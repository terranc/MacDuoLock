import Foundation

struct GatePolicy: Codable, Equatable {
    var presenceEnabled: Bool
    var autoDismissOnPresenceWhileShielded: Bool

    static let v1Default = GatePolicy(presenceEnabled: false, autoDismissOnPresenceWhileShielded: false)
}

final class GateSecretsStore: GateSecretsStoring {
    let keychain: KeychainClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(keychain: KeychainClient) {
        self.keychain = keychain
    }

    func passwordQuery() -> KeychainQuery<PasswordRecord> {
        decode(PasswordRecord.self, account: KeychainAccount.password)
    }

    func cleanDisarmQuery() -> KeychainQuery<Data> {
        keychain.get(account: KeychainAccount.cleanDisarm)
    }

    func writeCleanDisarm() {
        var token = Data(count: 16)
        token.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        try? keychain.set(account: KeychainAccount.cleanDisarm, data: token)
    }

    func clearCleanDisarm() {
        try? keychain.delete(account: KeychainAccount.cleanDisarm)
    }

    func lockoutQuery(kind: RateLimiterKind) -> KeychainQuery<LockoutRecord> {
        decode(LockoutRecord.self, account: kind == .password ? KeychainAccount.passwordLockout : KeychainAccount.recoveryLockout)
    }

    func setLockout(_ record: LockoutRecord?, kind: RateLimiterKind) {
        let account = kind == .password ? KeychainAccount.passwordLockout : KeychainAccount.recoveryLockout
        if let record {
            if let data = try? encoder.encode(record) {
                try? keychain.set(account: account, data: data)
            }
        } else {
            try? keychain.delete(account: account)
        }
    }

    func policyQuery() -> KeychainQuery<GatePolicy> {
        decode(GatePolicy.self, account: KeychainAccount.policy)
    }

    func setPolicy(_ policy: GatePolicy) throws {
        let data = try encoder.encode(policy)
        try keychain.set(account: KeychainAccount.policy, data: data)
    }

    func setPasswordRecord(_ record: PasswordRecord) throws {
        let data = try encoder.encode(record)
        try keychain.set(account: KeychainAccount.password, data: data)
    }

    func recoveryQuery() -> KeychainQuery<PasswordRecord> {
        decode(PasswordRecord.self, account: KeychainAccount.recovery)
    }

    func setRecoveryRecord(_ record: PasswordRecord) throws {
        let data = try encoder.encode(record)
        try keychain.set(account: KeychainAccount.recovery, data: data)
    }

    func deletePassword() throws {
        try keychain.delete(account: KeychainAccount.password)
    }

    private func decode<T: Decodable & Equatable>(_ type: T.Type, account: String) -> KeychainQuery<T> {
        switch keychain.get(account: account) {
        case .no:
            return .no
        case .unavailable(let s):
            return .unavailable(s)
        case .yes(let data):
            if let value = try? decoder.decode(T.self, from: data) {
                return .yes(value)
            }
            return .unavailable(errSecDecode)
        }
    }
}
