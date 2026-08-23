import Foundation

enum CrockfordBase32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ data: Data) -> String {
        var buffer: UInt64 = 0
        var bits = 0
        var out = ""
        out.reserveCapacity(26)
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((buffer >> bits) & 0x1F)
                out.append(alphabet[index])
            }
        }
        if bits > 0 {
            let index = Int((buffer << (5 - bits)) & 0x1F)
            out.append(alphabet[index])
        }
        return out
    }

    static func grouped(_ raw: String) -> String {
        var parts: [String] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            let j = raw.index(i, offsetBy: 5, limitedBy: raw.endIndex) ?? raw.endIndex
            parts.append(String(raw[i..<j]))
            i = j
        }
        return parts.joined(separator: "-")
    }

    static func normalize(_ input: String) -> String {
        let mapped = input.uppercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        return mapped.filter { alphabet.contains($0) }
    }
}

enum RecoveryKeyStore {
    static let rawByteCount = 16

    static func generateRaw() -> Data {
        var data = Data(count: rawByteCount)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, rawByteCount, $0.baseAddress!) }
        return data
    }

    static func displayString(from raw: Data) -> String {
        CrockfordBase32.encode(raw)
    }
}
