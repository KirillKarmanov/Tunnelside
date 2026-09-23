import Foundation

/// Where a rule's traffic goes
public enum RouteVia: Codable, Hashable, Sendable {
    /// Physical gateway picked automatically (bypassing the VPN)
    case physical
    /// A specific interface: through its gateway if it has one, otherwise (for example, a VPN utun) directly through the interface
    case interface(String)
    /// IP of a specific gateway
    case gateway(String)

    public var label: String {
        switch self {
        case .physical: return L("Physical gateway", "Физический шлюз")
        case .interface(let name): return L("Interface \(name)", "Интерфейс \(name)")
        case .gateway(let ip): return L("Gateway \(ip)", "Шлюз \(ip)")
        }
    }
}

public struct RouteRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// IP, CIDR or domain
    public var target: String
    public var enabled: Bool
    public var note: String
    /// Group name; an empty string means no group
    public var group: String
    public var via: RouteVia

    public init(id: UUID = UUID(), target: String, enabled: Bool = true, note: String = "", group: String = "", via: RouteVia = .physical) {
        self.id = id
        self.target = target
        self.enabled = enabled
        self.note = note
        self.group = group
        self.via = via
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        target = try c.decode(String.self, forKey: .target)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        via = try c.decodeIfPresent(RouteVia.self, forKey: .via) ?? .physical
    }
}

public enum DNSMode: String, Codable, CaseIterable, Sendable {
    /// Query the network's DNS server through the physical interface (bypassing VPN / proxy DNS and Fake-IP)
    case physical
    /// System resolver (may be intercepted by a VPN / proxy)
    case system
    /// Query a custom DNS server through the physical interface
    case custom

    public var label: String {
        switch self {
        case .physical: return L("Physical network DNS (recommended)", "DNS физической сети (рекомендуется)")
        case .system: return L("System DNS", "Системный DNS")
        case .custom: return L("Custom DNS server", "Свой DNS-сервер")
        }
    }
}

public struct HelperConfig: Codable, Equatable, Sendable {
    public static let automaticInterface = "auto"

    public var rules: [RouteRule]
    /// Physical gateway interface: "auto" or a BSD interface name (for example, en0)
    public var interface: String
    /// Domain address refresh interval (minutes)
    public var dnsRefreshMinutes: Int
    public var dnsMode: DNSMode
    public var customDNSServers: [String]
    /// How many hours a route to an old IP is kept after a domain's addresses change (so CDN rotation doesn't break open connections)
    public var dnsRetentionHours: Int
    /// Pause: remove all routes added by Tunnelside but keep the rules
    public var paused: Bool
    /// Language of service messages (log, rule errors) — the app sends the system language.
    /// nil means the app has not connected yet: the service uses the system default language.
    public var language: AppLanguage?
    /// Configuration revision number — detects concurrent changes (several windows or app instances)
    public var revision: Int

    public init(rules: [RouteRule] = [], interface: String = HelperConfig.automaticInterface, dnsRefreshMinutes: Int = 10,
                dnsMode: DNSMode = .physical, customDNSServers: [String] = [], dnsRetentionHours: Int = 6,
                paused: Bool = false, language: AppLanguage? = nil, revision: Int = 0) {
        self.rules = rules
        self.interface = interface
        self.dnsRefreshMinutes = dnsRefreshMinutes
        self.dnsMode = dnsMode
        self.customDNSServers = customDNSServers
        self.dnsRetentionHours = dnsRetentionHours
        self.paused = paused
        self.language = language
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([RouteRule].self, forKey: .rules) ?? []
        interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? HelperConfig.automaticInterface
        dnsRefreshMinutes = try c.decodeIfPresent(Int.self, forKey: .dnsRefreshMinutes) ?? 10
        dnsMode = try c.decodeIfPresent(DNSMode.self, forKey: .dnsMode) ?? .physical
        customDNSServers = try c.decodeIfPresent([String].self, forKey: .customDNSServers) ?? []
        dnsRetentionHours = try c.decodeIfPresent(Int.self, forKey: .dnsRetentionHours) ?? 6
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    /// Clamp out-of-range values
    public mutating func sanitize() {
        dnsRefreshMinutes = min(max(1, dnsRefreshMinutes), 1440)
        dnsRetentionHours = min(max(0, dnsRetentionHours), 168)
        customDNSServers = customDNSServers.filter { TargetParser.ipv4Value($0) != nil }
        for i in rules.indices {
            rules[i].target = rules[i].target.trimmingCharacters(in: .whitespacesAndNewlines)
            rules[i].group = rules[i].group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public var groups: [String] {
        Array(Set(rules.map(\.group).filter { !$0.isEmpty })).sorted()
    }
}

/// Physical gateway (the default exit)
public struct GatewayInfo: Codable, Equatable, Sendable {
    public var interface: String
    public var router: String
    public var localAddress: String?

    public init(interface: String, router: String, localAddress: String?) {
        self.interface = interface
        self.router = router
        self.localAddress = localAddress
    }
}

/// A system network interface with an IPv4 configuration
public struct NetworkInterfaceInfo: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var router: String?
    public var localAddress: String?
    public var subnetMask: String?
    public var dnsServers: [String]
    /// Virtual interface (VPN tunnel, etc.)
    public var isVirtual: Bool

    public init(name: String, router: String?, localAddress: String?, subnetMask: String?, dnsServers: [String], isVirtual: Bool) {
        self.name = name
        self.router = router
        self.localAddress = localAddress
        self.subnetMask = subnetMask
        self.dnsServers = dnsServers
        self.isVirtual = isVirtual
    }
}

public struct RuleStatus: Codable, Equatable, Sendable {
    /// Rule addresses (host IP or CIDR), including retained old domain addresses
    public var addresses: [String]
    /// Addresses whose route through the chosen exit is currently confirmed
    public var appliedAddresses: [String]
    /// Old domain addresses that are still retained
    public var retainedAddresses: [String]
    public var error: String?
    public var warning: String?
    public var resolvedAt: Date?
    /// Actual next hop, for example "192.168.1.1 (en0)"
    public var nextHop: String?

    public init(addresses: [String] = [], appliedAddresses: [String] = [], retainedAddresses: [String] = [],
                error: String? = nil, warning: String? = nil, resolvedAt: Date? = nil, nextHop: String? = nil) {
        self.addresses = addresses
        self.appliedAddresses = appliedAddresses
        self.retainedAddresses = retainedAddresses
        self.error = error
        self.warning = warning
        self.resolvedAt = resolvedAt
        self.nextHop = nextHop
    }
}

/// A route currently maintained by the background service
public struct ManagedRoute: Codable, Equatable, Hashable, Sendable {
    public var address: String
    public var gateway: String?
    public var interface: String?

    public init(address: String, gateway: String?, interface: String?) {
        self.address = address
        self.gateway = gateway
        self.interface = interface
    }
}

public struct LogEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case info, warning, error }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var message: String

    public init(level: Level, message: String) {
        id = UUID()
        date = Date()
        self.level = level
        self.message = message
    }
}

public struct HelperState: Codable, Sendable {
    public var version: String
    public var config: HelperConfig
    public var gateway: GatewayInfo?
    public var interfaces: [NetworkInterfaceInfo]
    /// Key — RouteRule.id.uuidString
    public var statuses: [String: RuleStatus]
    public var managedRoutes: [ManagedRoute]
    public var lastApplyAt: Date?
    public var logs: [LogEntry]

    public init(version: String, config: HelperConfig, gateway: GatewayInfo? = nil, interfaces: [NetworkInterfaceInfo] = [],
                statuses: [String: RuleStatus] = [:], managedRoutes: [ManagedRoute] = [], lastApplyAt: Date? = nil, logs: [LogEntry] = []) {
        self.version = version
        self.config = config
        self.gateway = gateway
        self.interfaces = interfaces
        self.statuses = statuses
        self.managedRoutes = managedRoutes
        self.lastApplyAt = lastApplyAt
        self.logs = logs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        config = try c.decode(HelperConfig.self, forKey: .config)
        gateway = try c.decodeIfPresent(GatewayInfo.self, forKey: .gateway)
        interfaces = try c.decodeIfPresent([NetworkInterfaceInfo].self, forKey: .interfaces) ?? []
        statuses = try c.decodeIfPresent([String: RuleStatus].self, forKey: .statuses) ?? [:]
        managedRoutes = try c.decodeIfPresent([ManagedRoute].self, forKey: .managedRoutes) ?? []
        lastApplyAt = try c.decodeIfPresent(Date.self, forKey: .lastApplyAt)
        logs = try c.decodeIfPresent([LogEntry].self, forKey: .logs) ?? []
    }
}

public enum RouteJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
