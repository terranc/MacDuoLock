import XCTest
@testable import MacLock

final class GateSecretsStoreTests: XCTestCase {
    func testCleanDisarmIndependentOfPassword() throws {
        let keychain = FakeKeychain()
        let store = GateSecretsStore(keychain: keychain)
        XCTAssertTrue(store.passwordQuery().isNo)
        XCTAssertTrue(store.cleanDisarmQuery().isNo)
        store.writeCleanDisarm()
        XCTAssertTrue(store.cleanDisarmQuery().isYes)
        store.clearCleanDisarm()
        XCTAssertTrue(store.cleanDisarmQuery().isNo)
    }

    func testUnavailableDoesNotLookLikeMissingPassword() {
        let keychain = FakeKeychain()
        keychain.unavailable = errSecInteractionNotAllowed
        let store = GateSecretsStore(keychain: keychain)
        XCTAssertTrue(store.passwordQuery().isUnavailable)
        XCTAssertFalse(store.passwordQuery().isNo)
    }
}
