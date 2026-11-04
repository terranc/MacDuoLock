import AppKit
import Foundation

@MainActor
final class ScreenLockMonitor: NSObject {
    let overlay: any OverlayCommanding
    let gate: SessionGate
    let remote: LiveRemoteSessionDetector?
    var snapshotProvider: () -> SessionSnapshot
    var onEventHandled: (() -> Void)?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var displayWakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var reconcileTimer: Timer?

    init(overlay: any OverlayCommanding, gate: SessionGate, snapshotProvider: @escaping () -> SessionSnapshot,
         remote: LiveRemoteSessionDetector? = nil) {
        self.overlay = overlay
        self.gate = gate
        self.snapshotProvider = snapshotProvider
        self.remote = remote
        super.init()
    }

    func install() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self,
            selector: #selector(didReceiveLock(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        dnc.addObserver(
            self,
            selector: #selector(didReceiveUnlock(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.handleSessionEvent(.didWake(self.snapshotProvider()))
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSessionEvent(.willSleep)
            }
        }
        displayWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A display can wake without the Mac itself sleeping.
                self.handleSessionEvent(.reconcile(self.snapshotProvider()))
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.gate.handle(.screensChanged)
        }
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.handleSessionEvent(.reconcile(self.snapshotProvider()))
            }
        }
    }

    @objc private func didReceiveLock(_ notification: Notification) {
        MacLockLog.file("dnc screenIsLocked")
        noteLocked()
    }

    @objc private func didReceiveUnlock(_ notification: Notification) {
        MacLockLog.file("dnc screenIsUnlocked")
        handleSessionEvent(.screenUnlocked)
    }

    func noteLocked() {
        overlay.dismissSync()
        handleSessionEvent(.screenLocked)
    }

    func handleSessionEvent(_ event: SessionEvent) {
        if shouldPreflightRemote(for: event) {
            remote?.prepare(for: event)
        }
        gate.handle(event)
        updateRemotePolling(for: event)
        onEventHandled?()
    }

    /// A periodic reconcile must not start a probe while the desktop is idle.
    private func shouldPreflightRemote(for event: SessionEvent) -> Bool {
        guard let remote else { return false }
        guard case .reconcile(let snapshot) = event else { return true }
        guard !remote.isPolling else { return true }
        return needsRemotePolling(for: snapshot, remote: remote)
    }

    /// Remote evidence is only useful while the screen is away, a shield is up,
    /// or an unlock-by-remote session is still active. Otherwise stay idle.
    private func needsRemotePolling(for snapshot: SessionSnapshot,
                                    remote: LiveRemoteSessionDetector) -> Bool {
        snapshot.screenLocked || !snapshot.onConsole || overlay.isPresented || remote.isActive
    }

    func updateRemotePolling(for event: SessionEvent) {
        guard let remote else { return }
        let snapshot: SessionSnapshot
        switch event {
        case .didLaunch(let snap), .didWake(let snap), .reconcile(let snap):
            snapshot = snap
        case .screenLocked:
            snapshot = SessionSnapshot(screenLocked: true, onConsole: true)
        case .screenUnlocked:
            snapshot = SessionSnapshot(screenLocked: false, onConsole: true)
        case .willSleep:
            remote.setPolling(false)
            return
        default:
            return
        }
        remote.setPolling(needsRemotePolling(for: snapshot, remote: remote))
    }

    func uninstall() {
        DistributedNotificationCenter.default().removeObserver(self)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let displayWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayWakeObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        reconcileTimer?.invalidate()
    }
}

func sessionSnapshot() -> SessionSnapshot {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return SessionSnapshot(screenLocked: false, onConsole: false)
    }
    let locked = (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    let onConsole = (dict[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue ?? false
    return SessionSnapshot(screenLocked: locked, onConsole: onConsole)
}
