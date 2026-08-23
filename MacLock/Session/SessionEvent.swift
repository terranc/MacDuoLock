import Foundation

enum GateState: Equatable {
    case disarmed, monitoring, checkingPresence, unlocked, shielded
}

struct SessionSnapshot: Equatable {
    var screenLocked: Bool
    var onConsole: Bool
}

enum SessionEvent: Equatable {
    case didLaunch(SessionSnapshot)
    case armVerified
    case disarmVerified
    case recoveryVerified
    case passwordRotated
    case screenLocked
    case screenUnlocked
    case presenceMatched(PresenceEvidence)
    case presenceTimeout(generation: UInt64)
    case passwordVerified
    case passwordRejected
    case screensChanged
    case didWake(SessionSnapshot)
    case reconcile(SessionSnapshot)
    case keychainBecameAvailable
}
