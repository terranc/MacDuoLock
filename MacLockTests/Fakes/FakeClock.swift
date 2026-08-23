import Foundation
@testable import MacLock

final class FakeClock: Clocking {
    var uptime: TimeInterval = 1_000
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { cont in
            waiters.append(cont)
        }
    }

    func advance(_ seconds: TimeInterval) {
        uptime += seconds
    }

    func fireSleep() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}
