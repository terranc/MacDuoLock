import XCTest
@testable import MacLock

@MainActor
final class PasswordStoreTests: XCTestCase {
    func testPBKDF2RoundTripUses200k() async throws {
        XCTAssertEqual(PasswordHasher.iterations, 200_000)
        let keychain = FakeKeychain()
        let secrets = GateSecretsStore(keychain: keychain)
        let clock = FakeClock()
        let store = PasswordStore(secrets: secrets, hasher: LivePasswordHasher(), clock: clock)
        try await store.setPassword("correcthorse")
        let accepted = await store.verify("correcthorse")
        XCTAssertEqual(accepted, .accepted)
        let rejected = await store.verify("wronghorse")
        XCTAssertEqual(rejected, .rejected)
        if case .yes(let record) = store.passwordQuery() {
            XCTAssertEqual(record.iterations, 200_000)
            XCTAssertEqual(record.algorithm, "pbkdf2-hmac-sha256-v1")
            XCTAssertEqual(record.salt.count, 16)
            XCTAssertEqual(record.hash.count, 32)
        } else {
            XCTFail("expected stored record")
        }
    }

    func testConstantTimeEqualScansMismatchedLengths() {
        let a = Data([1, 2, 3, 4])
        let b = Data([1, 2])
        XCTAssertFalse(PasswordHasher.constantTimeEqual(a, b))
        XCTAssertFalse(PasswordHasher.constantTimeEqual(b, a))
        XCTAssertTrue(PasswordHasher.constantTimeEqual(a, a))
    }

    func testDeriveDoesNotRunOnMainActor() async throws {
        let keychain = FakeKeychain()
        let secrets = GateSecretsStore(keychain: keychain)
        let clock = FakeClock()
        let hasher = RecordingHasher()
        let store = PasswordStore(secrets: secrets, hasher: hasher, clock: clock)
        try await store.setPassword("abcdefgh")
        _ = await store.verify("abcdefgh")
        XCTAssertFalse(hasher.ranOnMain.isEmpty)
        XCTAssertFalse(hasher.ranOnMain.contains(true))
    }

    func testShortPasswordRejected() async {
        let store = PasswordStore(secrets: GateSecretsStore(keychain: FakeKeychain()), clock: FakeClock())
        do {
            try await store.setPassword("abc")
            XCTFail("expected tooShort")
        } catch PasswordStoreError.tooShort(length: let length) {
            XCTAssertEqual(length, 3)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testWrongPasswordLockoutOnFifthFailure() async throws {
        let store = PasswordStore(secrets: GateSecretsStore(keychain: FakeKeychain()), clock: FakeClock())
        try await store.setPassword("abcdefgh")
        let first = await store.verify("badbadbad")
        let second = await store.verify("badbadbad")
        XCTAssertEqual(first, .rejected)
        XCTAssertEqual(second, .rejected)
        let third = await store.verify("badbadbad")
        guard case .lockedOut = third else {
            return XCTFail("expected lockout on 3rd failure per delay table, got \(third)")
        }
    }

    func testKeychainUnavailableIsNotNotSet() async {
        let keychain = FakeKeychain()
        keychain.unavailable = errSecInteractionNotAllowed
        let store = PasswordStore(secrets: GateSecretsStore(keychain: keychain), clock: FakeClock())
        let result = await store.verify("abcdefgh")
        guard case .keychainUnavailable(let status) = result else {
            return XCTFail("got \(result)")
        }
        XCTAssertEqual(status, errSecInteractionNotAllowed)
        XCTAssertNotEqual(result, .notSet)
    }

    func testLockoutPersistsAcrossStoreInstancesUntilUptimeElapses() async throws {
        let keychain = FakeKeychain()
        let clock = FakeClock()
        let store = PasswordStore(secrets: GateSecretsStore(keychain: keychain), hasher: LivePasswordHasher(), clock: clock)
        try await store.setPassword("abcdefgh")
        for _ in 1...5 { _ = await store.verify("nopeeeee") }
        let again = PasswordStore(secrets: GateSecretsStore(keychain: keychain), hasher: LivePasswordHasher(), clock: clock)
        let locked = await again.verify("abcdefgh")
        guard case .lockedOut = locked else { return XCTFail("\(locked)") }
        clock.advance(31)
        let after = await again.verify("abcdefgh")
        XCTAssertEqual(after, .accepted)
    }

    func testChangingPasswordInvalidatesLockout() async throws {
        let keychain = FakeKeychain()
        let clock = FakeClock()
        let store = PasswordStore(secrets: GateSecretsStore(keychain: keychain), clock: clock)
        try await store.setPassword("abcdefgh")
        for _ in 1...5 { _ = await store.verify("nopeeeee") }
        try await store.setPassword("newnewnew")
        let result = await store.verify("newnewnew")
        XCTAssertEqual(result, .accepted)
    }

    func testRecoveryLimiterIndependentOfPassword() async throws {
        let keychain = FakeKeychain()
        let clock = FakeClock()
        let store = PasswordStore(secrets: GateSecretsStore(keychain: keychain), clock: clock)
        try await store.setPassword("abcdefgh")
        try await store.setRecoveryKey("0123456789ABCDEFGHJKMNPQRS")
        for _ in 1...10 { _ = await store.verify("nopeeeee") }
        let recovery = await store.verifyRecovery("0123456789ABCDEFGHJKMNPQRS")
        XCTAssertEqual(recovery, .accepted)
    }

    func testForeignAppReadFails() {
        let keychain = FakeKeychain()
        keychain.storage[KeychainAccount.password] = Data([1])
        let foreign = keychain.getAsForeignApp(account: KeychainAccount.password)
        XCTAssertTrue(foreign.isUnavailable)
    }

    func testLiveKeychainWriteThenReadSameBytes() throws {
        let client = LiveKeychainClient()
        let account = "gate-test-roundtrip-v1"
        let payload = Data("maclock-live-keychain-roundtrip".utf8)
        try? client.delete(account: account)
        try client.set(account: account, data: payload)
        let query = client.get(account: account)
        try client.delete(account: account)
        guard case .yes(let data) = query else {
            return XCTFail("expected yes, got \(query)")
        }
        XCTAssertEqual(data, payload)
    }
}

final class RecordingHasher: PasswordHashing, @unchecked Sendable {
    var iterations: Int { 1 }
    var ranOnMain: [Bool] = []
    private let lock = NSLock()

    func hash(password: String, salt: Data, iterations: Int) -> Data {
        let main = Thread.isMainThread
        lock.lock()
        ranOnMain.append(main)
        lock.unlock()
        return PasswordHasher.hash(password: password, salt: salt, iterations: max(1, iterations))
    }

    func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        PasswordHasher.constantTimeEqual(a, b)
    }
}
