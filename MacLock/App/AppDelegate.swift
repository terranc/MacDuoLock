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
        MacLockLog.session.info("launch role=\(String(describing: ProcessRole.current()), privacy: .public)")
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
        statusItem.onOnboard = { [weak self] in self?.showOnboarding() }
        statusItem.onQuit = { [weak self] in self?.quitFromMenu() }
        statusItem.onLoginItem = { [weak self] in self?.enableLoginItem() }
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
        overlay.onBackdoor = { [weak self] in self?.unlockFromBackdoor() }
        tap.onBackdoor = { [weak self] in
            DispatchQueue.main.async { self?.unlockFromBackdoor() }
        }
        installSIGTERMSource()
        statusItem.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitIntent == .none && !positivelyDisarmedOrUnregistered {
            return .terminateCancel
        }
        return .terminateNow
    }

    private func unlockFromBackdoor() {
        guard gate.state == .shielded else { return }
        gate.handle(.passwordVerified)
        statusItem.refresh()
    }

    private func submitSecret(_ text: String) async {
        overlay.passwordPanel.setBusy(true)
        let result = await passwords.verify(text)
        overlay.passwordPanel.setBusy(false)
        switch result {
        case .accepted:
            gate.handle(.passwordVerified)
            overlay.passwordPanel.field.stringValue = ""
        case .rejected, .lockedOut:
            gate.handle(.passwordRejected)
            overlay.passwordPanel.showError(NSLocalizedString("maclock.unlock.wrong", comment: ""))
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
        gate.handle(.didLaunch(SessionSnapshot(screenLocked: false, onConsole: true)))
        statusItem.refresh()
    }

    private func detectPhone(silentIfNone: Bool = false) async {
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
                String(format: NSLocalizedString("maclock.detect.found", comment: ""), device.localizedName)
            )
        } else if !silentIfNone {
            alert(NSLocalizedString("maclock.detect.title", comment: ""), report)
        }
        statusItem.refresh()
    }

    private func enableLoginItem() {
        do {
            try loginItems.registerMainApp()
            alert(NSLocalizedString("maclock.loginitem.title", comment: ""), NSLocalizedString("maclock.loginitem.ok", comment: ""))
        } catch {
            try? loginItems.openSettings()
            alert(NSLocalizedString("maclock.loginitem.title", comment: ""), error.localizedDescription)
        }
    }

    private func quitFromMenu() {
        quitIntent = .unregisterAndQuit
        positivelyDisarmedOrUnregistered = true
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
        if gate.armed {
            NSApp.setActivationPolicy(.accessory)
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
