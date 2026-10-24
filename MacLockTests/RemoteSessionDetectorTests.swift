import XCTest
@testable import MacLock

@MainActor
final class RemoteSessionDetectorTests: XCTestCase {
    private let inboundConnection = "tcp4 0 0 192.168.1.20.5900 192.168.1.50.53190 ESTABLISHED"
    private let locked = SessionSnapshot(screenLocked: true, onConsole: true)
    private let unlocked = SessionSnapshot(screenLocked: false, onConsole: true)
    private let application = RemoteSessionStatus.application(bundleIdentifier: "com.netease.uuremote", processIdentifier: 123)
    private var clock: FakeClock!
    private var detector: LiveRemoteSessionDetector!
    private var status = RemoteSessionStatus.unavailable
    private var sourceIsAvailable = true
    private var checkedSources: [RemoteSessionStatus] = []
    private var readCount = 0

    override func setUp() {
        clock = FakeClock()
        status = .unavailable
        sourceIsAvailable = true
        checkedSources = []
        readCount = 0
        detector = LiveRemoteSessionDetector(readStatus: { [unowned self] in
            self.readCount += 1
            return self.status
        }, clock: clock, sourceAvailable: { [unowned self] source in
            self.checkedSources.append(source)
            return self.sourceIsAvailable
        })
    }

    func testCapturedDesktopWithInboundVNCConnectionIsRemote() {
        let connections = [
            inboundConnection,
            "tcp6 0 0 2001:db8::20.5900 2001:db8::50.53190 ESTABLISHED",
            "tcp6 0 0 fe80::20%en0.5900 fe80::50%en0.53190 ESTABLISHED",
            "tcp 0 0 192.168.1.20.5900 192.168.1.50.53190 ESTABLISHED"
        ]
        for connection in connections {
            let netstat = """
            Active Internet connections (including servers)
            Proto Recv-Q Send-Q Local Address Foreign Address (state)
            tcp4 0 0 *.5900 *.* LISTEN
            \(connection)
            """
            XCTAssertEqual(RemoteSessionStatus(screenCaptured: true, connections: netstat), .remote)
        }
    }

    func testCapturedDesktopWithoutInboundEstablishedVNCConnectionStaysLocal() {
        let connections = [
            "",
            "tcp4 0 0 *.5900 *.* LISTEN",
            "tcp4 0 0 192.168.1.20.53190 192.168.1.50.5900 ESTABLISHED",
            "tcp4 0 0 192.168.1.20.5901 192.168.1.50.53190 ESTABLISHED",
            "tcp4 0 0 192.168.1.20.59000 192.168.1.50.53190 ESTABLISHED",
            "udp4 0 0 192.168.1.20.5900 192.168.1.50.53190 ESTABLISHED",
            "tcp4 0 0 192.168.1.20.5900 *.* ESTABLISHED",
            "tcp6 0 0 2001:db8::20.5900 *.* ESTABLISHED",
            "tcp4 0 0 192.168.1.20.5900 192.168.1.50.0 ESTABLISHED",
            "tcp4 0 0 192.168.1.20.5900 192.168.1.50.65536 ESTABLISHED",
            "tcp4 0 0 192.168.1.20.5900 192.168.1.50.* ESTABLISHED",
            "tcp4 0 0 192.168.1.20.5900 not-an-ip.53190 ESTABLISHED",
            "tcp6 0 0 2001:db8::20.5900 2001:invalid::50.53190 ESTABLISHED",
            "tcp4 0 0 192.168.1.20.5900 192.168.1.50.53190 SYN_SENT",
            "tcp4 0 0 192.168.1.20.5900 192.168.1.50.53190 CLOSE_WAIT",
            "tcp4 0 0 192.168.1.20.5900 ESTABLISHED"
        ]
        for connection in connections {
            XCTAssertEqual(RemoteSessionStatus(screenCaptured: true, connections: connection), .local, connection)
        }
    }

    func testInboundVNCConnectionWithoutCapturedDesktopStaysLocal() {
        XCTAssertEqual(RemoteSessionStatus(screenCaptured: false, connections: inboundConnection), .local)
        XCTAssertEqual(RemoteSessionStatus(screenCaptured: false, connections: nil), .local)
    }

    func testMissingScreenOrNetworkSignalIsUnavailable() {
        XCTAssertEqual(RemoteSessionStatus(screenCaptured: nil, connections: inboundConnection), .unavailable)
        XCTAssertEqual(RemoteSessionStatus(screenCaptured: true, connections: nil), .unavailable)
        XCTAssertEqual(RemoteSessionStatus(screenCaptured: nil, connections: nil), .unavailable)
    }

    func testMergedSourcesPreserveWhitelistIdentityAndAcceptEitherPositiveSource() {
        for vnc in [RemoteSessionStatus.local, .remote, .unavailable] {
            XCTAssertEqual(RemoteSessionStatus(whitelist: application, vnc: vnc), application)
        }
        for whitelist in [RemoteSessionStatus.local, .remote, .unavailable] {
            XCTAssertEqual(RemoteSessionStatus(whitelist: whitelist, vnc: .remote), .remote)
        }
    }

    func testMergedSourcesRequireBothExplicitLocalResultsToConfirmLocal() {
        XCTAssertEqual(RemoteSessionStatus(whitelist: .local, vnc: .local), .local)
        for (whitelist, vnc) in [
            (RemoteSessionStatus.local, RemoteSessionStatus.unavailable),
            (.unavailable, .local), (.unavailable, .unavailable)
        ] {
            XCTAssertEqual(RemoteSessionStatus(whitelist: whitelist, vnc: vnc), .unavailable)
        }
    }

    func testRefreshReadsSynchronouslyAndOnlyPublishesActiveChanges() {
        status = .remote
        var changes: [Bool] = []
        detector.onChange = { changes.append($0) }
        XCTAssertFalse(detector.isActive)

        detector.refresh()
        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(changes, [true])
        detector.refresh()
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(changes, [true])

        status = .local
        detector.refresh()
        detector.refresh()
        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(changes, [true, false])
        status = .remote
        detector.refresh()
        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(changes, [true, false, true])
    }

    func testUnavailableRefreshKeepsRecentEvidenceWithoutRenewingItsExpiry() {
        status = .remote
        var changes: [Bool] = []
        detector.onChange = { changes.append($0) }
        detector.refresh()

        status = .unavailable
        clock.advance(2.9)
        detector.refresh()
        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(changes, [true])
        clock.advance(0.2)
        detector.refresh()
        detector.refresh()

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(changes, [true, false])
    }

    func testTimerObservesNativeLockBeforeDelayedLockNotificationExpiresEvidence() {
        status = application
        detector.refresh()
        status = .unavailable
        clock.advance(2)
        detector.poll(snapshot: locked)
        clock.advance(2)
        detector.poll(snapshot: locked)

        XCTAssertTrue(detector.isActive)
        detector.prepare(for: .screenLocked)
        clock.advance(60)
        detector.prepare(for: .screenUnlocked)
        XCTAssertTrue(detector.isActive)
    }

    func testTimerPollPublishesChangesOnceAndReadsStatusOnce() {
        var changes: [Bool] = []
        detector.onChange = { changes.append($0) }
        status = application
        detector.poll(snapshot: unlocked)
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(changes, [true])

        status = .unavailable
        clock.advance(2)
        detector.poll(snapshot: locked)
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(changes, [true])

        status = .local
        detector.poll(snapshot: locked)
        XCTAssertEqual(readCount, 3)
        XCTAssertEqual(changes, [true, false])
    }

    func testTimerCannotReviveEvidenceAlreadyExpiredBeforeNativeLockWasObserved() {
        status = application
        detector.poll(snapshot: unlocked)
        status = .unavailable
        clock.advance(3.1)

        detector.poll(snapshot: locked)
        detector.prepare(for: .screenLocked)
        detector.poll(snapshot: unlocked)

        XCTAssertFalse(detector.isActive)
    }

    func testTimerSourceLossNotifiesOnceAndCannotRestoreDiscardedEvidence() {
        var changes: [Bool] = []
        detector.onChange = { changes.append($0) }
        status = application
        detector.poll(snapshot: unlocked)
        status = .unavailable
        sourceIsAvailable = false

        detector.poll(snapshot: locked)
        detector.poll(snapshot: locked)
        XCTAssertEqual(changes, [true, false])
        sourceIsAvailable = true
        detector.poll(snapshot: unlocked)

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(changes, [true, false])
    }

    func testTimerPollDoesNotRecreateEvidenceWhileSleepingOrOffConsole() {
        status = application
        detector.poll(snapshot: unlocked)
        detector.prepare(for: .willSleep)
        let readsBeforeSleep = readCount
        detector.poll(snapshot: locked)
        XCTAssertEqual(readCount, readsBeforeSleep)
        XCTAssertFalse(detector.isActive)

        detector.prepare(for: .didWake(unlocked))
        XCTAssertTrue(detector.isActive)
        let readsBeforeLeavingConsole = readCount
        detector.poll(snapshot: SessionSnapshot(screenLocked: true, onConsole: false))
        XCTAssertEqual(readCount, readsBeforeLeavingConsole)
        XCTAssertFalse(detector.isActive)
    }

    func testTimerPollCannotRenewExpiredPreflightOrConsumedUnlockGrace() {
        status = application
        detector.poll(snapshot: unlocked)
        status = .unavailable
        detector.poll(snapshot: locked)
        clock.advance(90)
        detector.poll(snapshot: unlocked)
        XCTAssertTrue(detector.isActive)

        clock.advance(1)
        detector.poll(snapshot: locked)
        clock.advance(1)
        detector.poll(snapshot: unlocked)
        XCTAssertFalse(detector.isActive)

        status = application
        detector.poll(snapshot: locked)
        status = .unavailable
        clock.advance(180.1)
        detector.poll(snapshot: locked)
        XCTAssertFalse(detector.isActive)
        detector.poll(snapshot: unlocked)
        XCTAssertFalse(detector.isActive)
    }

    func testApplicationAndVNCStatusesArePositiveEvidence() {
        XCTAssertTrue(application.isRemote)
        XCTAssertTrue(RemoteSessionStatus.remote.isRemote)
        XCTAssertFalse(RemoteSessionStatus.local.isRemote)
        XCTAssertFalse(RemoteSessionStatus.unavailable.isRemote)
        status = application
        detector.refresh()
        XCTAssertTrue(detector.isActive)
    }

    func testPrepareUpdatesSynchronouslyWithoutNotifyingOnChange() {
        var changes: [Bool] = []
        detector.onChange = { changes.append($0) }
        status = application
        detector.prepare(for: .reconcile(unlocked))
        XCTAssertTrue(detector.isActive)
        XCTAssertEqual(readCount, 1)
        XCTAssertTrue(changes.isEmpty)

        status = .local
        detector.prepare(for: .reconcile(unlocked))
        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(readCount, 2)
        XCTAssertTrue(changes.isEmpty)

        status = .remote
        detector.refresh()
        status = .local
        detector.refresh()
        XCTAssertEqual(changes, [true, false])
    }

    func testLockedPrecheckCarriesApplicationEvidenceThenUnlockConsumesIt() {
        status = application
        detector.refresh()
        status = .unavailable
        detector.prepare(for: .screenLocked)
        clock.advance(90)
        detector.prepare(for: .didWake(locked))
        XCTAssertTrue(detector.isActive)

        detector.prepare(for: .screenUnlocked)
        XCTAssertTrue(detector.isActive)
        clock.advance(2.9)
        detector.prepare(for: .reconcile(unlocked))
        XCTAssertTrue(detector.isActive)
        clock.advance(0.2)
        detector.prepare(for: .reconcile(unlocked))
        XCTAssertFalse(detector.isActive)
    }

    func testEachLockedEventCanStartThePrecheckRound() {
        for event in [SessionEvent.screenLocked, .didWake(locked), .reconcile(locked)] {
            detector.reset()
            status = application
            detector.refresh()
            status = .unavailable
            detector.prepare(for: event)
            clock.advance(90)

            detector.prepare(for: .screenUnlocked)

            XCTAssertTrue(detector.isActive, "\(event)")
        }
    }

    func testLockedPrecheckExpiresWithoutRenewalByUnknownLockedEvents() {
        status = .remote
        detector.prepare(for: .screenLocked)
        status = .unavailable
        clock.advance(179.9)
        detector.prepare(for: .reconcile(locked))
        XCTAssertTrue(detector.isActive)

        clock.advance(0.2)
        detector.prepare(for: .didWake(locked))
        XCTAssertFalse(detector.isActive)
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)
    }

    func testConsumedUnlockGraceCannotCreateAnotherPrecheckRound() {
        status = application
        detector.refresh()
        status = .unavailable
        detector.prepare(for: .screenLocked)
        clock.advance(90)
        detector.prepare(for: .screenUnlocked)
        XCTAssertTrue(detector.isActive)

        clock.advance(1)
        detector.prepare(for: .screenLocked)
        clock.advance(1)
        detector.prepare(for: .screenUnlocked)

        XCTAssertFalse(detector.isActive)
        detector.prepare(for: .reconcile(unlocked))
        XCTAssertFalse(detector.isActive)
    }

    func testFreshPositiveEvidenceRenewsLockedPrecheckDeadline() {
        status = application
        detector.prepare(for: .screenLocked)
        clock.advance(170)
        detector.refresh()
        status = .unavailable
        clock.advance(179.9)
        detector.prepare(for: .reconcile(locked))
        XCTAssertTrue(detector.isActive)

        clock.advance(0.2)
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)
    }

    func testExplicitLocalStatusImmediatelyRevokesLockedPrecheck() {
        status = application
        detector.prepare(for: .screenLocked)
        status = .local
        detector.prepare(for: .reconcile(locked))
        XCTAssertFalse(detector.isActive)

        status = .unavailable
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)
    }

    func testUnavailableStatusNeverCreatesRemoteEvidence() {
        detector.prepare(for: .screenLocked)
        clock.advance(90)
        detector.prepare(for: .didWake(locked))
        detector.prepare(for: .screenUnlocked)
        detector.refresh()
        XCTAssertFalse(detector.isActive)
    }

    func testSourceLossRevokesCachedApplicationEvidenceWithoutResurrection() {
        status = application
        detector.prepare(for: .screenLocked)
        status = .unavailable
        sourceIsAvailable = false
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(checkedSources.last, application)

        sourceIsAvailable = true
        detector.refresh()
        XCTAssertFalse(detector.isActive)
    }

    func testSleepAndOffConsoleEventsClearPrecheckEvidence() {
        status = application
        detector.prepare(for: .screenLocked)
        status = .unavailable
        detector.prepare(for: .willSleep)
        XCTAssertFalse(detector.isActive)
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)

        status = application
        detector.prepare(for: .screenLocked)
        status = .unavailable
        detector.prepare(for: .reconcile(SessionSnapshot(screenLocked: true, onConsole: false)))
        XCTAssertFalse(detector.isActive)
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)
    }

    func testSleepIgnoresPositiveTimerReadsUntilWakeWithoutReusingOldEvidence() {
        status = application
        detector.prepare(for: .screenLocked)
        detector.prepare(for: .willSleep)
        let readsBeforeSleepingRefresh = readCount
        status = .remote

        detector.refresh()
        detector.prepare(for: .reconcile(locked))

        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(readCount, readsBeforeSleepingRefresh)
        status = .unavailable
        detector.prepare(for: .didWake(locked))
        XCTAssertFalse(detector.isActive)
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)
    }

    func testResetClearsEvidenceSilently() {
        var changes: [Bool] = []
        detector.onChange = { changes.append($0) }
        status = application
        detector.refresh()
        detector.reset()
        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(changes, [true])

        status = .unavailable
        detector.prepare(for: .screenUnlocked)
        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(changes, [true])
    }

    func testDisablingClearsEvidenceAndReenablingRequiresAFreshRead() {
        status = application
        detector.refresh()
        detector.setEnabled(false)
        XCTAssertFalse(detector.isActive)
        detector.prepare(for: .screenUnlocked)
        detector.refresh()
        XCTAssertFalse(detector.isActive)

        status = .unavailable
        let readsBeforeEnable = readCount
        detector.setEnabled(true)
        XCTAssertEqual(readCount, readsBeforeEnable + 1)
        XCTAssertFalse(detector.isActive)
        status = application
        detector.refresh()
        XCTAssertTrue(detector.isActive)
    }

    func testRemotePolicyDefaultsEnabledAndPersistsExplicitChoice() {
        let key = RemoteShieldPolicy.defaultsKey
        XCTAssertEqual(key, "skipShieldForRemoteSession")
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)
        XCTAssertTrue(RemoteShieldPolicy.isEnabled)

        RemoteShieldPolicy.isEnabled = false
        XCTAssertFalse(RemoteShieldPolicy.isEnabled)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
        RemoteShieldPolicy.isEnabled = true
        XCTAssertTrue(RemoteShieldPolicy.isEnabled)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
    }
}
