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

    func testUnlockRefreshesCameraAuthorizationWithoutOpeningSettings() {
        var authorized = false
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence,
                           clock: clock, cameraAuthorizationProvider: { authorized })
        arm()
        gate.presenceEnabled = true
        gate.handle(.didLaunch(lockedConsole()))

        authorized = true
        gate.handle(.screenUnlocked)

        XCTAssertTrue(gate.cameraAuthorized)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertEqual(presence.started.count, 1)
        matchWakePresence()
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testCameraAuthorizationRestoredWhileShieldedRestartsDetection() {
        var authorized = false
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence,
                           clock: clock, cameraAuthorizationProvider: { authorized })
        arm()
        gate.presenceEnabled = true
        gate.autoDismissOnPresenceWhileShielded = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(presence.started.isEmpty)

        authorized = true
        gate.handle(.reconcile(unlockedConsole()))
        gate.handle(.reconcile(unlockedConsole()))

        XCTAssertEqual(presence.started.count, 1)
        XCTAssertEqual(overlay.log.filter { $0.hasPrefix("present:") }.count, 1)
        matchWakePresence()
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testRestoringCameraAuthorizationDoesNotAutoUnlockManualLock() {
        var authorized = false
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence,
                           clock: clock, cameraAuthorizationProvider: { authorized })
        arm()
        gate.presenceEnabled = true
        gate.autoDismissOnPresenceWhileShielded = true
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        gate.handle(.lockNow)

        authorized = true
        gate.handle(.reconcile(unlockedConsole()))

        XCTAssertTrue(presence.started.isEmpty)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .lockNow)
    }

    func testRestoringCameraAuthorizationWhileSystemLockedWaitsForUnlock() {
        var authorized = false
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence,
                           clock: clock, cameraAuthorizationProvider: { authorized })
        arm()
        gate.presenceEnabled = true
        gate.autoDismissOnPresenceWhileShielded = true
        gate.handle(.didLaunch(unlockedConsole()))

        authorized = true
        gate.handle(.reconcile(lockedConsole()))

        XCTAssertTrue(presence.started.isEmpty)
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertEqual(presence.started.count, 1)
    }

    func testWakeRefreshesCameraAuthorizationBeforePresenceCheck() {
        var authorized = false
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence,
                           clock: clock, cameraAuthorizationProvider: { authorized })
        arm()
        gate.presenceEnabled = true
        gate.handle(.didLaunch(lockedConsole()))

        authorized = true
        gate.handle(.didWake(lockedConsole()))
        XCTAssertEqual(presence.started.count, 1)
        XCTAssertFalse(overlay.isPresented)
        matchWakePresence()
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testRevokingCameraAuthorizationRejectsPendingMatch() {
        var authorized = true
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence,
                           clock: clock, cameraAuthorizationProvider: { authorized })
        arm()
        gate.presenceEnabled = true
        gate.autoDismissOnPresenceWhileShielded = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        let generation = gate.generation

        authorized = false
        matchWakePresence(generation: generation)

        XCTAssertFalse(gate.cameraAuthorized)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertNotEqual(gate.generation, generation)
    }

    func testMonitoringUnlockWithWaitTChecksPresence() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.waitTOnUnlock = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(tap.startCount, 1)
        XCTAssertEqual(presence.started.count, 1)
    }

    func testPasswordCanUnlockDuringPresenceCheck() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        let generation = gate.generation

        gate.handle(.passwordVerified)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertEqual(gate.lastEffects.presence, .stop)

        gate.handle(.presenceTimeout(generation: generation))
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testPasswordRejectionDuringPresenceCheckKeepsBothPathsAvailable() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)

        gate.handle(.passwordRejected)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(gate.lastEffects.ui, .shakePassword)
        XCTAssertEqual(gate.lastEffects.presence, .stay)
    }

    func testPresenceCheckTimeoutKeepsContinuousDetectionWithoutRebuilding() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.autoDismissOnPresenceWhileShielded = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)

        gate.handle(.presenceTimeout(generation: gate.generation))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(presence.started.count, 1)
        XCTAssertEqual(overlay.log.filter { $0.hasPrefix("present:") }.count, 1)
    }

    func testReconcileRestoresMissingShieldDuringPresenceCheck() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        let generation = gate.generation
        overlay.isPresented = false

        gate.handle(.reconcile(unlockedConsole()))
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertEqual(gate.generation, generation)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(presence.started.count, 1)
    }

    func testRecoveryDuringPresenceCheckStopsDetectionAndIgnoresOldTimeout() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        let generation = gate.generation

        gate.handle(.recoveryVerified)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .recoveryRotate)
        gate.handle(.presenceTimeout(generation: generation))
        XCTAssertEqual(overlay.lastReason, .recoveryRotate)
        XCTAssertTrue(overlay.isPresented)
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
        XCTAssertEqual(overlay.lastReason, .passwordOnly)
        XCTAssertEqual(overlay.log.filter { $0.hasPrefix("present:") }.count, 1,
                       "timeout must not rebuild the panel and erase typed input")
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

    private func beginWakePresenceCheck() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.didWake(lockedConsole()))
    }

    private func matchWakePresence(generation: UInt64? = nil) {
        gate.handle(.presenceMatched(PresenceEvidence(
            generation: generation ?? gate.generation,
            matchReason: .uniqueID,
            uniqueIDFingerprint: "abcd",
            truncatedLocalizedName: "phone",
            continuityCount: 1,
            elapsedMs: 1
        )))
    }

    func testWakeWhileLockedStartsPresenceWithoutShield() {
        beginWakePresenceCheck()
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertEqual(presence.started.count, 1)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertEqual(tap.startCount, 0)
    }

    func testWakePresenceCacheSkipsShieldBeforeThreeMinutes() {
        beginWakePresenceCheck()
        matchWakePresence()
        clock.advance(179.9)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.log.contains { $0.hasPrefix("present:") })
        XCTAssertEqual(presence.started.count, 1)
        XCTAssertEqual(tap.startCount, 0)
    }

    func testWakePresenceCacheExpiresAtThreeMinutes() {
        beginWakePresenceCheck()
        matchWakePresence()
        clock.advance(180)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(presence.started.count, 2)
    }

    func testReconcileAndDuplicateLockPreserveWakeCheckAndCache() {
        beginWakePresenceCheck()
        let gen = gate.generation
        gate.handle(.reconcile(lockedConsole()))
        gate.handle(.screenLocked)
        XCTAssertEqual(gate.generation, gen)
        matchWakePresence(generation: gen)
        gate.handle(.reconcile(lockedConsole()))
        gate.handle(.screenLocked)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testReconcileUnlockConsumesWakeCache() {
        beginWakePresenceCheck()
        matchWakePresence()
        gate.handle(.reconcile(unlockedConsole()))
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testWakeCacheIsConsumedByFirstUnlock() {
        beginWakePresenceCheck()
        matchWakePresence()
        gate.handle(.screenUnlocked)
        gate.handle(.screenLocked)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertTrue(overlay.isPresented)
    }

    func testSleepInvalidatesWakeCacheAndOldEvidence() {
        beginWakePresenceCheck()
        let gen = gate.generation
        matchWakePresence()
        gate.handle(.willSleep)
        matchWakePresence(generation: gen)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
    }

    func testNewWakeDoesNotReusePreviousWakeCache() {
        beginWakePresenceCheck()
        matchWakePresence()
        gate.handle(.didWake(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
    }

    func testOffConsoleInvalidatesWakeCache() {
        beginWakePresenceCheck()
        matchWakePresence()
        gate.handle(.reconcile(SessionSnapshot(screenLocked: true, onConsole: false)))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
    }

    func testWakeTimeoutStopsScanAndRejectsLateMatch() {
        beginWakePresenceCheck()
        let gen = gate.generation
        gate.handle(.presenceTimeout(generation: gen))
        XCTAssertEqual(gate.lastEffects.presence, .stop)
        matchWakePresence(generation: gen)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
    }

    func testUnlockBeforeWakeMatchFallsBackAndRejectsOldMatch() {
        beginWakePresenceCheck()
        let gen = gate.generation
        gate.handle(.screenUnlocked)
        matchWakePresence(generation: gen)
        XCTAssertEqual(gate.state, .checkingPresence)
        XCTAssertTrue(overlay.isPresented)
        matchWakePresence()
        XCTAssertEqual(gate.state, .unlocked)
    }

    func testWakeCacheRequiresCurrentPermissionAndPresencePolicy() {
        for disableCamera in [true, false] {
            beginWakePresenceCheck()
            matchWakePresence()
            if disableCamera {
                gate.cameraAuthorized = false
            } else {
                gate.presenceEnabled = false
            }
            gate.handle(.screenUnlocked)
            XCTAssertEqual(gate.state, .shielded)
            XCTAssertTrue(overlay.isPresented)
        }
    }

    func testPlainLockDoesNotPrecheckOrCachePresence() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(lockedConsole()))
        XCTAssertTrue(presence.started.isEmpty)
        matchWakePresence()
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
    }

    func testManualLockInvalidatesWakeCache() {
        beginWakePresenceCheck()
        matchWakePresence()
        gate.handle(.lockNow)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
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

    func testUnlockedScreenUnlockedDoesNotRegate() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        XCTAssertEqual(gate.state, .unlocked)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testLegacyRemoteBypassPreferenceCannotSkipPasswordShield() {
        let key = "skipShieldForRemoteSession"
        let previousValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        arm()

        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .relaunchWhileUnlocked)
        XCTAssertTrue(overlay.isPresented)

        gate.handle(.passwordVerified)
        gate.handle(.screenLocked)
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .passwordOnly)
        XCTAssertTrue(overlay.isPresented)

        gate.handle(.passwordVerified)
        gate.handle(.didWake(unlockedConsole()))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .passwordOnly)
        XCTAssertTrue(overlay.isPresented)
    }

    func testDisarmedIgnoresUnlock() {
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertFalse(overlay.isPresented)
    }

    func testChordToggleUnlocksWhenShielded() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        XCTAssertEqual(gate.state, .shielded)
        gate.handle(.chordToggle)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
    }

    func testChordToggleLocksWhenUnlockedAndShowsPasswordOverlay() {
        arm()
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        XCTAssertEqual(gate.state, .unlocked)
        gate.handle(.chordToggle)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertEqual(overlay.lastReason, .lockNow)
    }

    func testChordToggleUnlocksVisibleShieldDuringCheckingPresence() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.waitTOnUnlock = true
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.screenUnlocked)
        XCTAssertEqual(gate.state, .checkingPresence)
        let gen = gate.generation
        gate.handle(.chordToggle)
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertFalse(overlay.isPresented)
        gate.handle(.presenceTimeout(generation: gen))
        XCTAssertEqual(gate.state, .unlocked)
    }

    func testChordToggleIgnoredWhenMonitoring() {
        arm()
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.chordToggle)
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
    }

    func testChordToggleIgnoredWhenDisarmed() {
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.chordToggle)
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertFalse(overlay.isPresented)
    }

    func testLockNowFromUnlockedShieldsImmediately() {
        arm()
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.waitTOnUnlock = true
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        gate.handle(.lockNow)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .lockNow)
        XCTAssertTrue(overlay.isPresented)
    }

    func testLockNowIgnoredWhenMonitoring() {
        arm()
        gate.handle(.didLaunch(lockedConsole()))
        gate.handle(.lockNow)
        XCTAssertEqual(gate.state, .monitoring)
        XCTAssertFalse(overlay.isPresented)
    }

    func testExplicitLockDoesNotAutoDismissOnPresence() {
        arm()
        gate.autoDismissOnPresenceWhileShielded = true
        gate.presenceEnabled = true
        gate.cameraAuthorized = true
        gate.handle(.didLaunch(unlockedConsole()))
        gate.handle(.passwordVerified)
        gate.handle(.chordToggle)
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertEqual(overlay.lastReason, .lockNow)
        gate.handle(.presenceMatched(PresenceEvidence(
            generation: gate.generation,
            matchReason: .uniqueID,
            uniqueIDFingerprint: "x",
            truncatedLocalizedName: "n",
            continuityCount: 1,
            elapsedMs: 0
        )))
        XCTAssertEqual(gate.state, .shielded)
        XCTAssertTrue(overlay.isPresented)
    }
}
