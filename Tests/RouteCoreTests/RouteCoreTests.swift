import Darwin
@testable import RouteHelperCore
import RouteShared
import Foundation
import Testing

@Suite(.serialized)
final class TargetParserTests {
    @Test func testHosts() {
        XCTAssertEqual(TargetParser.parse("1.2.3.4"), .host("1.2.3.4"))
        XCTAssertEqual(TargetParser.parse(" 10.0.0.1 "), .host("10.0.0.1"))
        XCTAssertEqual(TargetParser.parse("8.8.8.8/32"), .host("8.8.8.8"))
        XCTAssertNil(TargetParser.parse("1.2.3.256"))
        XCTAssertNil(TargetParser.parse("1.2.3"))
    }

    @Test func testNetworks() {
        XCTAssertEqual(TargetParser.parse("10.1.2.3/8"), .network("10.0.0.0", prefix: 8))
        XCTAssertEqual(TargetParser.parse("192.168.1.0/24"), .network("192.168.1.0", prefix: 24))
        XCTAssertNil(TargetParser.parse("10.0.0.0/33"))
        // wider than /8 is not allowed: such rules send almost all traffic around the VPN
        XCTAssertNil(TargetParser.parse("0.0.0.0/0"))
        XCTAssertNil(TargetParser.parse("0.0.0.0/1"))
        XCTAssertNil(TargetParser.parse("128.0.0.0/1"))
        XCTAssertNil(TargetParser.parse("10.0.0.0/7"))
        XCTAssertEqual(TargetParser.parse("87.232.64.0/24"), .network("87.232.64.0", prefix: 24))
        XCTAssertEqual(TargetParser.netmask(prefix: 20), "255.255.240.0")
    }

    @Test func testDomains() {
        XCTAssertEqual(TargetParser.parse("Example.COM"), .domain("example.com"))
        XCTAssertEqual(TargetParser.parse("https://api.example.com:8443/v1?x=1"), .domain("api.example.com"))
        XCTAssertNil(TargetParser.parse("bad domain"))
        XCTAssertNil(TargetParser.parse("-bad.com"))
    }

    @Test func testInternationalDomains() {
        XCTAssertEqual(TargetParser.parse("промаркируем.бел"), .domain("xn--80akihieihjdc0b.xn--90ais"))
        XCTAssertEqual(TargetParser.parse("https://промаркируем.бел/"), .domain("xn--80akihieihjdc0b.xn--90ais"))
        XCTAssertEqual(TargetParser.parse("https://Промаркируем.БЕЛ:8443/путь?x=1"), .domain("xn--80akihieihjdc0b.xn--90ais"))
        XCTAssertEqual(TargetParser.parse("www.президент.рф"), .domain("www.xn--d1abbgf6aiiy.xn--p1ai"))
        XCTAssertEqual(TargetParser.parse("bücher.example"), .domain("xn--bcher-kva.example"))
        XCTAssertEqual(TargetParser.parse("xn--90ais"), .domain("xn--90ais"))
        XCTAssertNil(TargetParser.parse("плохой домен.бел"))
    }

    @Test func testSplitInput() {
        XCTAssertEqual(TargetParser.splitInput("a.com, 1.1.1.1\nb.com；c.com"), ["a.com", "1.1.1.1", "b.com", "c.com"])
    }

    @Test func testAddressHelpers() {
        XCTAssertTrue(TargetParser.isFakeIP("198.18.0.5"))
        XCTAssertTrue(TargetParser.isFakeIP("198.19.255.1"))
        XCTAssertFalse(TargetParser.isFakeIP("198.20.0.1"))
        XCTAssertTrue(TargetParser.sameSubnet("192.168.1.1", "192.168.1.27", mask: "255.255.255.0"))
        XCTAssertFalse(TargetParser.sameSubnet("172.20.10.1", "192.168.1.27", mask: "255.255.255.0"))
        XCTAssertTrue(TargetParser.isUnroutableResolution("127.0.0.1"))
        XCTAssertTrue(TargetParser.isUnroutableResolution("0.0.0.0"))
    }

    @Test func testConfigDecodesLegacyFormat() throws {
        let json = #"{"rules":[{"id":"11111111-1111-1111-1111-111111111111","target":"github.com","enabled":true,"note":""}],"interface":"auto","dnsRefreshMinutes":10}"#
        let config = try RouteJSON.decoder().decode(HelperConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.rules.first?.via, .physical)
        XCTAssertEqual(config.rules.first?.group, "")
        XCTAssertEqual(config.dnsMode, .physical)
        XCTAssertEqual(config.revision, 0)
    }
}

@Suite(.serialized)
final class RouteToolTests {
    @Test func testParseGetOutput() {
        let output = """
           route to: 1.1.1.1
        destination: default
               mask: default
          interface: utun19
              flags: <UP,DONE,CLONING,STATIC,GLOBAL>
        """
        let info = RouteTool.parseGetOutput(output)
        XCTAssertNil(info.gateway)
        XCTAssertEqual(info.interface, "utun19")
        XCTAssertEqual(info.destination, "default")
    }

    @Test func testAddArguments() {
        XCTAssertEqual(RouteTool.addArguments("1.2.3.4", via: NextHop(gateway: "192.168.1.1", interface: "en0")), ["-n", "add", "-host", "1.2.3.4", "192.168.1.1"])
        XCTAssertEqual(RouteTool.addArguments("10.0.0.0/8", via: NextHop(gateway: nil, interface: "utun3")), ["-n", "add", "-net", "10.0.0.0/8", "-interface", "utun3"])
    }
}

@Suite(.serialized)
final class RoutingTableTests {
    /// Builds a single NET_RT_DUMP message
    private func message(flags: Int32, index: UInt16, sockaddrs: [(Int32, [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        var addrs: Int32 = 0
        for (rta, sa) in sockaddrs.sorted(by: { $0.0 < $1.0 }) {
            addrs |= Int32(1) << rta
            body += sa
            let rounded = sa.isEmpty ? 4 : 1 + ((sa.count - 1) | 3)
            body += [UInt8](repeating: 0, count: rounded - sa.count)
        }
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_index = index
        header.rtm_flags = flags
        header.rtm_addrs = addrs
        return withUnsafeBytes(of: &header) { Array($0) } + body
    }

    private func sin(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        [16, UInt8(AF_INET), 0, 0, a, b, c, d, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    @Test func testParsesHostNetAndStaleRoutes() {
        let bytes = message(flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC, index: 4,
                            sockaddrs: [(RTAX_DST, sin(203, 0, 113, 22)), (RTAX_GATEWAY, sin(172, 20, 10, 1)), (RTAX_IFA, sin(172, 20, 10, 9))])
            + message(flags: RTF_UP | RTF_GATEWAY | RTF_STATIC, index: 4,
                      sockaddrs: [(RTAX_DST, sin(10, 0, 0, 0)), (RTAX_GATEWAY, sin(192, 168, 1, 1)), (RTAX_NETMASK, [5, 255, 0, 0, 255])])
            + message(flags: RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_IFSCOPE, index: 4,
                      sockaddrs: [(RTAX_DST, sin(0, 0, 0, 0)), (RTAX_GATEWAY, sin(192, 168, 1, 1)), (RTAX_NETMASK, [])])

        let entries = bytes.withUnsafeBytes { RoutingTable.parse($0, interfaceName: { _ in "en0" }) }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].address, "203.0.113.22")
        XCTAssertEqual(entries[0].gateway, "172.20.10.1")
        XCTAssertEqual(entries[0].interfaceAddress, "172.20.10.9")
        XCTAssertEqual(entries[0].flagString, "UGHS")
        XCTAssertEqual(entries[1].address, "10.0.0.0/8")
        XCTAssertEqual(entries[2].displayDestination, "default")
        XCTAssertTrue(entries[2].isScoped)

        let local = [LocalAddress(interface: "en0", address: "192.168.1.27", netmask: "255.255.255.0")]
        XCTAssertNotNil(RouteAnalyzer.staleReason(entries[0], localAddresses: local))
        XCTAssertNil(RouteAnalyzer.staleReason(entries[1], localAddresses: local))
        XCTAssertNil(RoutingTable.exactRoute(for: "0.0.0.0/0", in: entries), "scoped routes don't take part in exact matching")
    }

    @Test func testLiveDumpReturnsDefaultRoute() {
        XCTAssertTrue(RoutingTable.dump().contains { $0.prefix == 0 }, "The routing table must have at least one default route")
    }
}

@Suite(.serialized)
final class DNSMessageTests {
    @Test func testQueryAndCompressedResponse() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 0x1234, name: "www.example.com"))
        XCTAssertEqual(query.count, 12 + 17 + 4)

        var response = query
        response[2] = 0x81; response[3] = 0x80 // QR, RD, RA
        response[7] = 2 // ANCOUNT
        // CNAME: points to the name from the question (compression pointer 0xC00C)
        response += [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xC0, 0x10]
        // A: 93.184.216.34
        response += [0xC0, 0x10, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        XCTAssertEqual(DNSMessage.parseA(response, expectedID: 0x1234), .success(["93.184.216.34"]))
        XCTAssertEqual(DNSMessage.parseA(response, expectedID: 0x9999), .failure(.idMismatch))

        var nx = query
        nx[2] = 0x81; nx[3] = 0x83
        XCTAssertEqual(DNSMessage.parseA(nx, expectedID: 0x1234), .failure(.notFound))
    }

    @Test func testFakeIPIsRejected() {
        XCTAssertEqual(DNSResolver.filter(["198.18.0.7"]), .failure(.fakeIP(["198.18.0.7"])))
        XCTAssertEqual(DNSResolver.filter(["198.18.0.7", "1.2.3.4"]), .success(["1.2.3.4"]))
    }
}

@Suite(.serialized)
final class GatewayDetectorTests {
    let entries: [GatewayDetector.ServiceEntry] = [
        .init(serviceID: "vpn", ipv4: ["InterfaceName": "utun19", "Router": "100.100.10.53", "Addresses": ["100.100.10.53"]]),
        .init(serviceID: "feth", ipv4: ["InterfaceName": "feth1234", "Router": "127.0.0.1", "Addresses": ["10.99.0.91"]]),
        .init(serviceID: "wifi", ipv4: ["InterfaceName": "en0", "Router": "192.168.1.1", "Addresses": ["192.168.1.27"], "SubnetMasks": ["255.255.255.0"]],
              dns: ["ServerAddresses": ["192.168.1.1", "fe80::1"]]),
        .init(serviceID: "eth", ipv4: ["InterfaceName": "en7", "Router": "10.0.0.1", "Addresses": ["10.0.0.5"]]),
    ]

    @Test func testSkipsTunnelsAndUsesServiceOrder() {
        XCTAssertEqual(GatewayDetector.choose(entries: entries, serviceOrder: ["vpn", "eth", "wifi"], preferredInterface: "auto").physical?.router, "10.0.0.1")
        let snapshot = GatewayDetector.choose(entries: entries, serviceOrder: ["vpn", "wifi", "eth"], preferredInterface: "auto")
        XCTAssertEqual(snapshot.physical?.interface, "en0")
        XCTAssertEqual(snapshot.physicalInterface?.dnsServers, ["192.168.1.1"])
        XCTAssertEqual(snapshot.interfaces.first { $0.name == "utun19" }?.router, nil, "A VPN's Router equals its own address — treat it as having no gateway")
        XCTAssertEqual(snapshot.interfaces.first { $0.name == "utun19" }?.isVirtual, true)
    }

    @Test func testPreferredInterface() {
        XCTAssertEqual(GatewayDetector.choose(entries: entries, serviceOrder: [], preferredInterface: "en0").physical?.router, "192.168.1.1")
        XCTAssertNil(GatewayDetector.choose(entries: entries, serviceOrder: [], preferredInterface: "en9").physical)
    }
}

// MARK: - Engine consistency tests

/// Fake kernel routing table and network environment
final class FakeSystem: RouteSystem {
    var network: GatewayDetector.Snapshot
    var table: [String: RouteEntry] = [:]
    var dnsAnswers: [String: Result<[String], ResolveError>] = [:]
    var failAdd = Set<String>()
    var operations: [String] = []

    init(network: GatewayDetector.Snapshot) {
        self.network = network
    }

    func networkSnapshot(preferredInterface: String) -> GatewayDetector.Snapshot { network }
    func routingTable() -> [RouteEntry] { Array(table.values) }

    func addRoute(_ address: String, via hop: NextHop) -> Result<Void, RouteToolError> {
        if failAdd.contains(address) { return .failure(RouteToolError(message: "Simulated failure")) }
        if table[address] != nil { return .failure(RouteToolError(message: "File exists")) }
        table[address] = FakeSystem.entry(address, gateway: hop.gateway, network: network, interface: hop.interface)
        operations.append("add \(address) \(hop.gateway ?? hop.interface ?? "")")
        return .success(())
    }

    func deleteRoute(_ address: String) -> Result<Void, RouteToolError> {
        guard table.removeValue(forKey: address) != nil else { return .failure(RouteToolError(message: "not in table")) }
        operations.append("delete \(address)")
        return .success(())
    }

    func resolve(_ domain: String, mode: DNSMode, customServers: [String], physical: NetworkInterfaceInfo?) -> Result<[String], ResolveError> {
        dnsAnswers[domain] ?? .failure(.notFound)
    }

    static func entry(_ address: String, gateway: String?, network: GatewayDetector.Snapshot, interface: String? = nil) -> RouteEntry {
        let parts = address.split(separator: "/")
        let info = network.interfaces.first { i in
            if let interface { return i.name == interface }
            guard let gateway, let local = i.localAddress, let mask = i.subnetMask else { return false }
            return TargetParser.sameSubnet(gateway, local, mask: mask)
        }
        return RouteEntry(destination: String(parts[0]), prefix: parts.count == 2 ? Int(parts[1])! : 32, gateway: gateway,
                          interface: info?.name ?? interface ?? "en0", interfaceAddress: info?.localAddress,
                          flags: RTF_UP | RTF_STATIC | (gateway != nil ? RTF_GATEWAY : 0) | (parts.count == 1 ? RTF_HOST : 0))
    }
}

final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite(.serialized)
final class RouteEngineTests {
    static let vpn = NetworkInterfaceInfo(name: "utun19", router: nil, localAddress: "100.100.10.53", subnetMask: nil, dnsServers: [], isVirtual: true)
    static let wifi = GatewayDetector.Snapshot(
        physical: GatewayInfo(interface: "en0", router: "192.168.1.1", localAddress: "192.168.1.27"),
        interfaces: [NetworkInterfaceInfo(name: "en0", router: "192.168.1.1", localAddress: "192.168.1.27", subnetMask: "255.255.255.0", dnsServers: ["192.168.1.1"], isVirtual: false), vpn])
    static let hotspot = GatewayDetector.Snapshot(
        physical: GatewayInfo(interface: "en0", router: "172.20.10.1", localAddress: "172.20.10.9"),
        interfaces: [NetworkInterfaceInfo(name: "en0", router: "172.20.10.1", localAddress: "172.20.10.9", subnetMask: "255.255.255.240", dnsServers: ["172.20.10.1"], isVirtual: false), vpn])
    static let offline = GatewayDetector.Snapshot(physical: nil, interfaces: [vpn])

    var storage: URL!
    var system: FakeSystem!
    var clock: Clock!

    init() {
        storage = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelsideTests-\(UUID().uuidString)")
        system = FakeSystem(network: Self.wifi)
        clock = Clock()
    }

    deinit {
        try? FileManager.default.removeItem(at: storage)
        AppLanguage.current = .en
    }

    private func makeEngine() -> RouteEngine {
        let clock = self.clock!
        let engine = RouteEngine(storageDirectory: storage, system: system, now: { clock.date })
        // Without a language in the configuration the service uses the system language — tests must not depend on it
        if engine.currentState().config.language == nil { AppLanguage.current = .en }
        return engine
    }

    @discardableResult
    private func update(_ engine: RouteEngine, _ body: (inout HelperConfig) -> Void) -> Bool {
        var config = engine.currentState().config
        if config.language == nil { config.language = .en }
        body(&config)
        var conflict = false
        engine.updateConfig(config) { _, c in conflict = c }
        engine.workQueue.sync {}
        return !conflict
    }

    private func status(_ engine: RouteEngine, _ rule: RouteRule) -> RuleStatus? {
        engine.currentState().statuses[rule.id.uuidString]
    }

    @Test func testAppliesHostNetworkAndDomainRules() {
        system.dnsAnswers["example.com"] = .success(["93.184.216.34", "93.184.216.35"])
        let engine = makeEngine()
        let rules = [RouteRule(target: "1.2.3.4"), RouteRule(target: "10.0.0.0/8"), RouteRule(target: "example.com")]
        update(engine) { $0.rules = rules }

        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")
        XCTAssertEqual(system.table["10.0.0.0/8"]?.gateway, "192.168.1.1")
        XCTAssertEqual(system.table["93.184.216.35"]?.gateway, "192.168.1.1")
        XCTAssertEqual(status(engine, rules[2])?.appliedAddresses.count, 2)
        XCTAssertEqual(engine.currentState().managedRoutes.count, 4)
    }

    @Test func testRejectsRulesWiderThanMinimumPrefix() {
        // the config may reach the service bypassing the interface — wide rules are still not applied
        let engine = makeEngine()
        let tableBefore = system.table.count
        let rules = [RouteRule(target: "0.0.0.0/1"), RouteRule(target: "128.0.0.0/1"), RouteRule(target: "0.0.0.0/0")]
        update(engine) { $0.rules = rules }

        XCTAssertEqual(system.table.count, tableBefore)
        XCTAssertNil(system.table["0.0.0.0/1"])
        XCTAssertNil(system.table["128.0.0.0/1"])
        XCTAssertEqual(engine.currentState().managedRoutes.count, 0)
        XCTAssertNotNil(status(engine, rules[0])?.error)
    }

    @Test func testWiFiSwitchReplacesRoutesUsingDeleteAndAdd() {
        system.network = Self.hotspot
        let engine = makeEngine()
        let rule = RouteRule(target: "203.0.113.22")
        update(engine) { $0.rules = [rule] }
        XCTAssertEqual(system.table["203.0.113.22"]?.gateway, "172.20.10.1")

        system.network = Self.wifi
        system.operations.removeAll()
        engine.reconcileNow(reason: "network state changed")

        XCTAssertEqual(system.table["203.0.113.22"]?.gateway, "192.168.1.1")
        XCTAssertEqual(system.table["203.0.113.22"]?.interfaceAddress, "192.168.1.27")
        XCTAssertEqual(system.operations, ["delete 203.0.113.22", "add 203.0.113.22 192.168.1.1"])
        XCTAssertEqual(status(engine, rule)?.appliedAddresses, ["203.0.113.22"])
    }

    @Test func testFixesRouteWithStaleSourceAddress() {
        let engine = makeEngine()
        // Same gateway, but the route is still bound to the source address of the old network (common after route change)
        var stale = FakeSystem.entry("1.2.3.4", gateway: "192.168.1.1", network: Self.wifi)
        stale.interfaceAddress = "172.20.10.9"
        system.table["1.2.3.4"] = stale
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        XCTAssertEqual(system.table["1.2.3.4"]?.interfaceAddress, "192.168.1.27")
    }

    // The language is global, so these tests live in the serialized engine suite
    @Test func testMessagesFollowConfigLanguage() {
        let engine = makeEngine()
        let rule = RouteRule(target: "1.2.3.4")
        update(engine) { $0.rules = [rule]; $0.language = .ru }
        XCTAssertEqual(AppLanguage.current, .ru)

        system.network = Self.offline
        engine.reconcileNow()
        XCTAssertTrue(status(engine, rule)?.error?.contains("сохраняю") ?? false)

        update(engine) { $0.language = .en }
        XCTAssertEqual(AppLanguage.current, .en)
        XCTAssertTrue(status(engine, rule)?.error?.contains("keeping") ?? false)
    }

    @Test func testLanguageSurvivesRestart() throws {
        let legacy = try RouteJSON.decoder().decode(HelperConfig.self, from: Data(#"{"rules":[]}"#.utf8))
        XCTAssertNil(legacy.language, "A MacOSRoute configuration has no language — the service uses the system language")

        update(makeEngine()) { $0.language = .ru }
        AppLanguage.current = .en
        _ = makeEngine()
        XCTAssertEqual(AppLanguage.current, .ru, "After a restart the service writes in the saved language")
        XCTAssertEqual(L("Rules", "Правила"), "Правила")
    }

    @Test func testKeepsRoutesWhileOffline() {
        let engine = makeEngine()
        let rule = RouteRule(target: "1.2.3.4")
        update(engine) { $0.rules = [rule] }

        system.network = Self.offline
        engine.reconcileNow()
        XCTAssertNotNil(system.table["1.2.3.4"], "The route must not be removed while offline")
        XCTAssertTrue(status(engine, rule)?.error?.contains("keeping") ?? false)

        system.network = Self.hotspot
        engine.reconcileNow()
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "172.20.10.1")
    }

    @Test func testRepairsRouteRemovedByAnotherProgram() {
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        system.table["1.2.3.4"] = nil // for example, the VPN cleared the routes when connecting
        engine.reconcileNow()
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")
    }

    @Test func testRemovingRuleOnlyDeletesRoutesWeStillOwn() {
        let engine = makeEngine()
        let a = RouteRule(target: "1.2.3.4"), b = RouteRule(target: "5.6.7.8")
        update(engine) { $0.rules = [a, b] }
        // another program moved 5.6.7.8 to a different gateway
        system.table["5.6.7.8"] = FakeSystem.entry("5.6.7.8", gateway: "192.168.1.254", network: Self.wifi)

        update(engine) { $0.rules = [] }
        XCTAssertNil(system.table["1.2.3.4"])
        XCTAssertEqual(system.table["5.6.7.8"]?.gateway, "192.168.1.254", "Someone else's route must not be removed")
        XCTAssertTrue(engine.currentState().managedRoutes.isEmpty)
    }

    @Test func testRestoresReplacedStaticRoute() {
        system.table["1.2.3.4"] = FakeSystem.entry("1.2.3.4", gateway: "192.168.1.254", network: Self.wifi)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")

        update(engine) { $0.rules = [] }
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.254", "The previous route must be restored after the rule is removed")
    }

    @Test func testAdoptedIdenticalRouteIsKeptAfterRuleRemoval() {
        // for example, the VPN client's own route 100.64.0.0/10 → utun19
        system.table["100.64.0.0/10"] = FakeSystem.entry("100.64.0.0/10", gateway: nil, network: Self.wifi, interface: "utun19")
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "100.64.0.0/10", via: .interface("utun19"))] }
        XCTAssertTrue(system.operations.isEmpty, "An identical route must not be recreated")

        update(engine) { $0.rules = [] }
        XCTAssertNotNil(system.table["100.64.0.0/10"], "Removing a rule must not remove a pre-existing route")
    }

    @Test func testAdoptedRouteBecomesOwnedAfterReplacement() {
        system.table["1.2.3.4"] = FakeSystem.entry("1.2.3.4", gateway: "192.168.1.1", network: Self.wifi)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        system.network = Self.hotspot
        engine.reconcileNow()
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "172.20.10.1")

        update(engine) { $0.rules = [] }
        XCTAssertNil(system.table["1.2.3.4"], "A route recreated after a network change belongs to us and is removed with the rule")
    }

    @Test func testStaleRouteIsNotRestored() {
        // A stale route left over from a hotspot network
        system.table["203.0.113.22"] = FakeSystem.entry("203.0.113.22", gateway: "172.20.10.1", network: Self.hotspot)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "203.0.113.22")] }
        XCTAssertEqual(system.table["203.0.113.22"]?.gateway, "192.168.1.1")

        update(engine) { $0.rules = [] }
        XCTAssertNil(system.table["203.0.113.22"], "A stale route must not be restored")
    }

    @Test func testFailedAddIsNotRecordedAndIsRetried() {
        system.failAdd = ["1.2.3.4"]
        let engine = makeEngine()
        let rule = RouteRule(target: "1.2.3.4")
        update(engine) { $0.rules = [rule] }
        XCTAssertEqual(status(engine, rule)?.error, "Simulated failure")
        XCTAssertTrue(engine.currentState().managedRoutes.isEmpty)

        system.failAdd = []
        engine.reconcileNow()
        XCTAssertNotNil(system.table["1.2.3.4"])
        XCTAssertNil(status(engine, rule)?.error)
    }

    @Test func testDNSFailureKeepsLastResult() {
        system.dnsAnswers["example.com"] = .success(["93.184.216.34"])
        let engine = makeEngine()
        let rule = RouteRule(target: "example.com")
        update(engine) { $0.rules = [rule] }

        system.dnsAnswers["example.com"] = .failure(.timeout)
        engine.reconcileNow(forceResolve: true)
        XCTAssertNotNil(system.table["93.184.216.34"])
        XCTAssertEqual(status(engine, rule)?.appliedAddresses, ["93.184.216.34"])
        XCTAssertNotNil(status(engine, rule)?.warning)
    }

    @Test func testChangedDNSAnswersAreRetainedThenPruned() {
        system.dnsAnswers["cdn.example.com"] = .success(["1.1.1.1"])
        let engine = makeEngine()
        let rule = RouteRule(target: "cdn.example.com")
        update(engine) { $0.rules = [rule]; $0.dnsRetentionHours = 6 }

        clock.date += 11 * 60
        system.dnsAnswers["cdn.example.com"] = .success(["2.2.2.2"])
        engine.reconcileNow()
        XCTAssertNotNil(system.table["1.1.1.1"], "The old IP works while it is retained")
        XCTAssertNotNil(system.table["2.2.2.2"])
        XCTAssertEqual(status(engine, rule)?.retainedAddresses, ["1.1.1.1"])

        clock.date += 7 * 3600
        engine.reconcileNow()
        XCTAssertNil(system.table["1.1.1.1"], "Removed after the retention period")
        XCTAssertNotNil(system.table["2.2.2.2"])
    }

    @Test func testRevisionConflictIsRejected() {
        let engine = makeEngine()
        let stale = engine.currentState().config
        XCTAssertTrue(update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] })

        var other = stale
        other.rules = [RouteRule(target: "5.6.7.8")]
        var conflict = false
        engine.updateConfig(other) { _, c in conflict = c }
        engine.workQueue.sync {}
        XCTAssertTrue(conflict)
        XCTAssertEqual(engine.currentState().config.rules.map(\.target), ["1.2.3.4"])
    }

    @Test func testPauseAndResume() {
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        update(engine) { $0.paused = true }
        XCTAssertNil(system.table["1.2.3.4"])
        update(engine) { $0.paused = false }
        XCTAssertNotNil(system.table["1.2.3.4"])
    }

    @Test func testRecordsSurviveRestart() {
        let rule = RouteRule(target: "1.2.3.4")
        update(makeEngine()) { $0.rules = [rule] }

        let restarted = makeEngine()
        XCTAssertEqual(restarted.currentState().config.rules, [rule])
        update(restarted) { $0.rules = [] }
        XCTAssertNil(system.table["1.2.3.4"], "After a restart previously added routes are still cleaned up")
    }

    @Test func testConflictingNextHopsPreferEarlierRule() {
        let engine = makeEngine()
        let first = RouteRule(target: "1.2.3.4")
        let second = RouteRule(target: "1.2.3.4/32", via: .interface("utun19"))
        update(engine) { $0.rules = [first, second] }
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")
        XCTAssertNotNil(status(engine, second)?.warning)
    }

    @Test func testInterfaceAndGatewayVia() {
        let engine = makeEngine()
        update(engine) {
            $0.rules = [RouteRule(target: "100.64.0.0/10", via: .interface("utun19")),
                        RouteRule(target: "8.8.8.8", via: .gateway("192.168.1.254")),
                        RouteRule(target: "9.9.9.9", via: .gateway("10.9.9.1"))]
        }
        XCTAssertNil(system.table["100.64.0.0/10"]?.gateway)
        XCTAssertEqual(system.table["100.64.0.0/10"]?.interface, "utun19")
        XCTAssertEqual(system.table["8.8.8.8"]?.gateway, "192.168.1.254")
        XCTAssertNil(system.table["9.9.9.9"], "If the gateway is not in the current network, the route is not added")
    }

    @Test func testDeleteSystemRoutesRefusesManagedRoutes() {
        system.table["203.0.113.22"] = FakeSystem.entry("203.0.113.22", gateway: "172.20.10.1", network: Self.hotspot)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }

        var error: String?
        engine.deleteSystemRoutes(["203.0.113.22", "1.2.3.4"]) { error = $0 }
        engine.workQueue.sync {}
        XCTAssertNil(system.table["203.0.113.22"])
        XCTAssertNotNil(system.table["1.2.3.4"])
        XCTAssertTrue(error?.contains("1.2.3.4") ?? false)
    }
}
