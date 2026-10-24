import XCTest
@testable import MacLock

@MainActor
final class ScreenLockMonitorTests: XCTestCase {
    private let locked = SessionSnapshot(screenLocked: true, onConsole: true)
    private let unlocked = SessionSnapshot(screenLocked: false, onConsole: true)
    private let application = RemoteSessionStatus.application(bundleIdentifier: "com.netease.uuremote", processIdentifier: 123)
    private var overlay: OverlaySpy!
    private var presence: PresenceSpy!
    private var clock: FakeClock!
    private var detector: LiveRemoteSessionDetector!
    private var gate: SessionGate!
    private var monitor: ScreenLockMonitor!
    private var status = RemoteSessionStatus.unavailable
    private var snapshot = SessionSnapshot(screenLocked: false, onConsole: true)
    private var sourceIsAvailable = true
    private var readCount = 0
    private var changes: [Bool] = []

    override func setUp() {
        overlay = OverlaySpy()
        presence = PresenceSpy()
        clock = FakeClock()
        status = .unavailable
        snapshot = unlocked
        sourceIsAvailable = true
        readCount = 0
        changes = []
        detector = LiveRemoteSessionDetector(readStatus: { [unowned self] in
            self.readCount += 1
            return self.status
        }, clock: clock, sourceAvailable: { [unowned self] _ in self.sourceIsAvailable })
        let secrets = FakeSecrets()
        secrets.password = .yes(FakeSecrets.record())
        secrets.disarm = .no
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: TapSpy(), presence: presence, clock: clock)
        gate.skipShieldForRemoteSession = true
        gate.isRemoteSessionActive = { [unowned self] in self.detector.isActive }
        monitor = ScreenLockMonitor(overlay: overlay, gate: gate,
                                    snapshotProvider: { [unowned self] in self.snapshot }, remote: detector)
        detector.onChange = { [unowned self] active in
            self.changes.append(active)
            self.monitor.handleSessionEvent(.reconcile(self.snapshot))
        }
    }

    private func beginRemoteDesktop() {
        status = application
        detector.refresh()
        monitor.handleSessionEvent(.didLaunch(unlocked))
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    private func lockWithUnavailableAccessibility() {
        status = .unavailable
        snapshot = locked
        monitor.noteLocked()
    }

    func testRemotePrecheckAvoidsAnyShieldPresentationDuringSystemPasswordEntry() {
        beginRemoteDesktop()
        lockWithUnavailableAccessibility()
        monitor.handleSessionEvent(.didWake(locked))
        clock.advance(90)
        monitor.handleSessionEvent(.reconcile(locked))
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertTrue(detector.isActive)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertFalse(overlay.log.contains { $0.hasPrefix("present:") })
    }

    func testTimerPrecheckPreservesRemoteEvidenceBeforeDelayedLockEvent() {
        beginRemoteDesktop()
        status = .unavailable
        snapshot = locked
        clock.advance(2)
        detector.poll(snapshot: snapshot)
        clock.advance(2)
        detector.poll(snapshot: snapshot)

        monitor.noteLocked()
        clock.advance(60)
        snapshot = unlocked
        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertFalse(overlay.log.contains { $0.hasPrefix("present:") })
    }

    func testEventPrecheckIsSilentAndGateProviderPerformsNoAdditionalReads() {
        gate.handle(.didLaunch(locked))
        status = application
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(readCount, 1)
        XCTAssertTrue(gate.isRemoteSessionActive())
        XCTAssertTrue(gate.isRemoteSessionActive())
        gate.handle(.reconcile(unlocked))
        XCTAssertEqual(readCount, 1)
        XCTAssertFalse(overlay.log.contains { $0.hasPrefix("present:") })
    }

    func testTemporaryUnknownIsStableButPersistentUnknownRestoresShield() {
        beginRemoteDesktop()
        status = .unavailable
        clock.advance(2.9)
        detector.refresh()
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)

        clock.advance(0.2)
        detector.refresh()

        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(overlay.log.filter { $0.hasPrefix("present:") }.count, 1)
        clock.advance(1)
        detector.refresh()
        XCTAssertEqual(overlay.log.filter { $0.hasPrefix("present:") }.count, 1)
    }

    func testExplicitLocalOnUnlockCannotReuseLockedRemoteEvidence() {
        beginRemoteDesktop()
        lockWithUnavailableAccessibility()
        clock.advance(90)
        status = .local
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }

    func testSourceLossOnUnlockCannotReuseLockedRemoteEvidence() {
        beginRemoteDesktop()
        lockWithUnavailableAccessibility()
        clock.advance(90)
        sourceIsAvailable = false
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }

    func testExpiredLockedPrecheckCannotSkipUnlockShield() {
        beginRemoteDesktop()
        lockWithUnavailableAccessibility()
        clock.advance(180.1)
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }

    func testRepeatedSystemLockCannotRenewConsumedUnknownEvidence() {
        beginRemoteDesktop()
        lockWithUnavailableAccessibility()
        clock.advance(90)
        snapshot = unlocked
        monitor.handleSessionEvent(.screenUnlocked)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)

        clock.advance(1)
        snapshot = locked
        monitor.noteLocked()
        clock.advance(1)
        snapshot = unlocked
        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }

    func testNewSleepDiscardsPrecheckBeforeWakeAndUnlock() {
        beginRemoteDesktop()
        lockWithUnavailableAccessibility()
        monitor.handleSessionEvent(.willSleep)
        monitor.handleSessionEvent(.didWake(locked))
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }

    func testLeavingConsoleDiscardsPrecheckBeforeReturningToDesktop() {
        beginRemoteDesktop()
        lockWithUnavailableAccessibility()
        snapshot = SessionSnapshot(screenLocked: false, onConsole: false)
        monitor.handleSessionEvent(.reconcile(snapshot))
        snapshot = unlocked

        monitor.handleSessionEvent(.reconcile(snapshot))

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }

    func testRemotePrecheckDoesNotDismissExplicitManualLock() {
        beginRemoteDesktop()
        monitor.handleSessionEvent(.lockNow)

        monitor.handleSessionEvent(.reconcile(unlocked))

        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .lockNow)
        XCTAssertTrue(overlay.isPresented)
    }

    func testManualLockSurvivesSystemLockWakeAndUnlockWithFreshRemoteEvidence() {
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.autoDismissOnPresenceWhileShielded = true
        beginRemoteDesktop()
        monitor.handleSessionEvent(.lockNow)
        snapshot = locked
        monitor.noteLocked()
        monitor.handleSessionEvent(.didWake(locked))
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)
        monitor.handleSessionEvent(.reconcile(unlocked))

        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .lockNow)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertTrue(presence.started.isEmpty)
    }

    func testRecoveryRotationSurvivesSystemLockWakeAndUnlockWithFreshRemoteEvidence() {
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.autoDismissOnPresenceWhileShielded = true
        beginRemoteDesktop()
        monitor.handleSessionEvent(.lockNow)
        monitor.handleSessionEvent(.recoveryVerified)
        XCTAssertEqual(overlay.lastReason, .recoveryRotate)
        snapshot = locked
        monitor.noteLocked()
        monitor.handleSessionEvent(.didWake(locked))
        snapshot = unlocked

        monitor.handleSessionEvent(.screenUnlocked)
        monitor.handleSessionEvent(.reconcile(unlocked))

        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .recoveryRotate)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertTrue(presence.started.isEmpty)
    }
}
