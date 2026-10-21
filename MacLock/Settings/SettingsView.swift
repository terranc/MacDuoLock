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

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, permissions, password, shortcut

    var id: Self { self }

    var title: String {
        NSLocalizedString("maclock.settings.page.\(rawValue).title", comment: "")
    }

    var navigationTitle: String {
        NSLocalizedString("maclock.settings.navigation.\(rawValue)", comment: "")
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .permissions: return "hand.raised"
        case .password: return "key"
        case .shortcut: return "keyboard"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    private let flow: OnboardingFlow
    private let loginItems: LoginItemService
    private let tap: EventTapController
    /// Lets the caller re-render the status menu so its key equivalent matches.
    var onShortcutChanged: (() -> Void)?
    var onDone: (() -> Void)?

    @Published var page: SettingsPage = .general
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
        guard !isUpdating else { return }
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

private func settingsText(_ key: String) -> String {
    NSLocalizedString("maclock.settings." + key, comment: "")
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: SetupModel
    var onLeavePermissions: (() -> Void)?

    var body: some View {
        AppWindowLayout {
            sidebar
        } content: {
            switch model.page {
            case .general: general
            case .permissions: PermissionSetupView(model: permissions)
            case .password: password
            case .shortcut: shortcut
            }
        } footer: {
            HStack {
                Text(model.versionText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.page == .password {
                    doneButton
                } else {
                    doneButton.keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onChange(of: model.page) { _, page in
            if page != .permissions { onLeavePermissions?() }
        }
    }

    private var doneButton: some View {
        Button(settingsText("done")) { model.onDone?() }
            .disabled(model.isUpdating)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            AppSidebarBrand(subtitle: settingsText("caption"))
            VStack(spacing: 6) {
                ForEach(SettingsPage.allCases) { page in
                    Button {
                        NSApp.keyWindow?.endEditing(for: nil)
                        model.page = page
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol).frame(width: 22)
                                .accessibilityHidden(true)
                            Text(page.navigationTitle).lineLimit(1)
                                .minimumScaleFactor(0.9)
                            Spacer(minLength: 0)
                        }
                        .font(.callout.weight(model.page == page ? .semibold : .regular))
                        .frame(minHeight: 20)
                        .foregroundStyle(model.page == page ? Color.accentColor : .primary)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(model.page == page ? Color.accentColor.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isUpdating)
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
                    .accessibilityIdentifier("settings.page.\(page.rawValue)")
                }
            }
            Spacer()
            Text(settingsText("sidebar.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(.general)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(settingsText("loginitem"), isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    Text(settingsText("general.login.detail"))
                        .font(.callout).foregroundStyle(.secondary)
                    if !model.loginMessage.isEmpty {
                        Text(model.loginMessage).font(.caption)
                            .foregroundStyle(model.loginFailed ? Color.red : .secondary)
                    }
                    if model.loginStatus == .requiresApproval {
                        Button(settingsText("loginitem.opensettings")) { model.openLoginSettings() }
                            .buttonStyle(.link).font(.callout)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var password: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(.password)
            GroupBox {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(settingsText("password.new"))
                        MacSecureField(text: $model.newPassword, onSubmit: updatePassword)
                            .frame(height: 24)
                            .accessibilityLabel(settingsText("password.new"))
                            .onChange(of: model.newPassword) { model.noteEdit() }
                        Text(NSLocalizedString("maclock.password.confirm", comment: "")).padding(.top, 8)
                        MacSecureField(text: $model.confirmPassword, onSubmit: updatePassword)
                            .frame(height: 24)
                            .accessibilityLabel(NSLocalizedString("maclock.password.confirm", comment: ""))
                            .onChange(of: model.confirmPassword) { model.noteEdit() }
                    }
                    .disabled(model.isUpdating)
                    Label(model.ruleText, systemImage: model.meetsMinimum ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.secondary)
                    if !model.passwordMessage.isEmpty {
                        Label(model.passwordMessage, systemImage: model.passwordFailed
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(model.passwordFailed ? Color.red : .green)
                            .accessibilityIdentifier("settings.password.message")
                    }
                    HStack {
                        Spacer()
                        if model.isUpdating { ProgressView().controlSize(.small) }
                        Button(settingsText("password.update"), action: updatePassword)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canUpdate)
                    }
                }
                .font(.callout).padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(settingsText("password.note"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(.shortcut)
            GroupBox {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Text(settingsText("shortcut.label"))
                        Spacer()
                        ShortcutRecorder(shortcut: model.shortcut) { model.capture($0) }
                            .frame(width: 116, height: 24)
                            .accessibilityLabel(settingsText("shortcut.label"))
                    }
                    Divider()
                    HStack {
                        Text(settingsText("shortcut.hint"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(settingsText("shortcut.reset")) { model.resetShortcut() }
                            .disabled(model.shortcut == .default)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func heading(_ page: SettingsPage) -> some View {
        AppPageHeading(title: page.title, subtitle: settingsText("page.\(page.rawValue).subtitle"))
    }

    private func updatePassword() {
        guard model.canUpdate else { return }
        Task { await model.updatePassword() }
    }
}

/// A single settings window shares both its layout and permission page with setup.
final class SettingsContentViewController: NSHostingController<SettingsRootView> {
    let model: SettingsModel
    let permissions: SetupModel
    private var dragGuide: PermissionDragGuide?

    var onShortcutChanged: (() -> Void)? {
        get { model.onShortcutChanged }
        set { model.onShortcutChanged = newValue }
    }

    var onPermissionsChanged: (() -> Void)? {
        get { permissions.onPermissionsChanged }
        set { permissions.onPermissionsChanged = newValue }
    }

    init(flow: OnboardingFlow, loginItems: LoginItemService, tap: EventTapController) {
        let model = SettingsModel(flow: flow, loginItems: loginItems, tap: tap)
        let permissions = SetupModel(flow: flow, loginItems: loginItems)
        self.model = model
        self.permissions = permissions
        super.init(rootView: SettingsRootView(model: model, permissions: permissions))
        rootView.onLeavePermissions = { [weak self] in self?.dismissPermissionGuide() }
        permissions.onSettingsOpened = { [weak self] permission in
            guard permission == .accessibility, self?.model.page == .permissions else { return }
            self?.showPermissionGuide()
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { nil }

    func dismissPermissionGuide() { dragGuide?.dismiss() }

    private func showPermissionGuide() {
        if dragGuide == nil {
            dragGuide = PermissionDragGuide(isAuthorized: { [weak self] in
                self?.permissions.refresh()
                return self?.permissions.accessibilityGranted ?? true
            }, onReturnToSetup: { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.view.window?.makeKeyAndOrderFront(nil)
            })
        }
        dragGuide?.present()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let content: SettingsContentViewController
    var onClose: (() -> Void)?

    init(content: SettingsContentViewController) {
        self.content = content
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AppWindowMetrics.width, height: AppWindowMetrics.height),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("maclock.menu.settings", comment: "") + " — MacDuoLock"
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.model.onDone = { [weak self] in self?.close() }
        window.setContentSize(NSSize(width: AppWindowMetrics.width, height: AppWindowMetrics.height))
        window.centerOnActiveScreen()
    }

    required init?(coder: NSCoder) { nil }

    func selectPage(_ page: SettingsPage) {
        guard !content.model.isUpdating else { return }
        window?.endEditing(for: nil)
        if page != .permissions { content.dismissPermissionGuide() }
        content.model.page = page
        content.model.refresh()
        if page == .permissions { content.permissions.refresh() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !content.model.isUpdating }

    func windowWillClose(_ notification: Notification) {
        content.dismissPermissionGuide()
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
