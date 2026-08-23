import Foundation

final class PasswordStore: PasswordStoring {
    static let minimumLength = 4

    let secrets: GateSecretsStore
    let hasher: any PasswordHashing
    let clock: Clocking
    private let deriveQueue = DispatchQueue(label: "app.maclock.pbkdf2", qos: .userInitiated)

    init(secrets: GateSecretsStore, hasher: any PasswordHashing = LivePasswordHasher(), clock: Clocking) {
        self.secrets = secrets
        self.hasher = hasher
        self.clock = clock
    }

    func passwordQuery() -> KeychainQuery<PasswordRecord> {
        secrets.passwordQuery()
    }

    func verify(_ plaintext: String) async -> PasswordVerifyResult {
        await verifySecret(plaintext, kind: .password)
    }

    func verifyRecovery(_ plaintext: String) async -> PasswordVerifyResult {
        await verifySecret(CrockfordBase32.normalize(plaintext), kind: .recovery)
    }

    func setPassword(_ plaintext: String) async throws {
        try await setSecret(plaintext, accountWriter: secrets.setPasswordRecord)
        secrets.setLockout(nil, kind: .password)
    }

    func setRecoveryKey(_ displayOrRaw: String) async throws {
        let normalized = CrockfordBase32.normalize(displayOrRaw)
        try await setSecret(normalized, accountWriter: secrets.setRecoveryRecord)
        secrets.setLockout(nil, kind: .recovery)
    }

    func destroy() throws {
        try secrets.deletePassword()
    }

    func rotatePassword(_ newPassword: String, newRecoveryDisplay: String) async throws {
        try await setPassword(newPassword)
        try await setRecoveryKey(newRecoveryDisplay)
        secrets.writeCleanDisarm()
    }

    private func setSecret(_ plaintext: String, accountWriter: (PasswordRecord) throws -> Void) async throws {
        guard plaintext.count >= PasswordStore.minimumLength else {
            throw PasswordStoreError.tooShort(length: plaintext.count)
        }
        let salt = PasswordHasher.randomSalt()
        let iterations = hasher.iterations
        let digest = try await derive(plaintext, salt: salt, iterations: iterations)
        let record = PasswordRecord(
            version: 1,
            algorithm: PasswordHasher.algorithm,
            iterations: iterations,
            salt: salt,
            hash: digest
        )
        try accountWriter(record)
    }

    private func verifySecret(_ plaintext: String, kind: RateLimiterKind) async -> PasswordVerifyResult {
        let query: KeychainQuery<PasswordRecord> = kind == .password ? secrets.passwordQuery() : secrets.recoveryQuery()
        switch query {
        case .no:
            return .notSet
        case .unavailable(let status):
            return .keychainUnavailable(status)
        case .yes(let record):
            guard record.hash.count == PasswordHasher.derivedLength, !record.salt.isEmpty else {
                return .malformedRecord
            }
            let prefix = Data(record.hash.prefix(8))
            if case .yes(let lockout) = secrets.lockoutQuery(kind: kind),
               lockout.passwordHashPrefix == prefix {
                let remaining = RateLimiter.remaining(record: lockout, uptime: clock.uptime)
                if remaining > 0 {
                    return .lockedOut(remainingUptime: remaining)
                }
            }
            let digest = await deriveUnchecked(plaintext, salt: record.salt, iterations: record.iterations)
            if hasher.constantTimeEqual(digest, record.hash) {
                secrets.setLockout(nil, kind: kind)
                return .accepted
            }
            let existing: LockoutRecord?
            if case .yes(let rec) = secrets.lockoutQuery(kind: kind), rec.passwordHashPrefix == prefix {
                existing = rec
            } else {
                existing = nil
            }
            let next = RateLimiter.recordFailure(
                existing: existing,
                hashPrefix: prefix,
                uptime: clock.uptime,
                kind: kind
            )
            secrets.setLockout(next, kind: kind)
            if next.delaySeconds > 0 {
                return .lockedOut(remainingUptime: next.delaySeconds)
            }
            return .rejected
        }
    }

    private func derive(_ plaintext: String, salt: Data, iterations: Int) async throws -> Data {
        await deriveUnchecked(plaintext, salt: salt, iterations: iterations)
    }

    private func deriveUnchecked(_ plaintext: String, salt: Data, iterations: Int) async -> Data {
        let hasher = self.hasher
        return await withCheckedContinuation { cont in
            deriveQueue.async {
                cont.resume(returning: hasher.hash(password: plaintext, salt: salt, iterations: iterations))
            }
        }
    }
}
