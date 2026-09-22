import CryptoKit
import Darwin
import Foundation
import RouteHelperCore
import Security
import RouteShared

final class HelperService: NSObject, RouteHelperProtocol {
    private let engine: RouteEngine

    init(engine: RouteEngine) {
        self.engine = engine
    }

    func fetchState(withReply reply: @escaping (Data?, String?) -> Void) {
        do {
            reply(try RouteJSON.encoder().encode(engine.currentState()), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func updateConfig(_ configData: Data, withReply reply: @escaping (String?, Bool) -> Void) {
        guard let config = try? RouteJSON.decoder().decode(HelperConfig.self, from: configData) else {
            reply("Некорректный формат конфигурации", false)
            return
        }
        engine.updateConfig(config, completion: reply)
    }

    func reapplyAll(withReply reply: @escaping (String?) -> Void) {
        engine.reapplyAll(completion: reply)
    }

    func removeAllRoutes(withReply reply: @escaping (String?) -> Void) {
        engine.removeAllRoutes(completion: reply)
    }

    func deleteSystemRoutes(_ addresses: [String], withReply reply: @escaping (String?) -> Void) {
        engine.deleteSystemRoutes(addresses, completion: reply)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService
    private let requireSignedClient: Bool

    init(service: HelperService, requireSignedClient: Bool) {
        self.service = service
        self.requireSignedClient = requireSignedClient
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Подключаться могут только администраторы (они и так могут менять маршруты через sudo)
        guard isAdministrator(uid: connection.effectiveUserIdentifier) else {
            FileHandle.standardError.write(Data("Отклонено подключение не-администратора uid=\(connection.effectiveUserIdentifier)\n".utf8))
            return false
        }
        if requireSignedClient {
            guard let requirement = Self.clientRequirement else {
                FileHandle.standardError.write(Data("Отказ: служба собрана без сертификата, проверить клиента нечем\n".utf8))
                return false
            }
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: RouteHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    /// Клиент обязан быть приложением MacOSRoute, подписанным тем же сертификатом, что и эта служба.
    /// Сертификат Apple Developer → проверка по Team ID; собственный (самоподписанный) сертификат →
    /// проверка по SHA-1 листового сертификата. Одного bundle ID мало: его подделает любая
    /// программа через `codesign -s - --identifier …`. Служба без сертификата (ad-hoc)
    /// возвращает nil и отказывает всем клиентам.
    static let clientRequirement: String? = {
        let identifier = "identifier \"\(RouteConstants.appBundleID)\""
        let info = ownSigningInformation()
        if let team = info?[kSecCodeInfoTeamIdentifier as String] as? String {
            return identifier + " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        if let certificates = info?[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            let der = SecCertificateCopyData(leaf) as Data
            let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
            return identifier + " and certificate leaf = H\"\(sha1)\""
        }
        return nil
    }()

    private static func ownSigningInformation() -> [String: Any]? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    private func isAdministrator(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let pw = getpwuid(uid), let admin = getgrnam("admin") else { return false }
        let adminGID = admin.pointee.gr_gid
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        if getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count) != -1,
           groups.prefix(Int(count)).contains(Int32(bitPattern: adminGID)) {
            return true
        }
        let name = String(cString: pw.pointee.pw_name)
        var member = admin.pointee.gr_mem
        while let m = member?.pointee {
            if String(cString: m) == name { return true }
            member = member?.advanced(by: 1)
        }
        return false
    }
}

let arguments = CommandLine.arguments

if arguments.contains("--print-client-requirement") {
    guard let requirement = ListenerDelegate.clientRequirement else {
        print("нет: служба не подписана сертификатом, клиенты будут отклоняться")
        exit(1)
    }
    print(requirement)
    exit(0)
}

if arguments.contains("--print-gateway") {
    let preferred = arguments.firstIndex(of: "--interface").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? HelperConfig.automaticInterface
    let snapshot = GatewayDetector.snapshot(preferredInterface: preferred)
    for info in snapshot.interfaces {
        print("\(info.name)\t router=\(info.router ?? "-") address=\(info.localAddress ?? "-") dns=\(info.dnsServers.joined(separator: ",")) virtual=\(info.isVirtual)")
    }
    if let gw = snapshot.physical {
        print("physical: interface=\(gw.interface) router=\(gw.router)")
        exit(0)
    }
    print("Физический шлюз не найден")
    exit(1)
}

if let index = arguments.firstIndex(of: "--resolve"), arguments.indices.contains(index + 1) {
    let physical = GatewayDetector.snapshot(preferredInterface: HelperConfig.automaticInterface).physicalInterface
    let servers = arguments.firstIndex(of: "--server").flatMap { arguments.indices.contains($0 + 1) ? [arguments[$0 + 1]] : nil } ?? []
    for mode in DNSMode.allCases where mode != .custom || !servers.isEmpty {
        let result = DNSResolver.resolve(arguments[index + 1], mode: mode, customServers: servers, physical: physical)
        switch result {
        case .success(let ips): print("\(mode.rawValue): \(ips.joined(separator: ", "))")
        case .failure(let error): print("\(mode.rawValue): \(error)")
        }
    }
    exit(0)
}

let isRoot = getuid() == 0
// Для отладки: без root хранить данные во временной папке и не вызывать route
let storage = isRoot
    ? URL(fileURLWithPath: RouteConstants.supportDirectory)
    : FileManager.default.temporaryDirectory.appendingPathComponent("MacOSRouteHelperDev")

let engine = RouteEngine(storageDirectory: storage, system: LiveRouteSystem(dryRun: !isRoot))
engine.start()

let delegate = ListenerDelegate(service: HelperService(engine: engine), requireSignedClient: !arguments.contains("--allow-unsigned-clients"))
let listener = NSXPCListener(machServiceName: RouteConstants.machServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
