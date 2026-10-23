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
        remote?.prepare(for: event)
        gate.handle(event)
        onEventHandled?()
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
