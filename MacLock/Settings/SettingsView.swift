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

    @Published var newPassword = ""
    @Published var confirmPassword = ""
    @Published var passwordMessage = ""
    @Published var passwordFailed = false
    @Published var shortcut = LockShortcutStore.current
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var loginMessage = ""
    @Published var loginFailed = false
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
        applyLoginStatus()
    }

    func updatePassword() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await flow.complete(password: newPassword, confirm: confirmPassword)
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
                SecureField("", text: $model.newPassword)
                    .labelsHidden()
                    .frame(width: Metrics.fieldWidth)
                    .onChange(of: model.newPassword) { model.clearPasswordMessage() }
            }
            LabeledContent(NSLocalizedString("maclock.password.confirm", comment: "")) {
                SecureField("", text: $model.confirmPassword)
                    .labelsHidden()
                    .frame(width: Metrics.fieldWidth)
                    .onSubmit { Task { await model.updatePassword() } }
                    .onChange(of: model.confirmPassword) { model.clearPasswordMessage() }
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
                Text(model.passwordMessage)
                    .font(.callout)
                    .foregroundStyle(model.passwordFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
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
    private let model: SettingsModel

    var onShortcutChanged: (() -> Void)? {
        get { model.onShortcutChanged }
        set { model.onShortcutChanged = newValue }
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
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Backs the SwiftUI `Settings` scene (⌘,) with the same view the status-bar
/// menu opens, so there is only one settings surface.
struct SettingsView: View {
    @State private var model: SettingsModel?

    var body: some View {
        Group {
            if let model {
                SettingsRootView(model: model)
            } else {
                Color.clear.frame(width: 480, height: 440)
            }
        }
        .onAppear {
            guard model == nil,
                  let delegate = NSApp.delegate as? AppDelegate,
                  let flow = delegate.onboarding else { return }
            let created = SettingsModel(flow: flow, loginItems: delegate.loginItems, tap: delegate.tap)
            created.onShortcutChanged = { delegate.statusItem.refresh() }
            model = created
        }
    }
}
