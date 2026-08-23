import Foundation

struct PasswordRecord: Codable, Equatable {
    var version: Int
    var algorithm: String
    var iterations: Int
    var salt: Data
    var hash: Data
}

enum KeychainQuery<Value: Equatable>: Equatable {
    case yes(Value)
    case no
    case unavailable(OSStatus)

    var isYes: Bool {
        if case .yes = self { return true }
        return false
    }

    var isNo: Bool {
        if case .no = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum PasswordVerifyResult: Equatable {
    case accepted
    case rejected
    case lockedOut(remainingUptime: TimeInterval)
    case notSet
    case malformedRecord
    case keychainUnavailable(OSStatus)
}

struct LockoutRecord: Codable, Equatable {
    var count: Int
    var delaySeconds: TimeInterval
    var startedUptime: TimeInterval
    var passwordHashPrefix: Data
}

protocol PasswordStoring {
    func passwordQuery() -> KeychainQuery<PasswordRecord>
    func verify(_ plaintext: String) async -> PasswordVerifyResult
    func setPassword(_ plaintext: String) async throws
    func destroy() throws
}

protocol GateSecretsStoring: AnyObject {
    func passwordQuery() -> KeychainQuery<PasswordRecord>
    func cleanDisarmQuery() -> KeychainQuery<Data>
    func writeCleanDisarm()
    func clearCleanDisarm()
}

enum PasswordStoreError: Error, Equatable, LocalizedError {
    case tooShort(length: Int)
    case mismatch
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tooShort(let length):
            return String(
                format: NSLocalizedString("maclock.error.tooshort", comment: ""),
                PasswordStore.minimumLength,
                length
            )
        case .mismatch:
            return NSLocalizedString("maclock.error.mismatch", comment: "")
        case .keychain(let status):
            return String(format: NSLocalizedString("maclock.error.keychain", comment: ""), Int(status))
        }
    }
}
