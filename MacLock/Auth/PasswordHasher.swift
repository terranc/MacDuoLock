import CommonCrypto
import Foundation

protocol PasswordHashing: Sendable {
    var iterations: Int { get }
    func hash(password: String, salt: Data, iterations: Int) -> Data
    func constantTimeEqual(_ a: Data, _ b: Data) -> Bool
}

enum PasswordHasher {
    static let iterations = 200_000
    static let saltLength = 16
    static let derivedLength = 32
    static let algorithm = "pbkdf2-hmac-sha256-v1"

    static func hash(password: String, salt: Data, iterations: Int = iterations) -> Data {
        var derived = Data(count: derivedLength)
        password.withCString { pwPtr in
            salt.withUnsafeBytes { saltRaw in
                derived.withUnsafeMutableBytes { outRaw in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr,
                        password.utf8.count,
                        saltRaw.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outRaw.bindMemory(to: UInt8.self).baseAddress,
                        derivedLength
                    )
                }
            }
        }
        return derived
    }

    /// Length mismatch still scans max(count) so timing does not leak length as an early return.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        let n = max(a.count, b.count)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        if n == 0 { return a.count == b.count }
        for i in 0..<n {
            let av: UInt8 = i < a.count ? a[i] : 0
            let bv: UInt8 = i < b.count ? b[i] : 0
            diff |= av ^ bv
        }
        return diff == 0
    }

    static func randomSalt() -> Data {
        var salt = Data(count: saltLength)
        salt.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, ptr.baseAddress!)
        }
        return salt
    }
}

struct LivePasswordHasher: PasswordHashing, Sendable {
    var iterations: Int { PasswordHasher.iterations }

    func hash(password: String, salt: Data, iterations: Int) -> Data {
        PasswordHasher.hash(password: password, salt: salt, iterations: iterations)
    }

    func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        PasswordHasher.constantTimeEqual(a, b)
    }
}
