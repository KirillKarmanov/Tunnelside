import Foundation
import RouteShared

/// Обёртка над /sbin/route. Формат адреса: хост — "1.2.3.4", подсеть — "10.0.0.0/8".
/// Таблица маршрутов читается через RoutingTable (sysctl), здесь — только изменения и точечные запросы.
public enum RouteTool {
    public struct RouteInfo: Equatable, Sendable {
        public var destination: String?
        public var mask: String?
        public var gateway: String?
        public var interface: String?
        public var flags: [String]
    }

    public struct CommandResult {
        public var status: Int32
        public var output: String
        public var succeeded: Bool { status == 0 }
    }

    @discardableResult
    public static func run(_ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(status: process.terminationStatus, output: output)
    }

    /// Возвращает ["-host", "1.2.3.4"] или ["-net", "10.0.0.0/8"]
    static func destinationArguments(_ address: String) -> [String] {
        address.contains("/") ? ["-net", address] : ["-host", address]
    }

    public static func addArguments(_ address: String, via hop: NextHop) -> [String]? {
        var args = ["-n", "add"] + destinationArguments(address)
        if let gateway = hop.gateway {
            args.append(gateway)
        } else if let interface = hop.interface {
            args += ["-interface", interface]
        } else {
            return nil
        }
        return args
    }

    public static func add(_ address: String, via hop: NextHop) -> Result<Void, RouteToolError> {
        guard let args = addArguments(address, via: hop) else { return .failure(RouteToolError(message: L("No gateway or interface specified", "Не указан шлюз или интерфейс"))) }
        let result = run(args)
        return result.succeeded ? .success(()) : .failure(RouteToolError(message: result.output))
    }

    public static func delete(_ address: String) -> Result<Void, RouteToolError> {
        let result = run(["-n", "delete"] + destinationArguments(address))
        return result.succeeded ? .success(()) : .failure(RouteToolError(message: result.output))
    }

    /// Запрашивает маршрут, который ядро фактически выбирает для адреса (самый длинный префикс), root не нужен
    public static func get(_ address: String) -> RouteInfo? {
        let result = run(["-n", "get"] + destinationArguments(address))
        guard result.succeeded else { return nil }
        return parseGetOutput(result.output)
    }

    public static func parseGetOutput(_ output: String) -> RouteInfo {
        var info = RouteInfo(flags: [])
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "destination": info.destination = value
            case "mask": info.mask = value
            case "gateway": info.gateway = value
            case "interface": info.interface = value
            case "flags":
                info.flags = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).split(separator: ",").map(String.init)
            default: break
            }
        }
        return info
    }
}

public struct RouteToolError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }

    public init(message: String) {
        self.message = message
    }
}
