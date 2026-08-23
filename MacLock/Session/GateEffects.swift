import Foundation

struct GateEffects: Equatable {
    var overlay: OverlayCommand = .stay
    var tap: TapCommand = .stay
    var presence: PresenceCommand = .stay
    var bumpGeneration: Bool = false
    var ui: UICommand = .none
}

enum OverlayCommand: Equatable {
    case stay
    case present(OverlayReason)
    case dismissSync
}

enum OverlayReason: Equatable {
    case waitTimeout
    case passwordOnly
    case relaunchWhileUnlocked
    case keychainUnavailable
    case recoveryRotate
    /// Explicit lock (menu / chord). Must not auto-dismiss on nearby iPhone.
    case lockNow
}

enum TapCommand: Equatable {
    case stay, start, stop
}

enum PresenceCommand: Equatable {
    case stay
    case start(generation: UInt64)
    case stop
}

enum UICommand: Equatable {
    case none
    case onboarding
    case shakePassword
    case applyLockout
    case rotatePassword
    case keychainWaiting
}

protocol OverlayCommanding: AnyObject {
    var isPresented: Bool { get }
    var lastReason: OverlayReason? { get }
    var dismissSyncCount: Int { get }
    var rebuildCount: Int { get }
    func apply(_ command: OverlayCommand)
    func dismissSync()
    func rebuild()
}

protocol TapCommanding: AnyObject {
    func startTap()
    func stopTap()
}

protocol PresenceControlling: AnyObject {
    func start(generation: UInt64)
    func stop()
}

protocol Clocking: AnyObject {
    var uptime: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

final class SystemClock: Clocking {
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
