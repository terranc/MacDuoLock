import AppKit
import ServiceManagement
import SwiftUI

/// Click-to-record control for the lock chord. SwiftUI has no key-recording
/// primitive, so this stays AppKit and is bridged in below.
final class ShortcutRecorderView: NSView {
    var shortcut: LockShortcut {
        didSet { needsDisplay = true }
    }
    var onCapture: ((LockShortcut) -> Void)?
    private var recording = false {
        didSet { needsDisplay = true }
    }

    init(shortcut: LockShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 116, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    /// Recording has to beat the main menu, which would otherwise swallow every
    /// ⌘-combination before `keyDown` ever runs.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    private func capture(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Bare Escape cancels; Escape with modifiers is a legitimate chord.
        if event.keyCode == 53, modifiers.isEmpty {
            recording = false
            return
        }
        guard let captured = LockShortcut.from(event) else {
            NSSound.beep()
            return
        }
        recording = false
        shortcut = captured
        onCapture?(captured)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = recording
            ? NSLocalizedString("maclock.settings.shortcut.recording", comment: "")
            : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded()
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// AppKit field so settings writes the same `stringValue` the shield later
/// verifies. SwiftUI `SecureField` on macOS can bind a different string than
/// the bullets on screen (IME / uncommitted editor).
struct MacSecureField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField(string: text)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.enter)
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.sendsActionOnEndEditing = false
        field.usesSingleLineMode = true
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacSecureField
        weak var field: NSSecureTextField?
        init(_ parent: MacSecureField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            parent.text = (obj.object as? NSTextField)?.stringValue ?? ""
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.text = (obj.object as? NSTextField)?.stringValue ?? ""
        }

        @objc func enter() {
            field?.validateEditing()
            if let field { parent.text = field.stringValue }
            parent.onSubmit?()
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: LockShortcut
    var onCapture: (LockShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView(shortcut: shortcut)
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.shortcut = shortcut
        nsView.onCapture = onCapture
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    private let flow: OnboardingFlow
    private let loginItems: LoginItemService
    private let tap: EventTapController
    /// Lets the caller re-render the status menu so its key equivalent matches.
    var onShortcutChanged: (() -> Void)?
    var onSkipRemoteShieldChanged: ((Bool) -> Void)?

    @Published var newPassword = ""
    @Published var confirmPassword = ""
    @Published var passwordMessage = ""
    @Published var passwordFailed = false
    @Published var shortcut = LockShortcutStore.current
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var loginMessage = ""
    @Published var loginFailed = false
    @Published var skipRemoteShield = RemoteShieldPolicy.isEnabled
    @Published private(set) var isUpdating = false

    init(flow: OnboardingFlow, loginItems: LoginItemService, tap: EventTapController) {
        self.flow = flow
        self.loginItems = loginItems
        self.tap = tap
    }

    var meetsMinimum: Bool { newPassword.count >= PasswordStore.minimumLength }
    var canUpdate: Bool { meetsMinimum && !confirmPassword.isEmpty && !isUpdating }
    var launchAtLogin: Bool { loginStatus == .enabled }

    var ruleText: String {
        String(
            format: NSLocalizedString("maclock.onboard.short", comment: ""),
            PasswordStore.minimumLength
        )
    }

    func refresh() {
        shortcut = LockShortcutStore.current
        skipRemoteShield = RemoteShieldPolicy.isEnabled
        applyLoginStatus()
    }

    func setSkipRemoteShield(_ enabled: Bool) {
        RemoteShieldPolicy.isEnabled = enabled
        skipRemoteShield = enabled
        onSkipRemoteShieldChanged?(enabled)
    }

    func updatePassword() async {
        isUpdating = true
        defer { isUpdating = false }
        NSApp.keyWindow?.endEditing(for: nil)
        let candidate = newPassword
        let confirm = confirmPassword
        do {
            try await flow.complete(password: candidate, confirm: confirm)
            MacLockLog.file("password set len=\(candidate.count)")
            let check = await flow.passwords.verify(candidate)
            guard check == .accepted else {
                passwordFailed = true
                passwordMessage = NSLocalizedString("maclock.settings.password.verifyfailed", comment: "")
                return
            }
            newPassword = ""
            confirmPassword = ""
            passwordFailed = false
            passwordMessage = NSLocalizedString("maclock.settings.password.updated", comment: "")
        } catch {
            passwordFailed = true
            passwordMessage = error.localizedDescription
        }
    }

    func clearPasswordMessage() {
        guard !passwordMessage.isEmpty else { return }
        passwordMessage = ""
        passwordFailed = false
    }

    /// Called from the fields' `onChange`. Resetting the fields after a
    /// successful save also fires `onChange`, and that must not wipe the
    /// confirmation the user just earned — so only a non-empty field counts as
    /// a real edit.
    func noteEdit() {
        guard !newPassword.isEmpty || !confirmPassword.isEmpty else { return }
        clearPasswordMessage()
    }

    func capture(_ captured: LockShortcut) {
        LockShortcutStore.save(captured)
        shortcut = captured
        tap.reloadShortcut()
        onShortcutChanged?()
    }

    func resetShortcut() {
        LockShortcutStore.resetToDefault()
        shortcut = LockShortcutStore.current
        tap.reloadShortcut()
        onShortcutChanged?()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try loginItems.registerMainApp()
            } else {
                try loginItems.unregisterMainApp()
            }
            loginFailed = false
        } catch {
            loginFailed = true
            loginMessage = error.localizedDescription
        }
        applyLoginStatus()
    }

    func openLoginSettings() {
        try? loginItems.openSettings()
    }

    private func applyLoginStatus() {
        let status = loginItems.status
        loginStatus = status
        // A write error already put its own text in loginMessage; keep it.
        guard !loginFailed else { return }
        switch status {
        case .enabled:
            loginMessage = NSLocalizedString("maclock.settings.loginitem.enabled", comment: "")
        case .requiresApproval:
            loginMessage = NSLocalizedString("maclock.settings.loginitem.approval", comment: "")
        case .notFound:
            loginMessage = NSLocalizedString("maclock.settings.loginitem.notfound", comment: "")
        default:
            loginMessage = ""
        }
    }

    var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        let value = (build == nil || build == short) ? short : "\(short) (\(build!))"
        return NSLocalizedString("maclock.settings.version", comment: "") + " " + value
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    private enum Metrics {
        static let width: CGFloat = 480
        static let fieldWidth: CGFloat = 170
    }

    var body: some View {
        Form {
            passwordSection
            shortcutSection
            generalSection
        }
        .formStyle(.grouped)
        // A grouped Form is a scroll view underneath. The content is short and
        // fixed, so take its ideal height and let the window size to it rather
        // than imposing a height that leaves a scroller behind.
        .scrollDisabled(true)
        .scrollIndicators(.never)
        .frame(width: Metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }

    private var passwordSection: some View {
        Section {
            LabeledContent(NSLocalizedString("maclock.settings.password.new", comment: "")) {
                MacSecureField(text: $model.newPassword)
                    .frame(width: Metrics.fieldWidth, height: 22)
                    .onChange(of: model.newPassword) { model.noteEdit() }
            }
            LabeledContent(NSLocalizedString("maclock.password.confirm", comment: "")) {
                MacSecureField(text: $model.confirmPassword, onSubmit: {
                    Task { await model.updatePassword() }
                })
                .frame(width: Metrics.fieldWidth, height: 22)
                .onChange(of: model.confirmPassword) { model.noteEdit() }
            }
            LabeledContent {
                Button(NSLocalizedString("maclock.settings.password.update", comment: "")) {
                    Task { await model.updatePassword() }
                }
                .disabled(!model.canUpdate)
            } label: {
                Label {
                    Text(model.ruleText)
                } icon: {
                    Image(systemName: model.meetsMinimum ? "checkmark.circle.fill" : "circle")
                }
                .font(.callout)
                .foregroundStyle(model.meetsMinimum ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
        } header: {
            Text(NSLocalizedString("maclock.settings.section.password", comment: ""))
        } footer: {
            if !model.passwordMessage.isEmpty {
                Label {
                    Text(model.passwordMessage)
                } icon: {
                    Image(systemName: model.passwordFailed
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(model.passwordFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.green))
            }
        }
    }

    private var shortcutSection: some View {
        Section {
            LabeledContent(NSLocalizedString("maclock.settings.shortcut.label", comment: "")) {
                HStack(spacing: 10) {
                    ShortcutRecorder(shortcut: model.shortcut) { model.capture($0) }
                        .frame(width: 116, height: 24)
                    Button(NSLocalizedString("maclock.settings.shortcut.reset", comment: "")) {
                        model.resetShortcut()
                    }
                    .controlSize(.small)
                    .disabled(model.shortcut == .default)
                }
            }
        } header: {
            Text(NSLocalizedString("maclock.settings.section.shortcut", comment: ""))
        } footer: {
            Text(NSLocalizedString("maclock.settings.shortcut.hint", comment: ""))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                Text(NSLocalizedString("maclock.settings.loginitem", comment: ""))
            }
            Toggle(isOn: Binding(
                get: { model.skipRemoteShield },
                set: { model.setSkipRemoteShield($0) }
            )) {
                Text(NSLocalizedString("maclock.settings.remote.skip", comment: ""))
            }
        } header: {
            Text(NSLocalizedString("maclock.settings.section.general", comment: ""))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !model.loginMessage.isEmpty {
                    Text(model.loginMessage)
                        .font(.callout)
                        .foregroundStyle(model.loginFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                if model.loginStatus == .requiresApproval {
                    Button(NSLocalizedString("maclock.settings.loginitem.opensettings", comment: "")) {
                        model.openLoginSettings()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                Text(NSLocalizedString("maclock.settings.remote.hint", comment: ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(model.versionText)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// SwiftUI content in an AppKit window: the modern grouped-form look without
/// depending on `showSettingsWindow:` to get the window on screen.
final class SettingsContentViewController: NSHostingController<SettingsRootView> {
    let model: SettingsModel

    var onShortcutChanged: (() -> Void)? {
        get { model.onShortcutChanged }
        set { model.onShortcutChanged = newValue }
    }

    var onSkipRemoteShieldChanged: ((Bool) -> Void)? {
        get { model.onSkipRemoteShieldChanged }
        set { model.onSkipRemoteShieldChanged = newValue }
    }

    init(flow: OnboardingFlow, loginItems: LoginItemService, tap: EventTapController) {
        let model = SettingsModel(flow: flow, loginItems: loginItems, tap: tap)
        self.model = model
        super.init(rootView: SettingsRootView(model: model))
    }

    @MainActor required dynamic init?(coder: NSCoder) { nil }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(content: SettingsContentViewController) {
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("maclock.menu.settings", comment: "")
        super.init(window: window)
        window.delegate = self
        // `NSWindow(contentViewController:)` only adopts the SwiftUI content's
        // size on the next layout pass. Centring before that would place a
        // near-zero frame at the screen centre, and the window would then grow
        // up and to the right from that point — so force the size first.
        content.view.layoutSubtreeIfNeeded()
        window.setContentSize(content.view.fittingSize)
        window.centerOnActiveScreen()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// The `Settings` scene exists only because `App` requires a scene. ⌘, is
/// redirected in `MacLockApp` to `AppDelegate.openSettings()`, which raises the
/// AppKit window above — so there is exactly one settings surface and this
/// content is never presented.
struct SettingsView: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
    }
}
