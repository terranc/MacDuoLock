import Foundation
import Security

protocol KeychainClient: AnyObject {
    func get(account: String) -> KeychainQuery<Data>
    func set(account: String, data: Data) throws
    func delete(account: String) throws
}

enum KeychainAccount {
    static let service = "app.maclock"
    static let password = "gate-password-v1"
    static let recovery = "gate-recovery-v1"
    static let cleanDisarm = "gate-clean-disarm-v1"
    static let passwordLockout = "gate-lockout-v1"
    static let recoveryLockout = "gate-recovery-lockout-v1"
    static let policy = "gate-policy-v1"
}

final class FileSecretStore {
    private var directory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("MacLock/secrets", isDirectory: true)
    }

    func url(for account: String) -> URL {
        directory.appendingPathComponent(account)
    }

    func get(account: String) -> KeychainQuery<Data> {
        let path = url(for: account)
        if !FileManager.default.fileExists(atPath: path.path) { return .no }
        do {
            return .yes(try Data(contentsOf: path))
        } catch {
            return .unavailable(OSStatus(errSecIO))
        }
    }

    func set(account: String, data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: account), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: account).path)
    }

    func delete(account: String) throws {
        let path = url(for: account)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

final class LiveKeychainClient: KeychainClient {
    private let files = FileSecretStore()

    func get(account: String) -> KeychainQuery<Data> {
        let protected = copyMatching(account: account, dataProtection: true)
        if case .yes = protected { return protected }
        let file = files.get(account: account)
        if case .yes = file { return file }
        // File-based keychain ACLs block LSUIElement apps waiting for a hidden
        // Allow sheet. Never query it on the launch path.
        if case .unavailable = protected { return protected }
        return file
    }

    private func copyMatching(account: String, dataProtection: Bool) -> KeychainQuery<Data> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainAccount.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .no }
        if status == errSecSuccess, let data = result as? Data { return .yes(data) }
        return .unavailable(status)
    }

    func set(account: String, data: Data) throws {
        try? addItem(account: account, data: data, dataProtection: true)
        try files.set(account: account, data: data)
    }

    private func addItem(account: String, data: Data, dataProtection: Bool) throws {
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainAccount.service,
            kSecAttrAccount as String: account,
        ]
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainAccount.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        if dataProtection {
            deleteQuery[kSecUseDataProtectionKeychain as String] = true
            add[kSecUseDataProtectionKeychain as String] = true
        }
        SecItemDelete(deleteQuery as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { throw PasswordStoreError.keychain(status) }
    }

    func delete(account: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainAccount.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        try files.delete(account: account)
    }
}
