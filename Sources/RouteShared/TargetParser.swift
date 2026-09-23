import Foundation

public enum RouteTarget: Equatable, Sendable {
    case host(String)
    /// Normalized network address and prefix length
    case network(String, prefix: Int)
    case domain(String)

    public var kindLabel: String {
        switch self {
        case .host: return "IP"
        case .network: return L("Subnet", "Подсеть")
        case .domain: return L("Domain", "Домен")
        }
    }
}

public enum TargetParser {
    /// The widest allowed subnet. Rules wider than /8 (0.0.0.0/0, pairs of /1, etc.) would send
    /// almost the whole internet around the VPN with one line — neither the interface nor the service accepts them.
    public static let minimumPrefix = 8

    public static func parse(_ raw: String) -> RouteTarget? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // A full URL can be pasted: https://example.com:8443/path -> example.com
        if s.contains("://"), let host = URLComponents(string: s)?.host {
            s = host
        }

        if let slash = s.firstIndex(of: "/") {
            let addr = String(s[..<slash])
            guard let prefix = Int(s[s.index(after: slash)...]), (minimumPrefix...32).contains(prefix),
                  let value = ipv4Value(addr) else { return nil }
            if prefix == 32 { return .host(ipv4String(value)) }
            return .network(ipv4String(value & maskValue(prefix: prefix)), prefix: prefix)
        }

        if let value = ipv4Value(s) {
            return .host(ipv4String(value))
        }

        // Looks like an IP but is invalid (for example, 1.2.3.256) — don't treat it as a domain
        if s.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }

        let host = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return isValidHostname(host) ? .domain(host) : nil
    }

    /// Split user input into addresses by spaces, commas and semicolons
    public static func splitInput(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: " \t\n\r,;，；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func ipv4Value(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = value << 8 | octet
        }
        return value
    }

    public static func ipv4String(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    public static func netmask(prefix: Int) -> String {
        ipv4String(maskValue(prefix: prefix))
    }

    public static func maskValue(prefix: Int) -> UInt32 {
        prefix <= 0 ? 0 : prefix >= 32 ? ~UInt32(0) : ~UInt32(0) << UInt32(32 - prefix)
    }

    public static func prefixLength(mask: String) -> Int? {
        ipv4Value(mask).map { $0.nonzeroBitCount }
    }

    /// Whether ip is in the subnet address/mask
    public static func sameSubnet(_ ip: String, _ address: String, mask: String) -> Bool {
        guard let a = ipv4Value(ip), let b = ipv4Value(address), let m = ipv4Value(mask) else { return false }
        return a & m == b & m
    }

    /// Fake-IP subnet of proxies like Surge / Clash: 198.18.0.0/15
    public static func isFakeIP(_ ip: String) -> Bool {
        guard let v = ipv4Value(ip) else { return false }
        return v & maskValue(prefix: 15) == 0xC612_0000
    }

    /// Domain addresses that must not be routed
    public static func isUnroutableResolution(_ ip: String) -> Bool {
        guard let v = ipv4Value(ip) else { return true }
        return v == 0 || v >> 24 == 127 || v >> 28 == 0xE || v == ~UInt32(0)
    }

    private static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= 63,
                  label.unicodeScalars.allSatisfy(allowed.contains),
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        }
        return true
    }
}
