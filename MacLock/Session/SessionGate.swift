import Foundation

/// Table-driven gate from DESIGN.md §3.4. Longer than 80 lines because the
/// exhaustive (state, event) table is the product contract.
@MainActor
final class SessionGate {
    private(set) var state: GateState = .disarmed
    private(set) var generation: UInt64 = 0
    private(set) var lastEffects = GateEffects()
    private(set) var lastSnapshot = SessionSnapshot(screenLocked: false, onConsole: true)
    private(set) var lastOverlayReason: OverlayReason?

    let secrets: any GateSecretsStoring
    let overlay: any OverlayCommanding
    let tap: any TapCommanding
    let presence: any PresenceControlling
    let clock: any Clocking

    var waitTOnUnlock: Bool = true
    var autoDismissOnPresenceWhileShielded: Bool = false
    var presenceEnabled: Bool = false
    var cameraAuthorized: Bool = false
    var presenceTimeout: TimeInterval = 3
    private var checkingWakePresence = false
    private var wakePresenceMatchedAt: TimeInterval?

    let immediateShieldOnRelaunchWhileUnlocked = true

    init(
        secrets: any GateSecretsStoring,
        overlay: any OverlayCommanding,
        tap: any TapCommanding,
        presence: any PresenceControlling,
        clock: any Clocking
    ) {
        self.secrets = secrets
        self.overlay = overlay
        self.tap = tap
        self.presence = presence
        self.clock = clock
    }

    var presenceOK: Bool { armed && presenceEnabled && cameraAuthorized }
    var waitT: Bool { waitTOnUnlock && presenceOK }

    var keychainUp: Bool {
        !secrets.passwordQuery().isUnavailable && !secrets.cleanDisarmQuery().isUnavailable
    }

    var hasPassword: Bool { secrets.passwordQuery().isYes }
    var cleanDisarm: Bool { secrets.cleanDisarmQuery().isYes }
    var armed: Bool { keychainUp && hasPassword && !cleanDisarm }

    func handle(_ event: SessionEvent) {
        switch event {
        case .didLaunch(let snap):
            lastSnapshot = snap
            handleDidLaunch()
        case .didWake(let snap):
            lastSnapshot = snap
            handleDidWake()
        case .reconcile(let snap):
            lastSnapshot = snap
            handleReconcile()
        case .willSleep:
            clearWakePresence()
            apply(state: state, overlay: .stay, tap: .stay, presence: .stop, bump: true, ui: .none)
        case .screenLocked:
            if state != .monitoring { clearWakePresence() }
            lastSnapshot.screenLocked = true
            if state == .monitoring, checkingWakePresence || wakePresenceMatchedAt != nil {
                ignore()
                break
            }
            handleRest(.screenLocked)
        case .screenUnlocked:
            lastSnapshot.screenLocked = false
            lastSnapshot.onConsole = true
            handleRest(.screenUnlocked)
        default:
            handleRest(event)
        }
        MacLockLog.file("handle \(String(describing: event)) -> \(state)")
    }

    private func handleDidLaunch() {
        let snap = lastSnapshot
        if !keychainUp {
            if snap.screenLocked || !snap.onConsole {
                apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
            } else {
                apply(
                    state: .shielded,
                    overlay: .present(.keychainUnavailable),
                    tap: .start,
                    presence: .stop,
                    bump: true,
                    ui: .keychainWaiting
                )
            }
            return
        }
        if !hasPassword {
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .onboarding)
            return
        }
        if cleanDisarm {
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
            return
        }
        if snap.screenLocked || !snap.onConsole {
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        } else {
            let p: PresenceCommand = autoDismissOnPresenceWhileShielded && presenceOK ? .start(generation: 0) : .stop
            apply(
                state: .shielded,
                overlay: .present(.relaunchWhileUnlocked),
                tap: .start,
                presence: p,
                bump: true,
                ui: .none
            )
        }
    }

    private func handleDidWake() {
        clearWakePresence()
        guard armed else { ignore(); return }
        if lastSnapshot.screenLocked || !lastSnapshot.onConsole {
            checkingWakePresence = lastSnapshot.screenLocked && lastSnapshot.onConsole && presenceOK
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop,
                  presence: checkingWakePresence ? .start(generation: 0) : .stop, bump: true, ui: .none)
            if checkingWakePresence { schedulePresenceTimeout() }
        } else {
            enterUnlockPath(fromSyntheticMonitoring: true)
        }
    }

    private func clearWakePresence() {
        checkingWakePresence = false
        wakePresenceMatchedAt = nil
    }

    private func handleReconcile() {
        if !armed {
            ignore()
            return
        }
        if lastSnapshot.screenLocked || !lastSnapshot.onConsole {
            if lastSnapshot.onConsole, state == .monitoring,
               checkingWakePresence || wakePresenceMatchedAt != nil {
                ignore()
                return
            }
            clearWakePresence()
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
            return
        }
        switch state {
        case .monitoring:
            enterUnlockPath(fromSyntheticMonitoring: false)
        case .unlocked, .disarmed:
            ignore()
        case .shielded, .checkingPresence:
            if !overlay.isPresented, let reason = lastOverlayReason {
                apply(state: state, overlay: .present(reason), tap: .start, presence: .stay, bump: false, ui: .none)
            } else {
                ignore()
            }
        }
    }

    private func handleRest(_ event: SessionEvent) {
        if case .presenceMatched(let ev) = event, ev.generation != generation {
            ignore()
            return
        }
        if case .presenceTimeout(let gen) = event, gen != generation {
            ignore()
            return
        }

        switch event {
        case .disarmVerified, .recoveryVerified, .passwordRotated, .lockNow, .chordToggle:
            if checkingWakePresence {
                apply(state: state, overlay: .stay, tap: .stay, presence: .stop, bump: true, ui: .none)
            }
            clearWakePresence()
        default:
            break
        }

        switch (state, event) {
        case (_, .didLaunch):
            break
        case (.monitoring, .keychainBecameAvailable):
            handleKeychainBecameAvailableFromMonitoring()
        case (.shielded, .keychainBecameAvailable):
            handleKeychainBecameAvailableFromShielded()
        case (.unlocked, .keychainBecameAvailable), (.checkingPresence, .keychainBecameAvailable), (.disarmed, .keychainBecameAvailable):
            ignore()
        case (.disarmed, .armVerified):
            if lastSnapshot.screenLocked || !lastSnapshot.onConsole {
                apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
            } else {
                apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
            }
        case (.disarmed, _):
            ignore()
        case (.monitoring, .screenUnlocked):
            enterUnlockPath(fromSyntheticMonitoring: false)
        case (.monitoring, .presenceMatched):
            guard checkingWakePresence, presenceOK else { ignore(); return }
            checkingWakePresence = false
            wakePresenceMatchedAt = clock.uptime
            MacLockLog.file("wake presence cached for 180 seconds")
            apply(state: .monitoring, overlay: .stay, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.monitoring, .presenceTimeout):
            guard checkingWakePresence else { ignore(); return }
            clearWakePresence()
            apply(state: .monitoring, overlay: .stay, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.monitoring, .passwordVerified), (.monitoring, .passwordRejected):
            ignore()
        case (.monitoring, .disarmVerified):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.checkingPresence, .presenceMatched):
            apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.checkingPresence, .presenceTimeout):
            let p: PresenceCommand = autoDismissOnPresenceWhileShielded && presenceOK ? .stay : .stop
            apply(state: .shielded, overlay: .stay, tap: .stay, presence: p, bump: false, ui: .none)
        case (.checkingPresence, .screenLocked):
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.checkingPresence, .disarmVerified):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.checkingPresence, .passwordRejected):
            apply(state: .checkingPresence, overlay: .stay, tap: .stay, presence: .stay, bump: false, ui: .shakePassword)
        case (.checkingPresence, .recoveryVerified):
            apply(state: .shielded, overlay: .present(.recoveryRotate), tap: .stay, presence: .stop, bump: true, ui: .rotatePassword)
        case (.unlocked, .screenLocked):
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.unlocked, .disarmVerified):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.unlocked, .presenceMatched), (.unlocked, .presenceTimeout):
            ignore()
        case (.unlocked, .screenUnlocked):
            // Already at the desktop. Duplicate Unlocked (remote apps do this)
            // must not re-raise the shield. didWake still re-gates.
            ignore()
        case (.shielded, .chordToggle), (.checkingPresence, .chordToggle):
            apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.unlocked, .chordToggle),
             (.unlocked, .lockNow), (.checkingPresence, .lockNow):
            shieldImmediately(reason: .lockNow, allowPresenceDismiss: false)
        case (.shielded, .lockNow):
            if !overlay.isPresented, let reason = lastOverlayReason {
                apply(state: .shielded, overlay: .present(reason), tap: .start, presence: .stay, bump: false, ui: .none)
            } else {
                ignore()
            }
        case (.shielded, .passwordVerified), (.checkingPresence, .passwordVerified):
            apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.shielded, .passwordRejected):
            apply(state: .shielded, overlay: .stay, tap: .stay, presence: .stay, bump: false, ui: .shakePassword)
        case (.shielded, .recoveryVerified):
            apply(state: .shielded, overlay: .present(.recoveryRotate), tap: .stay, presence: .stay, bump: false, ui: .rotatePassword)
        case (.shielded, .passwordRotated):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.shielded, .presenceMatched):
            if autoDismissOnPresenceWhileShielded, lastOverlayReason != .lockNow {
                apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
            } else {
                ignore()
            }
        case (.shielded, .presenceTimeout):
            ignore()
        case (.shielded, .screenLocked):
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.shielded, .disarmVerified):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.shielded, .screensChanged), (.checkingPresence, .screensChanged):
            overlay.rebuild()
            lastEffects = GateEffects(overlay: .stay, tap: .stay, presence: .stay, bumpGeneration: false, ui: .none)
        case (_, .screensChanged):
            ignore()
        case (_, .armVerified) where armed:
            ignore()
        default:
            ignore()
        }
    }

    private func handleKeychainBecameAvailableFromMonitoring() {
        if lastSnapshot.screenLocked || !lastSnapshot.onConsole {
            if !hasPassword && keychainUp {
                apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .onboarding)
            } else {
                ignore()
            }
            return
        }
        ignore()
    }

    private func handleKeychainBecameAvailableFromShielded() {
        guard lastOverlayReason == .keychainUnavailable else { ignore(); return }
        if !hasPassword && keychainUp {
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .onboarding)
            return
        }
        if lastSnapshot.screenLocked == false && lastSnapshot.onConsole && armed {
            apply(
                state: .shielded,
                overlay: .present(.relaunchWhileUnlocked),
                tap: .start,
                presence: .stop,
                bump: false,
                ui: .none
            )
            return
        }
        ignore()
    }

    private func enterUnlockPath(fromSyntheticMonitoring: Bool) {
        let cachedPresenceOK = wakePresenceMatchedAt.map { clock.uptime - $0 < 180 } ?? false
        clearWakePresence()
        if cachedPresenceOK, presenceOK {
            MacLockLog.file("unlock using cached wake presence")
            apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
            return
        }
        if fromSyntheticMonitoring {
            state = .monitoring
        }
        if waitT {
            beginWaitTCheck()
        } else {
            shieldImmediately(reason: .passwordOnly)
        }
    }

    private func shieldImmediately(reason: OverlayReason, allowPresenceDismiss: Bool = true) {
        let p: PresenceCommand = allowPresenceDismiss && autoDismissOnPresenceWhileShielded && presenceOK ? .start(generation: 0) : .stop
        apply(state: .shielded, overlay: .present(reason), tap: .start, presence: p, bump: true, ui: .none)
    }

    func beginWaitTCheck() {
        apply(
            state: .checkingPresence,
            overlay: .present(.passwordOnly),
            tap: .start,
            presence: .start(generation: 0),
            bump: true,
            ui: .none
        )
        schedulePresenceTimeout()
    }

    private func schedulePresenceTimeout() {
        let gen = generation
        let timeout = min(8, max(1, presenceTimeout))
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(seconds: timeout)
            self.handle(.presenceTimeout(generation: gen))
        }
    }

    private func apply(
        state next: GateState,
        overlay overlayCmd: OverlayCommand,
        tap tapCmd: TapCommand,
        presence presenceCmd: PresenceCommand,
        bump: Bool,
        ui: UICommand
    ) {
        if bump { generation &+= 1 }
        var resolvedPresence = presenceCmd
        if case .start = presenceCmd {
            resolvedPresence = .start(generation: generation)
        }
        state = next
        lastEffects = GateEffects(
            overlay: overlayCmd,
            tap: tapCmd,
            presence: resolvedPresence,
            bumpGeneration: bump,
            ui: ui
        )
        MacLockLog.file("gate \(state) overlay=\(overlayCmd) tap=\(tapCmd) presence=\(resolvedPresence) armed=\(armed) presenceOK=\(presenceOK)")
        overlay.apply(overlayCmd)
        switch overlayCmd {
        case .present(let reason):
            lastOverlayReason = reason
        case .dismissSync:
            lastOverlayReason = nil
        case .stay:
            break
        }
        switch tapCmd {
        case .start: tap.startTap()
        case .stop: tap.stopTap()
        case .stay: break
        }
        switch resolvedPresence {
        case .start(let gen): presence.start(generation: gen)
        case .stop: presence.stop()
        case .stay: break
        }
    }

    private func ignore() {
        lastEffects = GateEffects()
        MacLockLog.file("gate ignore state=\(state) armed=\(armed)")
    }
}
