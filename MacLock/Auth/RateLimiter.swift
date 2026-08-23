import Foundation

enum RateLimiterKind: Equatable {
    case password
    case recovery
}

enum RateLimiter {
    static func delaySeconds(kind: RateLimiterKind, failureCount: Int) -> TimeInterval {
        switch (kind, failureCount) {
        case (_, 1), (_, 2):
            return 0
        case (_, 3), (_, 4):
            return 2
        case (_, 5), (_, 6), (_, 7):
            return 30
        case (.password, 8), (.password, 9):
            return 120
        case (.password, let n) where n >= 10:
            return 300
        case (.recovery, let n) where n >= 8:
            return 60
        default:
            return 0
        }
    }

    static func remaining(record: LockoutRecord, uptime: TimeInterval) -> TimeInterval {
        let elapsed = max(0, uptime - record.startedUptime)
        return max(0, record.delaySeconds - elapsed)
    }

    static func recordFailure(
        existing: LockoutRecord?,
        hashPrefix: Data,
        uptime: TimeInterval,
        kind: RateLimiterKind
    ) -> LockoutRecord {
        let nextCount = (existing?.count ?? 0) + 1
        return LockoutRecord(
            count: nextCount,
            delaySeconds: delaySeconds(kind: kind, failureCount: nextCount),
            startedUptime: uptime,
            passwordHashPrefix: hashPrefix
        )
    }
}
