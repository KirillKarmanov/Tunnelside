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
            // The language changes on workQueue — read it there too
            engine.workQueue.async { reply(L("Invalid configuration format", "Некорректный формат конфигурации"), false) }
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
        // Only administrators may connect (they can change routes via sudo anyway)
        guard isAdministrator(uid: connection.effectiveUserIdentifier) else {
            FileHandle.standardError.write(Data("Rejected connection from non-admin uid=\(connection.effectiveUserIdentifier)\n".utf8))
            return false
        }
        if requireSignedClient {
            guard let requirement = Self.clientRequirement else {
                FileHandle.standardError.write(Data("Rejected: the helper was built without a certificate, so clients cannot be verified\n".utf8))
                return false
            }
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: RouteHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    /// The client must be the Tunnelside app signed with the same certificate as this service.
    /// Apple Developer certificate → check by Team ID; own (self-signed) certificate →
    /// check by the SHA-1 of the leaf certificate. A bundle ID alone is not enough: any program
    /// can fake it with `codesign -s - --identifier …`. A service without a certificate (ad-hoc)
    /// returns nil and rejects all clients.
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
        print("none: the helper is not signed with a certificate, all clients will be rejected")
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
    print("Physical gateway not found")
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
// For debugging: without root, keep data in a temporary folder and don't call route
let storage = isRoot
    ? URL(fileURLWithPath: RouteConstants.supportDirectory)
    : FileManager.default.temporaryDirectory.appendingPathComponent("TunnelsideHelperDev")

let engine = RouteEngine(storageDirectory: storage, system: LiveRouteSystem(dryRun: !isRoot))
engine.start()

let delegate = ListenerDelegate(service: HelperService(engine: engine), requireSignedClient: !arguments.contains("--allow-unsigned-clients"))
let listener = NSXPCListener(machServiceName: RouteConstants.machServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
