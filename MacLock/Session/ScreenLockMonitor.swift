import AppKit
import Foundation

@MainActor
final class ScreenLockMonitor: NSObject {
    let overlay: any OverlayCommanding
    let gate: SessionGate
    var snapshotProvider: () -> SessionSnapshot
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var reconcileTimer: Timer?

    init(overlay: any OverlayCommanding, gate: SessionGate, snapshotProvider: @escaping () -> SessionSnapshot) {
        self.overlay = overlay
        self.gate = gate
        self.snapshotProvider = snapshotProvider
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
            guard let self else { return }
            self.gate.handle(.didWake(self.snapshotProvider()))
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
                self.gate.handle(.reconcile(self.snapshotProvider()))
            }
        }
    }

    @objc private func didReceiveLock(_ notification: Notification) {
        MacLockLog.file("dnc screenIsLocked")
        noteLocked()
    }

    @objc private func didReceiveUnlock(_ notification: Notification) {
        MacLockLog.file("dnc screenIsUnlocked")
        gate.handle(.screenUnlocked)
    }

    func noteLocked() {
        overlay.dismissSync()
        gate.handle(.screenLocked)
    }

    func uninstall() {
        DistributedNotificationCenter.default().removeObserver(self)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
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
