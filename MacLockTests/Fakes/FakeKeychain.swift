import Foundation
@testable import MacLock

final class FakeKeychain: KeychainClient {
    var storage: [String: Data] = [:]
    var unavailable: OSStatus?

    func get(account: String) -> KeychainQuery<Data> {
        if let unavailable { return .unavailable(unavailable) }
        if let data = storage[account] { return .yes(data) }
        return .no
    }

    func set(account: String, data: Data) throws {
        if let unavailable { throw PasswordStoreError.keychain(unavailable) }
        storage[account] = data
    }

    func delete(account: String) throws {
        storage.removeValue(forKey: account)
    }

    func getAsForeignApp(account: String) -> KeychainQuery<Data> {
        .unavailable(errSecAuthFailed)
    }
}

@MainActor
final class FakeSecrets: GateSecretsStoring {
    var password: KeychainQuery<PasswordRecord> = .no
    var disarm: KeychainQuery<Data> = .no

    func passwordQuery() -> KeychainQuery<PasswordRecord> { password }
    func cleanDisarmQuery() -> KeychainQuery<Data> { disarm }
    func writeCleanDisarm() { disarm = .yes(Data([1, 2, 3, 4])) }
    func clearCleanDisarm() { disarm = .no }

    static func record() -> PasswordRecord {
        PasswordRecord(
            version: 1,
            algorithm: PasswordHasher.algorithm,
            iterations: PasswordHasher.iterations,
            salt: Data(repeating: 9, count: 16),
            hash: Data(repeating: 7, count: 32)
        )
    }
}
