import XCTest
@testable import MacLock

@MainActor
final class SessionGateTests: XCTestCase {
    private var overlay: OverlaySpy!
    private var secrets: FakeSecrets!
    private var clock: FakeClock!
    private var tap: TapSpy!
    private var presence: PresenceSpy!
    private var gate: SessionGate!

    override func setUp() {
        overlay = OverlaySpy()
        secrets = FakeSecrets()
        clock = FakeClock()
        tap = TapSpy()
        presence = PresenceSpy()
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence, clock: clock)
    }

    private func arm() {
        secrets.password = .yes(FakeSecrets.record())
        secrets.disarm = .no
    }

    private func unlockedConsole() -> SessionSnapshot {
        SessionSnapshot(screenLocked: false, onConsole: true)
    }

    private func lockedConsole() -> SessionSnapshot {
        SessionSnapshot(screenLocked: true, onConsole: true)
    }

    func testDidLaunchNoPasswordGoesOnboarding() {
        secrets.password = .no
        secrets.disarm = .no
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertEqual(gate.lastEffects.ui, .onboarding)
        XCTAssertFalse(overlay.isPresented)
    }

    func testDidLaunchCleanDisarmIsDisarmed() {
        arm()
        secrets.disarm = .yes(Data([1]))
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertFalse(overlay.isPresented)
    }

    func testDidLaunchArmedLockedMonitorsWithoutOverlay() {
        arm()
        gate.handle(.didLaunch(lockedConsole()))
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
    }

    func testDidLaunchArmedUnlockedImmediateShieldNoWaitT() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.waitTOnUnlock = true
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .relaunchWhileUnlocked)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertTrue(presence.started.isEmpty || gate.state == .shielded)
    }

    func testDidLaunchKeychainUnavailableLockedForbidsOverlay() {
        secrets.password = .unavailable(errSecInteractionNotAllowed)
        gate.handle(.didLaunch(lockedConsole()))
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertNotEqual(gate.lastEffects.ui, .onboarding)
    }

    func testDidLaunchKeychainUnavailableOffConsoleForbidsOverlay() {
        secrets.password = .unavailable(errSecInteractionNotAllowed)
        gate.handle(.didLaunch(SessionSnapshot(screenLocked: false, onConsole: false)))
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
    }

    func testDidLaunchKeychainUnavailableUnlockedShields() {
        secrets.password = .unavailable(errSecInteractionNotAllowed)
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .keychainUnavailable)
        XCTAssertNotEqual(gate.lastEffects.ui, .onboarding)
    }

    func testKeychainBecameAvailableFromUnavailableUnlocksPasswordField() {
        secrets.password = .unavailable(errSecInteractionNotAllowed)
        gate.handle(.didLaunch(unlockedConsole()))
        arm()
        gate.handle(.keychainBecameAvailable)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .relaunchWhileUnlocked)
    }

    func testKeychainBecameAvailableFromUnlockedIgnored() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        XCTAssertEqual(gate.state, .unlocked)
        let gen = gate.generation
        gate.handle(.keychainBecameAvailable)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertEqual(gate.generation, gen)
    }

    func testMonitoringUnlockWithoutWaitTShieldsPasswordOnly() {
        arm()
        gate.presenceEnabled = false
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .passwordOnly)
    }

    func testMonitoringUnlockWithWaitTChecksPresence() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.waitTOnUnlock = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertEqual(presence.started.count, 1)
    }

    func testCheckingPresenceMatchUnlocks() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        let gen = gate.generation
        gate.handle(.presenceMatched(PresenceEvidence(
            generation: gen,
            matchReason: .uniqueID,
            uniqueIDFingerprint: "abcd",
            truncatedLocalizedName: "phone",
            continuityCount: 1,
            elapsedMs: 1
        )))
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testStaleTimeoutAfterMatchIgnored() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        let gen = gate.generation
        gate.handle(.presenceMatched(PresenceEvidence(
            generation: gen,
            matchReason: .uniqueID,
            uniqueIDFingerprint: "abcd",
            truncatedLocalizedName: "phone",
            continuityCount: 1,
            elapsedMs: 1
        )))
        XCTAssertEqual(gate.state, .unlocked)
        gate.handle(.presenceTimeout(generation: gen))
        XCTAssertEqual(gate.state, .unlocked)
    }

    func testTimeoutSameGenerationShields() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        let gen = gate.generation
        gate.handle(.presenceTimeout(generation: gen))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .waitTimeout)
    }

    func testLockDuringCheckingGoesMonitoring() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        let dismissBefore = overlay.dismissSyncCount
        gate.handle(.screenLocked)
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertGreaterThan(overlay.dismissSyncCount, dismissBefore)
        XCTAssertFalse(overlay.isPresented)
    }

    func testLockDuringShieldedDismisses() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertTrue(overlay.isPresented)
        let monitor = ScreenLockMonitor(overlay: overlay, gate: gate, snapshotProvider: lockedConsole)
        monitor.noteLocked()
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertEqual(overlay.log.first, "present:relaunchWhileUnlocked")
        XCTAssertTrue(overlay.log.contains("dismissSync"))
        let dismissIdx = overlay.log.firstIndex(of: "dismissSync")!
        XCTAssertGreaterThan(overlay.dismissSyncCount, 0)
        XCTAssertEqual(overlay.log[dismissIdx], "dismissSync")
    }

    func testPasswordRejectedStaysShielded() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordRejected)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(gate.lastEffects.ui, .shakePassword)
    }

    func testPasswordVerifiedGoesUnlockedNoPasswordAcceptedState() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testQ1OffPresenceWhileShieldedIgnored() {
        arm()
        gate.autoDismissOnPresenceWhileShielded = false
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.presenceMatched(PresenceEvidence(
            generation: gate.generation,
            matchReason: .uniqueID,
            uniqueIDFingerprint: "x",
            truncatedLocalizedName: "n",
            continuityCount: 1,
            elapsedMs: 0
        )))
        XCTAssertEqual(gate.state, .shielded)
    }

    func testQ1OnPresenceWhileShieldedUnlocks() {
        arm()
        gate.autoDismissOnPresenceWhileShielded = true
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.presenceMatched(PresenceEvidence(
            generation: gate.generation,
            matchReason: .uniqueID,
            uniqueIDFingerprint: "x",
            truncatedLocalizedName: "n",
            continuityCount: 1,
            elapsedMs: 0
        )))
        XCTAssertEqual(gate.state, .unlocked)
    }

    func testDisarmFromShieldedCheckingUnlocked() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.disarmVerified)
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertTrue(secrets.disarm.isYes)

        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        gate.handle(.disarmVerified)
        XCTAssertEqual(gate.state, .disarmed)

        arm()
        secrets.disarm = .no
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        gate.handle(.disarmVerified)
        XCTAssertEqual(gate.state, .disarmed)
    }

    func testArmVerifiedUnlockedDoesNotPresent() {
        secrets.password = .yes(FakeSecrets.record())
        secrets.disarm = .yes(Data([1]))
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .disarmed)
        secrets.disarm = .no
        gate.handle(.armVerified)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testRecoveryVerifiedKeepsShieldThenPasswordRotatedDisarms() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.recoveryVerified)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .recoveryRotate)
        gate.handle(.passwordRotated)
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertTrue(secrets.password.isYes)
        XCTAssertTrue(secrets.disarm.isYes)
        XCTAssertFalse(overlay.isPresented)
    }

    func testDidWakeFromUnlockedRegatesImmediately() {
        arm()
        gate.presenceEnabled = false
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        XCTAssertEqual(gate.state, .unlocked)
        gate.handle(.didWake(unlockedConsole()))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .passwordOnly)
    }

    func testPeriodicReconcileUnlockedDoesNotRegate() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        gate.handle(.reconcile(unlockedConsole()))
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testScreensChangedWhenNotShieldedDoesNotRebuild() {
        arm()
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screensChanged)
        XCTAssertEqual(overlay.rebuildCount, 0)
    }

    func testScreensChangedWhenShieldedRebuilds() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.screensChanged)
        XCTAssertEqual(overlay.rebuildCount, 1)
        XCTAssertEqual(gate.state, .shielded)
    }

    func testReconcileLockedFromUnlockedGoesMonitoring() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        gate.handle(.reconcile(lockedConsole()))
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
    }

    func testReconcileOffConsoleFromShieldedDismisses() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.reconcile(SessionSnapshot(screenLocked: false, onConsole: false)))
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
    }

    func testUserDefaultsArmedNoiseDoesNotArm() {
        UserDefaults.standard.set(true, forKey: "armed")
        UserDefaults.standard.set(true, forKey: "userRequestedQuit")
        secrets.password = .no
        secrets.disarm = .no
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertFalse(overlay.isPresented)
        UserDefaults.standard.removeObject(forKey: "armed")
        UserDefaults.standard.removeObject(forKey: "userRequestedQuit")
    }

    func testUnlockedScreenUnlockedRegatesImmediately() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        XCTAssertEqual(gate.state, .unlocked)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }

    func testDisarmedIgnoresUnlock() {
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertFalse(overlay.isPresented)
    }
}
