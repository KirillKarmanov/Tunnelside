import Foundation
import RouteShared

/// Route engine: stores the configuration, tracks added routes and reconciles the kernel routing table to the desired state.
///
/// Consistency rules:
/// - All changes run serially on workQueue; the published snapshot is guarded by a lock, so reads are never blocked by slow operations.
/// - Routes in applied.json are always a superset of the routes actually added: a record is written before adding and removed after a successful removal, so cleanup can continue after a crash and restart.
/// - Every sync re-checks the kernel routing table instead of trusting the previous result, so it repairs routes changed by the VPN and other programs.
/// - If the next hop is temporarily unavailable (no network, interface not connected), existing routes are kept, not removed.
/// - When a rule is removed, the address returns to its state before the rule: an identical pre-existing route is kept; a replaced working static route is restored, a stale one is not.
public final class RouteEngine: @unchecked Sendable {
    struct AppliedRoute: Codable, Equatable {
        var gateway: String?
        var interface: String?
        /// Gateway of the replaced original static route; restored when the rule is removed
        var restoreGateway: String?
        /// An identical route already existed in the kernel before the rule was applied (for example, the VPN's own route); kept when the rule is removed
        var adopted: Bool?

        /// Whether this kernel route still belongs to us
        func owns(_ entry: RouteEntry) -> Bool {
            if let gateway { return entry.gateway == gateway }
            return entry.gateway == nil && entry.interface == interface
        }
    }

    struct DNSRecord: Codable, Equatable {
        /// IP -> when it was last among the domain's addresses
        var addresses: [String: Date] = [:]
        var resolvedAt: Date?
        var lastError: String?
        var retryAfter: Date?

        var currentAddresses: [String] {
            guard let resolvedAt else { return [] }
            return addresses.filter { $0.value >= resolvedAt }.map(\.key).sorted(by: ipLess)
        }

        var retainedAddresses: [String] {
            addresses.filter { resolvedAt == nil || $0.value < resolvedAt! }.map(\.key).sorted(by: ipLess)
        }
    }

    public let workQueue = DispatchQueue(label: "io.github.kirillkarmanov.Tunnelside.engine")
    private let system: RouteSystem
    private let storageDirectory: URL
    private let now: () -> Date

    // Accessed only on workQueue
    private var config: HelperConfig
    private var applied: [String: AppliedRoute]
    private var dns: [String: DNSRecord]
    private var pendingReconcile: DispatchWorkItem?
    private var pendingForceResolve = false
    /// After removeAllRoutes, sync is paused (uninstall in progress) until the configuration is updated or a manual reapply happens
    private var suspended = false
    private var networkMonitor: NetworkChangeMonitor?
    private var routingMonitor: RoutingTableMonitor?
    private var timer: DispatchSourceTimer?

    // Guarded by lock
    private let lock = NSLock()
    private var snapshot: HelperState

    private static let maxLogs = 500
    private static let maxAddressesPerDomain = 64
    private static let dnsRetryInterval: TimeInterval = 60

    public init(storageDirectory: URL, system: RouteSystem, now: @escaping () -> Date = Date.init) {
        self.storageDirectory = storageDirectory
        self.system = system
        self.now = now
        config = Self.load(HelperConfig.self, from: storageDirectory.appendingPathComponent("config.json")) ?? HelperConfig()
        applied = Self.load([String: AppliedRoute].self, from: storageDirectory.appendingPathComponent("applied.json")) ?? [:]
        dns = Self.load([String: DNSRecord].self, from: storageDirectory.appendingPathComponent("dns.json")) ?? [:]
        snapshot = HelperState(version: RouteConstants.helperVersion, config: config)
        AppLanguage.current = config.language ?? .system
    }

    public func start() {
        workQueue.async { [self] in
            log(.info, L("Helper \(RouteConstants.helperVersion) started, rules: \(config.rules.count), recorded routes: \(applied.count)", "Helper \(RouteConstants.helperVersion) запущен, правил: \(config.rules.count), записанных маршрутов: \(applied.count)"))
            networkMonitor = NetworkChangeMonitor(queue: workQueue) { [weak self] in
                self?.scheduleReconcile(reason: L("network state changed", "изменилось состояние сети"), delay: 2, forceResolve: true)
            }
            routingMonitor = RoutingTableMonitor(queue: workQueue) { [weak self] in
                self?.scheduleReconcile(reason: nil, delay: 2, forceResolve: false)
            }
            // Safety-net periodic check: catches missed events and refreshes domain addresses on schedule
            let timer = DispatchSource.makeTimerSource(queue: workQueue)
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in self?.reconcile(reason: nil, forceResolve: false) }
            timer.resume()
            self.timer = timer
            reconcile(reason: L("startup", "запуск"), forceResolve: false)
        }
    }

    // MARK: - Public interface (callable from any thread)

    public func currentState() -> HelperState {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func updateConfig(_ newConfig: HelperConfig, completion: @escaping (_ error: String?, _ conflict: Bool) -> Void) {
        workQueue.async { [self] in
            guard newConfig.revision == config.revision else {
                completion(nil, true)
                return
            }
            var next = newConfig
            next.sanitize()
            next.revision = config.revision + 1
            AppLanguage.current = next.language ?? .system
            do {
                try save(next, to: "config.json")
            } catch {
                log(.error, L("Could not save the configuration: \(error.localizedDescription)", "Не удалось сохранить конфигурацию: \(error.localizedDescription)"))
                completion(L("Could not save the configuration: \(error.localizedDescription)", "Не удалось сохранить конфигурацию: \(error.localizedDescription)"), false)
                return
            }
            let reason = next.paused != config.paused ? (next.paused ? L("paused", "пауза") : L("resumed", "продолжено")) : L("configuration changed", "изменена конфигурация")
            config = next
            suspended = false
            lock.lock()
            snapshot.config = next
            lock.unlock()
            completion(nil, false)
            reconcile(reason: reason, forceResolve: false)
        }
    }

    public func reapplyAll(completion: @escaping (String?) -> Void) {
        workQueue.async { [self] in
            suspended = false
            for key in dns.keys {
                dns[key]?.resolvedAt = nil
                dns[key]?.retryAfter = nil
            }
            reconcile(reason: L("manual reapply", "ручное применение"), forceResolve: true)
            completion(nil)
        }
    }

    public func removeAllRoutes(completion: @escaping (String?) -> Void) {
        workQueue.async { [self] in
            suspended = true
            pendingReconcile?.cancel()
            let table = system.routingTable()
            var failures: [String] = []
            for address in applied.keys.sorted() {
                if let error = removeManagedRoute(address, table: table) {
                    failures.append("\(address): \(error)")
                }
            }
            log(.info, L("Removed routes added by Tunnelside; sync is paused", "Удалены маршруты, добавленные Tunnelside; синхронизация на паузе"))
            publish(statuses: [:], network: system.networkSnapshot(preferredInterface: config.interface), applyDate: nil)
            completion(failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    public func deleteSystemRoutes(_ addresses: [String], completion: @escaping (String?) -> Void) {
        workQueue.async { [self] in
            let table = system.routingTable()
            var failures: [String] = []
            for address in addresses {
                guard applied[address] == nil else {
                    failures.append(L("\(address): managed by Tunnelside — remove the matching rule instead", "\(address): управляется Tunnelside — удалите соответствующее правило"))
                    continue
                }
                guard let entry = RoutingTable.exactRoute(for: address, in: table), entry.isStatic else {
                    failures.append(L("\(address): not a static route or no longer exists", "\(address): не статический маршрут или уже не существует"))
                    continue
                }
                switch system.deleteRoute(address) {
                case .success:
                    log(.info, L("Removed system route \(address) → \(entry.gateway ?? entry.interface)", "Удалён системный маршрут \(address) → \(entry.gateway ?? entry.interface)"))
                case .failure(let error):
                    failures.append("\(address): \(error)")
                }
            }
            completion(failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    /// For tests: run one sync synchronously
    func reconcileNow(reason: String? = nil, forceResolve: Bool = false) {
        workQueue.sync { reconcile(reason: reason, forceResolve: forceResolve) }
    }

    // MARK: - Sync logic

    private func scheduleReconcile(reason: String?, delay: TimeInterval, forceResolve: Bool) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        pendingReconcile?.cancel()
        pendingForceResolve = pendingForceResolve || forceResolve
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconcile(reason: reason, forceResolve: self.pendingForceResolve)
        }
        pendingReconcile = item
        workQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reconcile(reason: String?, forceResolve: Bool) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        pendingReconcile?.cancel()
        pendingReconcile = nil
        pendingForceResolve = false
        guard !suspended else { return }

        let network = system.networkSnapshot(preferredInterface: config.interface)
        let previous = currentState().gateway
        if network.physical?.interface != previous?.interface || network.physical?.router != previous?.router {
            if let gw = network.physical {
                log(.info, L("Physical gateway: \(gw.interface) → \(gw.router)", "Физический шлюз: \(gw.interface) → \(gw.router)"))
            } else {
                log(.warning, config.interface == HelperConfig.automaticInterface ? L("No reachable physical gateway found", "Не найден доступный физический шлюз") : L("Interface \(config.interface) has no reachable gateway", "У интерфейса \(config.interface) нет доступного шлюза"))
            }
        }
        if let reason { log(.info, L("Syncing routes (\(reason))", "Синхронизация маршрутов (\(reason))")) }

        if !config.paused {
            resolveDomains(force: forceResolve, network: network)
        }

        // 1. Compute the desired state
        var statuses: [String: RuleStatus] = [:]
        var desired: [String: (hop: NextHop, rule: RouteRule)] = [:]
        var keep = Set<String>()
        for rule in config.rules {
            var status = RuleStatus()
            switch TargetParser.parse(rule.target) {
            case nil:
                status.error = L("Invalid address", "Некорректный адрес")
            case .host(let ip):
                status.addresses = [ip]
            case .network(let net, let prefix):
                status.addresses = ["\(net)/\(prefix)"]
            case .domain(let domain):
                if let record = dns[domain] {
                    status.retainedAddresses = record.retainedAddresses
                    status.addresses = record.currentAddresses + record.retainedAddresses
                    status.resolvedAt = record.resolvedAt
                    if let error = record.lastError {
                        if status.addresses.isEmpty { status.error = error } else { status.warning = L("\(error), keeping the previous addresses", "\(error), используются прежние адреса") }
                    }
                }
            }

            if rule.enabled, !config.paused, !status.addresses.isEmpty {
                switch nextHop(for: rule.via, network: network) {
                case .failure(let failure):
                    status.error = failure.message
                    keep.formUnion(status.addresses)
                case .success(let hop):
                    status.nextHop = hop.label
                    for address in status.addresses {
                        if let owner = desired[address] {
                            if owner.hop != hop {
                                status.warning = L("\(address): route conflicts with rule “\(owner.rule.target)”; the rule higher in the list wins", "\(address): выход конфликтует с правилом «\(owner.rule.target)», действует правило, стоящее выше")
                            }
                        } else {
                            desired[address] = (hop, rule)
                        }
                    }
                }
            }
            statuses[rule.id.uuidString] = status
        }

        // 2. Remove routes that are no longer needed
        var table = system.routingTable()
        var changed = false
        for address in applied.keys.sorted() where desired[address] == nil && !keep.contains(address) {
            _ = removeManagedRoute(address, table: table)
            changed = true
        }

        // 3. Add / fix routes
        var failed: [String: String] = [:]
        for address in desired.keys.sorted(by: ipLess) {
            let want = desired[address]!.hop
            let existing = RoutingTable.exactRoute(for: address, in: table)
            if let existing, want.isSatisfied(by: existing) {
                if applied[address]?.gateway != want.gateway || applied[address]?.interface != want.interface {
                    var record = applied[address] ?? AppliedRoute(adopted: true)
                    record.gateway = want.gateway
                    record.interface = want.interface
                    applied[address] = record
                    saveApplied()
                }
                continue
            }

            var record = applied[address] ?? AppliedRoute()
            if applied[address] == nil, let existing, existing.isStatic, existing.hasGateway, !existing.isCloned,
               existing.gateway != want.gateway, isReachable(existing.gateway, network: network) {
                record.restoreGateway = existing.gateway
            }
            record.adopted = nil
            record.gateway = want.gateway
            record.interface = want.interface
            applied[address] = record
            saveApplied() // record the intent first, then change the kernel

            changed = true
            // "Delete + add" instead of route change: after a network change, change may keep the old source address (ifa)
            if existing != nil { _ = system.deleteRoute(address) }
            var result = system.addRoute(address, via: want)
            if case .failure = result, existing == nil, case .success = system.deleteRoute(address) {
                result = system.addRoute(address, via: want) // there may be an unrecognized equivalent route — delete it and retry
            }
            switch result {
            case .success:
                if let existing {
                    log(.info, L("Fixed route \(address) → \(want.label) (was \(existing.gateway ?? existing.interface))", "Исправлен маршрут \(address) → \(want.label) (был \(existing.gateway ?? existing.interface))"))
                } else {
                    log(.info, L("Added route \(address) → \(want.label)", "Добавлен маршрут \(address) → \(want.label)"))
                }
            case .failure(let error):
                failed[address] = error.message
                log(.error, L("Could not add route \(address): \(error)", "Не удалось установить маршрут \(address): \(error)"))
                if existing != nil, let restore = record.restoreGateway {
                    _ = system.addRoute(address, via: NextHop(gateway: restore, interface: nil))
                }
                applied[address] = nil
                saveApplied()
            }
        }

        // 4. Verify the result against the actual kernel state
        if changed { table = system.routingTable() }
        for (key, var status) in statuses {
            status.appliedAddresses = status.addresses.filter { address in
                guard let want = desired[address], failed[address] == nil,
                      let entry = RoutingTable.exactRoute(for: address, in: table) else { return false }
                return want.hop.isSatisfied(by: entry)
            }
            if status.error == nil, let failure = status.addresses.compactMap({ failed[$0] }).first {
                status.error = failure
            }
            statuses[key] = status
        }
        publish(statuses: statuses, network: network, applyDate: now())
    }

    /// Removes a route we manage; if the kernel route was already changed by another program, only the record is removed. Returns the error text.
    private func removeManagedRoute(_ address: String, table: [RouteEntry]) -> String? {
        guard let record = applied[address] else { return nil }
        if record.adopted == true {
            log(.info, L("Rule removed; pre-existing route \(address) kept", "Правило удалено, существовавший ранее маршрут \(address) сохранён"))
        } else if let entry = RoutingTable.exactRoute(for: address, in: table), record.owns(entry) {
            if case .failure(let error) = system.deleteRoute(address) {
                log(.error, L("Could not remove route \(address): \(error)", "Не удалось удалить маршрут \(address): \(error)"))
                return error.message // keep the record, retry on the next sync
            }
            if let restore = record.restoreGateway {
                if case .failure(let error) = system.addRoute(address, via: NextHop(gateway: restore, interface: nil)) {
                    log(.warning, L("Removed route \(address), but could not restore the previous gateway \(restore): \(error)", "Удалён маршрут \(address), но не удалось восстановить прежний шлюз \(restore): \(error)"))
                } else {
                    log(.info, L("Removed route \(address), restored the previous gateway \(restore)", "Удалён маршрут \(address), восстановлен прежний шлюз \(restore)"))
                }
            } else {
                log(.info, L("Removed route \(address)", "Удалён маршрут \(address)"))
            }
        }
        applied[address] = nil
        saveApplied()
        return nil
    }

    /// Whether the gateway is in the subnet of one of the current networks
    private func isReachable(_ gateway: String?, network: GatewayDetector.Snapshot) -> Bool {
        guard let gateway else { return false }
        return network.interfaces.contains { i in
            guard let local = i.localAddress, let mask = i.subnetMask else { return false }
            return TargetParser.sameSubnet(gateway, local, mask: mask)
        }
    }

    private func nextHop(for via: RouteVia, network: GatewayDetector.Snapshot) -> Result<NextHop, RouteToolError> {
        switch via {
        case .physical:
            guard let gw = network.physical else {
                return .failure(RouteToolError(message: config.interface == HelperConfig.automaticInterface
                    ? L("Physical gateway not found, keeping existing routes", "Физический шлюз не найден, сохраняю существующие маршруты") : L("Interface \(config.interface) has no gateway, keeping existing routes", "У интерфейса \(config.interface) нет шлюза, сохраняю существующие маршруты")))
            }
            return .success(NextHop(gateway: gw.router, interface: gw.interface, localAddress: gw.localAddress))
        case .interface(let name):
            guard let info = network.interfaces.first(where: { $0.name == name }) else {
                return .failure(RouteToolError(message: L("Interface \(name) is not connected, keeping existing routes", "Интерфейс \(name) не подключён, сохраняю существующие маршруты")))
            }
            if let router = info.router, !info.isVirtual {
                return .success(NextHop(gateway: router, interface: name, localAddress: info.localAddress))
            }
            return .success(NextHop(gateway: nil, interface: name))
        case .gateway(let ip):
            guard TargetParser.ipv4Value(ip) != nil else { return .failure(RouteToolError(message: L("Invalid gateway \(ip)", "Некорректный шлюз \(ip)"))) }
            let info = network.interfaces.first { i in
                guard let local = i.localAddress, let mask = i.subnetMask else { return false }
                return TargetParser.sameSubnet(ip, local, mask: mask)
            }
            guard let info else { return .failure(RouteToolError(message: L("Gateway \(ip) is not in any current network, keeping existing routes", "Шлюз \(ip) не входит ни в одну текущую сеть, сохраняю существующие маршруты"))) }
            return .success(NextHop(gateway: ip, interface: info.name, localAddress: info.localAddress))
        }
    }

    // MARK: - DNS

    private func resolveDomains(force: Bool, network: GatewayDetector.Snapshot) {
        let current = now()
        var allDomains = Set<String>()
        var enabledDomains = Set<String>()
        for rule in config.rules {
            guard case .domain(let domain) = TargetParser.parse(rule.target) else { continue }
            allDomains.insert(domain)
            if rule.enabled { enabledDomains.insert(domain) }
        }
        var dirty = false
        for key in dns.keys where !allDomains.contains(key) {
            dns[key] = nil
            dirty = true
        }

        let refresh = TimeInterval(config.dnsRefreshMinutes * 60)
        let due = enabledDomains.filter { domain in
            guard let record = dns[domain] else { return true }
            if force { return true }
            if let retry = record.retryAfter { return current >= retry }
            return record.resolvedAt.map { current.timeIntervalSince($0) >= refresh } ?? true
        }.sorted()

        let physical = network.physicalInterface
        if !due.isEmpty, config.dnsMode == .system || physical != nil {
            final class Results: @unchecked Sendable {
                var values: [Result<[String], ResolveError>?]
                let lock = NSLock()
                init(count: Int) { values = Array(repeating: nil, count: count) }
            }
            let results = Results(count: due.count)
            let mode = config.dnsMode
            let servers = config.customDNSServers
            let system = self.system
            DispatchQueue.concurrentPerform(iterations: due.count) { i in
                let result = system.resolve(due[i], mode: mode, customServers: servers, physical: physical)
                results.lock.lock()
                results.values[i] = result
                results.lock.unlock()
            }

            for (domain, result) in zip(due, results.values) {
                var record = dns[domain] ?? DNSRecord()
                switch result {
                case .success(let ips)?:
                    let previous = Set(record.currentAddresses)
                    for ip in ips { record.addresses[ip] = current }
                    record.resolvedAt = current
                    record.lastError = nil
                    record.retryAfter = nil
                    if previous != Set(ips) {
                        log(.info, L("Addresses of \(domain): \(ips.joined(separator: ", "))", "Адреса \(domain): \(ips.joined(separator: ", "))"))
                    }
                case .failure(let error)?:
                    if record.lastError != error.description {
                        log(.warning, "\(domain) \(error)")
                    }
                    record.lastError = error.description
                    record.retryAfter = current.addingTimeInterval(Self.dnsRetryInterval)
                case nil:
                    continue
                }
                dns[domain] = record
            }
            dirty = true
        }

        // Drop old addresses whose retention period has expired
        let retention = TimeInterval(config.dnsRetentionHours * 3600)
        for domain in dns.keys {
            guard var record = dns[domain], let resolvedAt = record.resolvedAt else { continue }
            let before = record.addresses.count
            record.addresses = record.addresses.filter { $0.value >= resolvedAt || current.timeIntervalSince($0.value) < retention }
            if record.addresses.count > Self.maxAddressesPerDomain {
                let newest = record.addresses.sorted { $0.value > $1.value }.prefix(Self.maxAddressesPerDomain)
                record.addresses = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
            if record.addresses.count != before {
                dns[domain] = record
                dirty = true
            }
        }
        if dirty { saveDNS() }
    }

    // MARK: - Publishing state and saving

    private func publish(statuses: [String: RuleStatus], network: GatewayDetector.Snapshot, applyDate: Date?) {
        let managed = applied.keys.sorted(by: ipLess).map { ManagedRoute(address: $0, gateway: applied[$0]?.gateway, interface: applied[$0]?.interface) }
        lock.lock(); defer { lock.unlock() }
        snapshot.config = config
        snapshot.statuses = statuses
        snapshot.gateway = network.physical
        snapshot.interfaces = network.interfaces
        snapshot.managedRoutes = managed
        if let applyDate { snapshot.lastApplyAt = applyDate }
    }

    private func log(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: entry.date)) [\(level.rawValue)] \(message)\n".utf8))
        lock.lock(); defer { lock.unlock() }
        snapshot.logs.append(entry)
        if snapshot.logs.count > Self.maxLogs {
            snapshot.logs.removeFirst(snapshot.logs.count - Self.maxLogs)
        }
    }

    private func saveApplied() {
        do { try save(applied, to: "applied.json") } catch { log(.error, L("Could not save route records: \(error.localizedDescription)", "Не удалось сохранить записи маршрутов: \(error.localizedDescription)")) }
    }

    private func saveDNS() {
        do { try save(dns, to: "dns.json") } catch { log(.error, L("Could not save the DNS cache: \(error.localizedDescription)", "Не удалось сохранить кеш DNS: \(error.localizedDescription)")) }
    }

    private func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let data = try RouteJSON.encoder().encode(value)
        try data.write(to: storageDirectory.appendingPathComponent(name), options: .atomic)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? RouteJSON.decoder().decode(type, from: data)
    }
}

/// Compares IP / CIDR strings in numeric order
func ipLess(_ a: String, _ b: String) -> Bool {
    func key(_ s: String) -> (UInt32, Int) {
        let parts = s.split(separator: "/")
        return (TargetParser.ipv4Value(String(parts[0])) ?? 0, parts.count == 2 ? Int(parts[1]) ?? 32 : 32)
    }
    return key(a) < key(b)
}
