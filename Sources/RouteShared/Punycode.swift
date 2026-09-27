import Foundation

/// Internationalized domain names (IDNA): промаркируем.бел -> xn--80akihieihjdc0b.xn--90ais.
/// Encoded by hand (RFC 3492): Foundation converts a URL host to Punycode only on newer macOS,
/// and the helper's own DNS client sends the name as is, so it must already be ASCII.
public enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    /// Converts each non-ASCII label of the host to the "xn--" form; ASCII labels stay as they are
    public static func asciiHost(_ host: String) -> String? {
        var labels: [String] = []
        for label in host.lowercased().split(separator: ".", omittingEmptySubsequences: false) {
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                labels.append(String(label))
            } else {
                guard let encoded = encode(String(label)) else { return nil }
                labels.append("xn--" + encoded)
            }
        }
        return labels.joined(separator: ".")
    }

    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = String(String.UnicodeScalarView(input.unicodeScalars.filter(\.isASCII)))
        let basicCount = output.unicodeScalars.count
        var handled = basicCount
        if basicCount > 0 { output += "-" }

        var n = initialN, delta = 0, bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                guard c == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, handled + 1, first: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return output
    }

    private static func digit(_ d: Int) -> Character {
        Character(UnicodeScalar(UInt8(d < 26 ? d + 97 : d + 22)))
    }

    private static func adapt(_ delta: Int, _ numPoints: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
