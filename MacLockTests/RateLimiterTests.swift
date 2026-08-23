import XCTest
@testable import MacLock

final class RateLimiterTests: XCTestCase {
    func testPasswordSchedule() {
        XCTAssertEqual(RateLimiter.delaySeconds(kind: .password, failureCount: 1), 0)
        XCTAssertEqual(RateLimiter.delaySeconds(kind: .password, failureCount: 5), 30)
        XCTAssertEqual(RateLimiter.delaySeconds(kind: .password, failureCount: 10), 300)
        XCTAssertEqual(RateLimiter.delaySeconds(kind: .recovery, failureCount: 10), 60)
    }

    func testRemainingUsesUptimeNotWallClock() {
        let record = LockoutRecord(count: 5, delaySeconds: 30, startedUptime: 100, passwordHashPrefix: Data([1]))
        XCTAssertEqual(RateLimiter.remaining(record: record, uptime: 110), 20)
        XCTAssertEqual(RateLimiter.remaining(record: record, uptime: 140), 0)
    }
}
