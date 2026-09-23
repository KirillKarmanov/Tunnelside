import Foundation
import RouteShared

/// Следующий переход маршрута
public struct NextHop: Codable, Equatable, Hashable, Sendable {
    /// IP шлюза; nil — маршрут напрямую через interface (маршрут интерфейса, например VPN-туннель)
    public var gateway: String?
    public var interface: String?
    /// Ожидаемый локальный адрес источника — чтобы находить маршруты, оставшиеся со старым адресом после смены сети
    public var localAddress: String?

    public init(gateway: String?, interface: String?, localAddress: String? = nil) {
        self.gateway = gateway
        self.interface = interface
        self.localAddress = localAddress
    }

    public var label: String {
        switch (gateway, interface) {
        case let (g?, i?): return "\(g) (\(i))"
        case let (g?, nil): return g
        case let (nil, i?): return L("interface \(i)", "интерфейс \(i)")
        default: return "—"
        }
    }

    /// Соответствует ли маршрут в ядре уже этому следующему переходу
    public func isSatisfied(by entry: RouteEntry) -> Bool {
        if let gateway {
            guard entry.gateway == gateway else { return false }
        } else {
            guard entry.gateway == nil, !entry.hasGateway else { return false }
        }
        if let interface, entry.interface != interface { return false }
        if let localAddress, let ifa = entry.interfaceAddress, ifa != localAddress { return false }
        return true
    }
}

/// Все зависимости движка от ОС — чтобы в тестах подменять их имитацией
public protocol RouteSystem: AnyObject {
    func networkSnapshot(preferredInterface: String) -> GatewayDetector.Snapshot
    func routingTable() -> [RouteEntry]
    func addRoute(_ address: String, via hop: NextHop) -> Result<Void, RouteToolError>
    func deleteRoute(_ address: String) -> Result<Void, RouteToolError>
    func resolve(_ domain: String, mode: DNSMode, customServers: [String], physical: NetworkInterfaceInfo?) -> Result<[String], ResolveError>
}

public final class LiveRouteSystem: RouteSystem {
    private let dryRun: Bool
    private let lock = NSLock()
    /// Маршруты, «добавленные» в режиме dryRun
    private var simulated: [String: RouteEntry] = [:]

    /// При dryRun = true команда route не выполняется (отладка без root)
    public init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    public func networkSnapshot(preferredInterface: String) -> GatewayDetector.Snapshot {
        GatewayDetector.snapshot(preferredInterface: preferredInterface)
    }

    public func routingTable() -> [RouteEntry] {
        let table = RoutingTable.dump()
        guard dryRun else { return table }
        lock.lock(); defer { lock.unlock() }
        return table.filter { simulated[$0.address] == nil } + simulated.values
    }

    public func addRoute(_ address: String, via hop: NextHop) -> Result<Void, RouteToolError> {
        if dryRun {
            let parts = address.split(separator: "/")
            let entry = RouteEntry(destination: String(parts[0]), prefix: parts.count == 2 ? Int(parts[1]) ?? 32 : 32,
                                   gateway: hop.gateway, interface: hop.interface ?? "?", interfaceAddress: hop.localAddress,
                                   flags: RTF_UP | RTF_STATIC | (hop.gateway != nil ? RTF_GATEWAY : 0) | (parts.count == 1 ? RTF_HOST : 0))
            lock.lock(); simulated[address] = entry; lock.unlock()
            return .success(())
        }
        return RouteTool.add(address, via: hop)
    }

    public func deleteRoute(_ address: String) -> Result<Void, RouteToolError> {
        if dryRun {
            lock.lock(); simulated[address] = nil; lock.unlock()
            return .success(())
        }
        return RouteTool.delete(address)
    }

    public func resolve(_ domain: String, mode: DNSMode, customServers: [String], physical: NetworkInterfaceInfo?) -> Result<[String], ResolveError> {
        DNSResolver.resolve(domain, mode: mode, customServers: customServers, physical: physical)
    }
}
