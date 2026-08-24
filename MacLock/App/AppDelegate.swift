import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var gate: SessionGate!
    var overlay: OverlayWindowManager!
    var secrets: GateSecretsStore!
    var passwords: PasswordStore!
    var lockMonitor: ScreenLockMonitor!
    var presence: PresenceMonitor!
    var onboarding: OnboardingFlow!
    var armDisarm: ArmDisarmController!
    var statusItem = StatusItemController()
    var loginItems = LoginItemService()
    var tap = EventTapController()
    var quitIntent: QuitIntent = .none
    var positivelyDisarmedOrUnregistered = false
    private var sigterm: DispatchSourceSignal?
    private var onboardingWindow: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        if CommandLine.arguments.contains("--diagnose-presence") {
            Task { @MainActor in
                print(await PresenceDiagnostics.report(requestIfNeeded: false))
                NSApp.terminate(nil)
            }
            return
        }
        MacLockLog.file("launch role=\(String(describing: ProcessRole.current()))")
        if handleSingleInstance() { return }

        let keychain = LiveKeychainClient()
        secrets = GateSecretsStore(keychain: keychain)
        let clock = SystemClock()
        passwords = PasswordStore(secrets: secrets, clock: clock)
        overlay = OverlayWindowManager()
        presence = PresenceMonitor(
            catalog: AVCaptureDeviceCatalog(),
            matcher: { PresenceMatcherStore.load() },
            isCameraAuthorized: { Permissions.cameraAuthorized() }
        )
        gate = SessionGate(secrets: secrets, overlay: overlay, tap: tap, presence: presence, clock: clock)
        if case .yes(let policy) = secrets.policyQuery() {
            gate.presenceEnabled = policy.presenceEnabled
            gate.autoDismissOnPresenceWhileShielded = policy.autoDismissOnPresenceWhileShielded
        }
        gate.presenceEnabled = true
        gate.autoDismissOnPresenceWhileShielded = true
        gate.waitTOnUnlock = false
        gate.presenceTimeout = 5
        gate.cameraAuthorized = Permissions.cameraAuthorized()
        if Permissions.cameraStatus() == .notDetermined {
            Task { [weak self] in
                _ = await Permissions.requestCamera()
                self?.gate.cameraAuthorized = Permissions.cameraAuthorized()
            }
        }
        presence.onMatched = { [weak self] evidence in
            self?.gate.handle(.presenceMatched(evidence))
        }
        onboarding = OnboardingFlow(passwords: passwords, secrets: secrets, gate: gate)
        armDisarm = ArmDisarmController(passwords: passwords, secrets: secrets, gate: gate)

        statusItem.onLockNow = { [weak self] in self?.lockNow() }
        statusItem.onDetectPhone = { [weak self] in Task { await self?.detectPhone() } }
        statusItem.onSettings = { [weak self] in self?.openSettings() }
        statusItem.onQuit = { [weak self] in self?.requestQuit() }
        statusItem.install(gate: gate)

        let snapshot = sessionSnapshot()
        let passwordQ = secrets.passwordQuery()
        _ = secrets.cleanDisarmQuery()
        if passwordQ.isNo {
            NSApp.setActivationPolicy(.regular)
            positivelyDisarmedOrUnregistered = true
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        gate.handle(.didLaunch(snapshot))
        if gate.state == .disarmed, passwordQ.isNo {
            positivelyDisarmedOrUnregistered = true
            showOnboarding()
        }
        if secrets.cleanDisarmQuery().isYes {
            positivelyDisarmedOrUnregistered = true
        }

        lockMonitor = ScreenLockMonitor(overlay: overlay, gate: gate, snapshotProvider: sessionSnapshot)
        lockMonitor.install()
        overlay.passwordPanel.onSubmit = { [weak self] text in
            Task { await self?.submitSecret(text) }
        }
        overlay.onBackdoor = { [weak self] in self?.toggleFromChord() }
        tap.onBackdoor = { [weak self] in
            DispatchQueue.main.async { self?.toggleFromChord() }
        }
        tap.installPersistentChordWatch()
        installSIGTERMSource()
        statusItem.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitIntent == .none && !positivelyDisarmedOrUnregistered {
            return .terminateCancel
        }
        return .terminateNow
    }

    private var lastChordUptime: TimeInterval = 0

    private func toggleFromChord() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastChordUptime > 0.2 else { return }
        lastChordUptime = now
        overlay.attachToScreen = true
        MacLockLog.file("chord toggle from \(gate.state)")
        gate.handle(.chordToggle)
        statusItem.refresh()
    }

    private func submitSecret(_ text: String) async {
        overlay.passwordPanel.setBusy(true)
        let result = await passwords.verify(text)
        MacLockLog.file("verify result=\(result) len=\(text.count)")
        overlay.passwordPanel.setBusy(false)
        switch result {
        case .accepted:
            gate.handle(.passwordVerified)
            overlay.passwordPanel.field.stringValue = ""
        case .rejected:
            gate.handle(.passwordRejected)
            overlay.passwordPanel.showError(NSLocalizedString("maclock.unlock.wrong", comment: ""))
        case .lockedOut(let remaining):
            gate.handle(.passwordRejected)
            overlay.passwordPanel.showError(
                String(
                    format: NSLocalizedString("maclock.unlock.lockedout", comment: ""),
                    Int(remaining.rounded(.up))
                )
            )
        case .notSet:
            overlay.passwordPanel.showError(NSLocalizedString("maclock.unlock.nosecret", comment: ""))
        case .keychainUnavailable:
            overlay.passwordPanel.showInfo(NSLocalizedString("maclock.keychain.waiting", comment: ""))
        case .malformedRecord:
            overlay.passwordPanel.showError(NSLocalizedString("maclock.unlock.malformed", comment: ""))
        }
        statusItem.refresh()
    }

    private func showOnboarding() {
        restoreShellIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let window = OnboardingWindowController(flow: onboarding)
        window.onFinished = { [weak self] in
            guard let self else { return }
            self.positivelyDisarmedOrUnregistered = false
            NSApp.setActivationPolicy(.accessory)
            self.statusItem.refresh()
            Task { await self.detectPhone(silentIfNone: true) }
        }
        window.showWindow(nil)
        onboardingWindow = window
    }

    private func lockNow() {
        guard gate.armed else {
            showOnboarding()
            return
        }
        overlay.attachToScreen = true
        gate.handle(.lockNow)
        statusItem.refresh()
    }

    private var detectInFlight = false

    private func detectPhone(silentIfNone: Bool = false) async {
        if detectInFlight { return }
        detectInFlight = true
        statusItem.isDetecting = true
        defer {
            detectInFlight = false
            statusItem.isDetecting = false
        }
        let report = await PresenceDiagnostics.report(requestIfNeeded: true)
        MacLockLog.presence.info("\(report, privacy: .public)")
        gate.cameraAuthorized = Permissions.cameraAuthorized()
        if let device = await PresenceDiagnostics.firstBindableDevice() {
            var matcher = PresenceMatcher.v1Default
            matcher.preferredUniqueID = device.uniqueID
            matcher.preferredLocalizedName = device.localizedName
            PresenceMatcherStore.save(matcher)
            try? secrets.setPolicy(GatePolicy(presenceEnabled: true, autoDismissOnPresenceWhileShielded: true))
            gate.presenceEnabled = true
            gate.autoDismissOnPresenceWhileShielded = true
            alert(
                NSLocalizedString("maclock.detect.title", comment: ""),
                NSLocalizedString("maclock.detect.found", comment: ""),
                symbol: "checkmark.circle.fill"
            )
        } else if !silentIfNone {
            alert(
                NSLocalizedString("maclock.detect.title", comment: ""),
                NSLocalizedString("maclock.detect.failed", comment: ""),
                symbol: "xmark.circle.fill"
            )
        }
        statusItem.refresh()
    }

    /// Opens the single settings surface. No alerts anywhere in here — the
    /// login-item outcome is reported inline by the settings view itself.
    func openSettings() {
        restoreShellIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let content = SettingsContentViewController(flow: onboarding, loginItems: loginItems, tap: tap)
            content.onShortcutChanged = { [weak self] in self?.statusItem.refresh() }
            let controller = SettingsWindowController(content: content)
            controller.onClose = { [weak self] in
                guard let self else { return }
                self.settingsWindow = nil
                if self.gate.armed {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            settingsWindow = controller
        }
        // Re-centre on the screen the user is on now, but never yank a window
        // they already have open and may have moved deliberately.
        if settingsWindow?.window?.isVisible != true {
            settingsWindow?.window?.centerOnActiveScreen()
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// Undo any leftover kiosk presentation options before showing a normal
    /// window, so the Dock and menu bar are never stranded hidden.
    private func restoreShellIfNeeded() {
        guard !overlay.isPresented else { return }
        NSApp.presentationOptions = []
    }

    /// The single quit path, shared by ⌘Q, the app menu's Quit item and the
    /// status-menu item. Going through `NSApp.terminate` alone is not enough:
    /// `applicationShouldTerminate` cancels a bare terminate while armed, which
    /// is what made ⌘Q look broken.
    func requestQuit() {
        // Quitting while the shield is up would dismiss the overlay without a
        // password. The event tap already swallows ⌘Q there; this is the backstop.
        guard gate.state != .shielded else {
            NSSound.beep()
            MacLockLog.file("quit refused while shielded")
            return
        }
        quitIntent = .unregisterAndQuit
        positivelyDisarmedOrUnregistered = true
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ message: String, symbol: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            icon.isTemplate = true
            alert.icon = icon
        }
        alert.layout()
        centerAlertLabels(in: alert.window)
        alert.runModal()
        if gate.armed {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func centerAlertLabels(in window: NSWindow) {
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable {
                field.alignment = .center
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView {
            walk(content)
        }
    }

    private func handleSingleInstance() -> Bool {
        let role = ProcessRole.current()
        let others = otherMacLockApps()
        switch (role, others.isEmpty) {
        case (.user, false):
            DistributedNotificationCenter.default().post(name: .init("app.maclock.activate"), object: nil)
            quitIntent = .handoffUserInstance
            positivelyDisarmedOrUnregistered = true
            NSApp.terminate(nil)
            return true
        default:
            return false
        }
    }

    private func installSIGTERMSource() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if self.quitIntent == .none && !self.positivelyDisarmedOrUnregistered {
                _exit(1)
            }
            _exit(0)
        }
        src.resume()
        sigterm = src
    }
}
