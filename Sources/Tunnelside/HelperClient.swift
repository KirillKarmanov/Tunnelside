import Foundation
import RouteShared

/// Connection to the root service and state for the interface
@MainActor
final class HelperClient: ObservableObject {
    enum Status: Equatable {
        case checking
        case notInstalled
        case running
        case outdated(installed: String)
        case unreachable(String)
    }

    @Published private(set) var state: HelperState?
    @Published private(set) var status: Status = .checking
    @Published private(set) var isBusy = false
    @Published var alertMessage: String?

    /// For debugging: connect to the service in the user domain (launchctl gui/<uid>) instead of the system LaunchDaemon
    private let useDevAgent = ProcessInfo.processInfo.environment["TUNNELSIDE_DEV_AGENT"] == "1"
    private var connection: NSXPCConnection?
    private var timer: Timer?
    /// Incremented on every local configuration change to discard results of a fetch sent before the change, so the interface doesn't roll back
    private var configGeneration = 0

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Only a service of the matching version may change the configuration (the protocol may have changed)
    var canModify: Bool { status == .running }
    var config: HelperConfig? { state?.config }
    var rules: [RouteRule] { state?.config.rules ?? [] }
    var groups: [String] { state?.config.groups ?? [] }
    var isPaused: Bool { state?.config.paused ?? false }

    func status(for rule: RouteRule) -> RuleStatus? {
        state?.statuses[rule.id.uuidString]
    }

    var isInstalled: Bool {
        useDevAgent || FileManager.default.fileExists(atPath: RouteConstants.launchDaemonPlistPath)
    }

    // MARK: - Reading

    func refresh() {
        guard isInstalled else {
            // A service with the old identifier can't be reached by the new Mach service name — offer an update to finish the migration
            status = HelperInstaller.legacyHelperInstalled ? .outdated(installed: L("old version", "старая версия")) : .notInstalled
            state = nil
            return
        }
        let generation = configGeneration
        remote { [weak self] error in
            self?.status = .unreachable(error)
        }?.fetchState { data, error in
            let decoded = data.flatMap { try? RouteJSON.decoder().decode(HelperState.self, from: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.configGeneration else { return }
                self.apply(decoded, error: error)
            }
        }
    }

    private func apply(_ decoded: HelperState?, error: String?) {
        guard let decoded else {
            status = .unreachable(error ?? L("Could not read the background service state", "Не удалось прочитать состояние фоновой службы"))
            return
        }
        state = decoded
        status = decoded.version == RouteConstants.helperVersion ? .running : .outdated(installed: decoded.version)
        // The service writes the log and rule errors in the language from the configuration — pass it the system language
        if status == .running, decoded.config.language != AppLanguage.current {
            mutateConfig { $0.language = AppLanguage.current }
        }
    }

    // MARK: - Changing rules

    /// Returns unrecognized input
    @discardableResult
    func addTargets(from text: String, note: String = "", group: String = "", via: RouteVia = .physical) -> [String] {
        let inputs = TargetParser.splitInput(text)
        let invalid = inputs.filter { TargetParser.parse($0) == nil }
        let valid = inputs.filter { TargetParser.parse($0) != nil }
        guard !valid.isEmpty else { return invalid }
        mutateConfig { config in
            var existing = Set(config.rules.map { $0.target.lowercased() })
            for target in valid where !existing.contains(target.lowercased()) {
                existing.insert(target.lowercased())
                config.rules.append(RouteRule(target: target, note: note, group: group, via: via))
            }
        }
        return invalid
    }

    func setEnabled(_ enabled: Bool, for ids: Set<RouteRule.ID>) {
        mutateRules(ids) { $0.enabled = enabled }
    }

    func setGroup(_ group: String, for ids: Set<RouteRule.ID>) {
        mutateRules(ids) { $0.group = group }
    }

    func setVia(_ via: RouteVia, for ids: Set<RouteRule.ID>) {
        mutateRules(ids) { $0.via = via }
    }

    func setGroupEnabled(_ group: String, enabled: Bool) {
        mutateConfig { config in
            for i in config.rules.indices where config.rules[i].group == group {
                config.rules[i].enabled = enabled
            }
        }
    }

    func renameGroup(_ group: String, to newName: String) {
        mutateConfig { config in
            for i in config.rules.indices where config.rules[i].group == group {
                config.rules[i].group = newName
            }
        }
    }

    func updateRule(_ rule: RouteRule) {
        mutateConfig { config in
            if let i = config.rules.firstIndex(where: { $0.id == rule.id }) {
                config.rules[i] = rule
            }
        }
    }

    func removeRules(_ ids: Set<RouteRule.ID>) {
        mutateConfig { $0.rules.removeAll { ids.contains($0.id) } }
    }

    /// Rule order sets the priority when exits conflict
    func moveRules(_ ids: Set<RouteRule.ID>, toTop: Bool) {
        mutateConfig { config in
            let moved = config.rules.filter { ids.contains($0.id) }
            let others = config.rules.filter { !ids.contains($0.id) }
            config.rules = toTop ? moved + others : others + moved
        }
    }

    func setPaused(_ paused: Bool) {
        mutateConfig { $0.paused = paused }
    }

    private func mutateRules(_ ids: Set<RouteRule.ID>, _ body: @escaping (inout RouteRule) -> Void) {
        mutateConfig { config in
            for i in config.rules.indices where ids.contains(config.rules[i].id) {
                body(&config.rules[i])
            }
        }
    }

    /// Change the latest configuration and send it. If another window / instance changed it first (revision conflict), load fresh state and repeat the change.
    func mutateConfig(_ body: @escaping (inout HelperConfig) -> Void) {
        guard canModify, let base = state?.config else {
            alertMessage = status == .running ? L("The background service is not ready", "Фоновая служба не готова") : L("Install or update the background service first", "Сначала установите или обновите фоновую службу")
            return
        }
        var config = base
        body(&config)
        guard config != base else { return }
        state?.config = config
        configGeneration += 1
        submit(config, body: body, attemptsLeft: 3)
    }

    private func submit(_ config: HelperConfig, body: @escaping (inout HelperConfig) -> Void, attemptsLeft: Int) {
        guard let data = try? RouteJSON.encoder().encode(config) else { return }
        remote { [weak self] error in
            self?.alertMessage = L("Could not save: \(error)", "Не удалось сохранить: \(error)")
            self?.configGeneration += 1
            self?.refresh()
        }?.updateConfig(data) { error, conflict in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if conflict, attemptsLeft > 0 {
                    self.retryAfterConflict(body: body, attemptsLeft: attemptsLeft - 1)
                    return
                }
                self.configGeneration += 1
                if conflict { self.alertMessage = L("The configuration was changed in another window, try again", "Конфигурацию изменили в другом окне, повторите") }
                if let error { self.alertMessage = error }
                self.refresh()
            }
        }
    }

    private func retryAfterConflict(body: @escaping (inout HelperConfig) -> Void, attemptsLeft: Int) {
        remote { [weak self] error in
            self?.alertMessage = error
        }?.fetchState { data, _ in
            let decoded = data.flatMap { try? RouteJSON.decoder().decode(HelperState.self, from: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, var latest = decoded?.config else { return }
                body(&latest)
                self.state?.config = latest
                self.configGeneration += 1
                self.submit(latest, body: body, attemptsLeft: attemptsLeft)
            }
        }
    }

    func reapply() {
        isBusy = true
        remote { [weak self] error in
            self?.isBusy = false
            self?.alertMessage = error
        }?.reapplyAll { error in
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                if let error { self?.alertMessage = error }
                self?.refresh()
            }
        }
    }

    func deleteSystemRoutes(_ addresses: [String], completion: @escaping @MainActor () -> Void = {}) {
        guard canModify else { return }
        isBusy = true
        remote { [weak self] error in
            self?.isBusy = false
            self?.alertMessage = error
        }?.deleteSystemRoutes(addresses) { error in
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                if let error { self?.alertMessage = L("Some routes were not removed:\n\(error)", "Часть маршрутов не удалена:\n\(error)") }
                completion()
            }
        }
    }

    // MARK: - Install / uninstall

    func installHelper() {
        isBusy = true
        Task {
            do {
                try await HelperInstaller.install()
                resetConnection()
                try? await Task.sleep(nanoseconds: 800_000_000)
            } catch HelperInstaller.InstallError.cancelled {
            } catch {
                alertMessage = L("Could not install: \(error.localizedDescription)", "Не удалось установить: \(error.localizedDescription)")
            }
            isBusy = false
            refresh()
        }
    }

    func uninstallHelper() {
        isBusy = true
        let finish: @MainActor () -> Void = { [weak self] in
            Task { @MainActor in
                do {
                    try await HelperInstaller.uninstall()
                    self?.resetConnection()
                } catch HelperInstaller.InstallError.cancelled {
                    // The user cancelled — resume syncing
                    self?.reapply()
                } catch {
                    self?.alertMessage = L("Could not uninstall: \(error.localizedDescription)", "Не удалось удалить: \(error.localizedDescription)")
                }
                self?.isBusy = false
                self?.refresh()
            }
        }
        guard canModify, let proxy = remote({ _ in finish() }) else {
            finish()
            return
        }
        // First the service removes the routes it added
        proxy.removeAllRoutes { _ in
            DispatchQueue.main.async { finish() }
        }
    }

    // MARK: - XPC

    private func resetConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func remote(_ onError: @escaping @MainActor (String) -> Void) -> RouteHelperProtocol? {
        let connection = self.connection ?? makeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { onError(error.localizedDescription) }
        }
        return proxy as? RouteHelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: RouteConstants.machServiceName, options: useDevAgent ? [] : .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: RouteHelperProtocol.self)
        let reset: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        c.invalidationHandler = reset
        c.interruptionHandler = reset
        c.resume()
        connection = c
        return c
    }
}

/// Navigation between sections (for example, from rules or the routing table to diagnostics)
@MainActor
final class AppNavigation: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case rules, routeTable, diagnostics, logs, settings

        var id: String { rawValue }
        var title: String {
            switch self {
            case .rules: return L("Rules", "Правила")
            case .routeTable: return L("Routing Table", "Таблица маршрутов")
            case .diagnostics: return L("Diagnostics", "Диагностика")
            case .logs: return L("Log", "Журнал")
            case .settings: return L("Settings", "Настройки")
            }
        }
        var symbol: String {
            switch self {
            case .rules: return "arrow.triangle.branch"
            case .routeTable: return "tablecells"
            case .diagnostics: return "stethoscope"
            case .logs: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var section: Section? = .rules
    @Published var diagnosticsTarget = ""
    /// Increment to start diagnostics automatically
    @Published var diagnosticsRequest = 0

    func diagnose(_ target: String) {
        diagnosticsTarget = target
        section = .diagnostics
        diagnosticsRequest += 1
    }
}
