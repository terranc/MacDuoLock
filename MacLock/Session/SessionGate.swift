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
        case .screenLocked:
            lastSnapshot.screenLocked = true
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
        guard armed else { ignore(); return }
        if lastSnapshot.screenLocked || !lastSnapshot.onConsole {
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        } else {
            enterUnlockPath(fromSyntheticMonitoring: true)
        }
    }

    private func handleReconcile() {
        if !armed {
            ignore()
            return
        }
        if lastSnapshot.screenLocked || !lastSnapshot.onConsole {
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
            return
        }
        switch state {
        case .monitoring:
            enterUnlockPath(fromSyntheticMonitoring: false)
        case .unlocked, .checkingPresence, .disarmed:
            ignore()
        case .shielded:
            if !overlay.isPresented, let reason = lastOverlayReason {
                apply(state: .shielded, overlay: .present(reason), tap: .start, presence: .stay, bump: false, ui: .none)
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
        case (.monitoring, .presenceMatched), (.monitoring, .presenceTimeout),
             (.monitoring, .passwordVerified), (.monitoring, .passwordRejected):
            ignore()
        case (.monitoring, .disarmVerified):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.checkingPresence, .presenceMatched):
            apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.checkingPresence, .presenceTimeout):
            let p: PresenceCommand = autoDismissOnPresenceWhileShielded && presenceOK ? .start(generation: 0) : .stop
            apply(state: .shielded, overlay: .present(.waitTimeout), tap: .start, presence: p, bump: false, ui: .none)
        case (.checkingPresence, .screenLocked):
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.checkingPresence, .disarmVerified):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.checkingPresence, .passwordVerified), (.checkingPresence, .passwordRejected):
            ignore()
        case (.unlocked, .screenLocked):
            apply(state: .monitoring, overlay: .dismissSync, tap: .stop, presence: .stop, bump: true, ui: .none)
        case (.unlocked, .disarmVerified):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.unlocked, .presenceMatched), (.unlocked, .presenceTimeout):
            ignore()
        case (.unlocked, .screenUnlocked):
            enterUnlockPath(fromSyntheticMonitoring: true)
        case (.shielded, .passwordVerified):
            apply(state: .unlocked, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.shielded, .passwordRejected):
            apply(state: .shielded, overlay: .stay, tap: .stay, presence: .stay, bump: false, ui: .shakePassword)
        case (.shielded, .recoveryVerified):
            apply(state: .shielded, overlay: .present(.recoveryRotate), tap: .stay, presence: .stay, bump: false, ui: .rotatePassword)
        case (.shielded, .passwordRotated):
            secrets.writeCleanDisarm()
            apply(state: .disarmed, overlay: .dismissSync, tap: .stop, presence: .stop, bump: false, ui: .none)
        case (.shielded, .presenceMatched):
            if autoDismissOnPresenceWhileShielded {
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
        case (.shielded, .screensChanged):
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
        if fromSyntheticMonitoring {
            state = .monitoring
        }
        if waitT {
            beginWaitTCheck()
        } else {
            let p: PresenceCommand = autoDismissOnPresenceWhileShielded && presenceOK ? .start(generation: 0) : .stop
            apply(state: .shielded, overlay: .present(.passwordOnly), tap: .start, presence: p, bump: true, ui: .none)
        }
    }

    func beginWaitTCheck() {
        generation &+= 1
        let gen = generation
        state = .checkingPresence
        overlay.dismissSync()
        tap.stopTap()
        presence.start(generation: gen)
        lastEffects = GateEffects(
            overlay: .dismissSync,
            tap: .stop,
            presence: .start(generation: gen),
            bumpGeneration: true,
            ui: .none
        )
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
