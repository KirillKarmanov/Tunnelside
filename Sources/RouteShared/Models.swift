import Foundation

/// Выход для правила
public enum RouteVia: Codable, Hashable, Sendable {
    /// Физический шлюз, выбранный автоматически (мимо VPN)
    case physical
    /// Заданный интерфейс: через его шлюз, если он есть, иначе (например, utun у VPN) напрямую через интерфейс
    case interface(String)
    /// IP заданного шлюза
    case gateway(String)

    public var label: String {
        switch self {
        case .physical: return "Физический шлюз"
        case .interface(let name): return "Интерфейс \(name)"
        case .gateway(let ip): return "Шлюз \(ip)"
        }
    }
}

public struct RouteRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// IP, CIDR или домен
    public var target: String
    public var enabled: Bool
    public var note: String
    /// Имя группы; пустая строка — без группы
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
    /// Запрос к DNS-серверу сети через физический интерфейс (мимо DNS и Fake-IP у VPN / прокси)
    case physical
    /// Системный резолвер (его может перехватывать VPN / прокси)
    case system
    /// Запрос к своему DNS-серверу через физический интерфейс
    case custom

    public var label: String {
        switch self {
        case .physical: return "DNS физической сети (рекомендуется)"
        case .system: return "Системный DNS"
        case .custom: return "Свой DNS-сервер"
        }
    }
}

public struct HelperConfig: Codable, Equatable, Sendable {
    public static let automaticInterface = "auto"

    public var rules: [RouteRule]
    /// Интерфейс физического шлюза: "auto" или BSD-имя интерфейса (например, en0)
    public var interface: String
    /// Интервал обновления адресов доменов (минуты)
    public var dnsRefreshMinutes: Int
    public var dnsMode: DNSMode
    public var customDNSServers: [String]
    /// Сколько часов удерживается маршрут на старый IP после смены адресов домена (чтобы ротация CDN не рвала открытые соединения)
    public var dnsRetentionHours: Int
    /// Пауза: удалить все маршруты, добавленные MacOSRoute, но сохранить правила
    public var paused: Bool
    /// Номер версии конфигурации — для обнаружения одновременных изменений (несколько окон или экземпляров приложения)
    public var revision: Int

    public init(rules: [RouteRule] = [], interface: String = HelperConfig.automaticInterface, dnsRefreshMinutes: Int = 10,
                dnsMode: DNSMode = .physical, customDNSServers: [String] = [], dnsRetentionHours: Int = 6,
                paused: Bool = false, revision: Int = 0) {
        self.rules = rules
        self.interface = interface
        self.dnsRefreshMinutes = dnsRefreshMinutes
        self.dnsMode = dnsMode
        self.customDNSServers = customDNSServers
        self.dnsRetentionHours = dnsRetentionHours
        self.paused = paused
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
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    /// Исправить значения вне допустимого диапазона
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

/// Физический шлюз (выход по умолчанию)
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

/// Сетевой интерфейс системы с IPv4-конфигурацией
public struct NetworkInterfaceInfo: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var router: String?
    public var localAddress: String?
    public var subnetMask: String?
    public var dnsServers: [String]
    /// Виртуальный интерфейс (туннель VPN и т. п.)
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
    /// Адреса правила (IP хоста или CIDR), включая удерживаемые старые адреса домена
    public var addresses: [String]
    /// Адреса, для которых маршрут через нужный выход сейчас подтверждён
    public var appliedAddresses: [String]
    /// Старые адреса домена, которые ещё удерживаются
    public var retainedAddresses: [String]
    public var error: String?
    public var warning: String?
    public var resolvedAt: Date?
    /// Фактический следующий узел, например "192.168.1.1 (en0)"
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

/// Маршрут, который сейчас поддерживает фоновая служба
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
    /// Ключ — RouteRule.id.uuidString
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
