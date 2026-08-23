import AppKit
import ServiceManagement
import SwiftUI

/// Click-to-record control for the lock chord. Draws itself rather than using a
/// bezel so the recording state is unmistakable.
@MainActor
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

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 26) }
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
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text = recording
            ? NSLocalizedString("maclock.settings.shortcut.recording", comment: "")
            : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded()
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

@MainActor
final class SettingsContentViewController: NSViewController {
    private enum Metrics {
        static let contentWidth: CGFloat = 420
        static let inset: CGFloat = 24
    }

    private let flow: OnboardingFlow
    private let loginItems: LoginItemService
    private let tap: EventTapController
    /// Lets the caller re-render the status menu so its key equivalent matches.
    var onShortcutChanged: (() -> Void)?

    private let newField = NSSecureTextField(string: "")
    private let confirmField = NSSecureTextField(string: "")
    private let ruleIcon = NSImageView()
    private let ruleLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton(
        title: NSLocalizedString("maclock.settings.password.update", comment: ""),
        target: nil,
        action: nil
    )
    private let passwordStatus = NSTextField(wrappingLabelWithString: "")
    private lazy var recorder = ShortcutRecorderView(shortcut: LockShortcutStore.current)
    private let loginToggle = NSButton(
        checkboxWithTitle: NSLocalizedString("maclock.settings.loginitem", comment: ""),
        target: nil,
        action: nil
    )
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let openLoginSettings = NSButton(
        title: NSLocalizedString("maclock.settings.loginitem.opensettings", comment: ""),
        target: nil,
        action: nil
    )

    init(flow: OnboardingFlow, loginItems: LoginItemService, tap: EventTapController) {
        self.flow = flow
        self.loginItems = loginItems
        self.tap = tap
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let stack = buildStack()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Metrics.contentWidth),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.inset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.inset),
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        recorder.shortcut = LockShortcutStore.current
        refreshLoginItem()
        refreshRule()
    }

    private func buildStack() -> NSStackView {
        configurePasswordSection()
        configureShortcutSection()
        configureGeneralSection()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addPasswordSection(to: stack)
        addShortcutSection(to: stack)
        addGeneralSection(to: stack)
        return stack
    }

    // MARK: - Password

    private func configurePasswordSection() {
        for field in [newField, confirmField] {
            field.bezelStyle = .roundedBezel
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = nil
            field.delegate = self
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        ruleLabel.font = .systemFont(ofSize: 11)
        ruleIcon.imageScaling = .scaleProportionallyDown
        updateButton.bezelStyle = .rounded
        updateButton.keyEquivalent = "\r"
        updateButton.target = self
        updateButton.action = #selector(updatePassword)
        passwordStatus.font = .systemFont(ofSize: 11)
        passwordStatus.preferredMaxLayoutWidth = Metrics.contentWidth
        passwordStatus.isHidden = true
        refreshRule()
    }

    private func addPasswordSection(to stack: NSStackView) {
        let grid = NSGridView(views: [
            [caption(NSLocalizedString("maclock.settings.password.new", comment: "")), newField],
            [caption(NSLocalizedString("maclock.password.confirm", comment: "")), confirmField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        stack.addArrangedSubview(header(NSLocalizedString("maclock.settings.section.password", comment: "")))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(grid)
        stack.setCustomSpacing(10, after: grid)
        stack.addArrangedSubview(statusRow(icon: ruleIcon, label: ruleLabel))
        stack.addArrangedSubview(trailingRow(updateButton))
        stack.addArrangedSubview(passwordStatus)
        stack.setCustomSpacing(16, after: passwordStatus)
        stack.addArrangedSubview(separator())
    }

    @objc private func updatePassword() {
        Task { await performUpdate() }
    }

    private func performUpdate() async {
        updateButton.isEnabled = false
        defer { updateButton.isEnabled = true }
        do {
            try await flow.complete(password: newField.stringValue, confirm: confirmField.stringValue)
            newField.stringValue = ""
            confirmField.stringValue = ""
            refreshRule()
            show(passwordStatus, NSLocalizedString("maclock.settings.password.updated", comment: ""), isError: false)
        } catch let storeError as PasswordStoreError {
            show(passwordStatus, storeError.localizedDescription, isError: true)
        } catch {
            show(passwordStatus, error.localizedDescription, isError: true)
        }
    }

    private func refreshRule() {
        let satisfied = newField.stringValue.count >= PasswordStore.minimumLength
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let name = satisfied ? "checkmark.circle.fill" : "circle"
        ruleIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        ruleIcon.contentTintColor = satisfied ? .systemGreen : .tertiaryLabelColor
        ruleLabel.textColor = satisfied ? .secondaryLabelColor : .tertiaryLabelColor
        ruleLabel.stringValue = String(
            format: NSLocalizedString("maclock.onboard.short", comment: ""),
            PasswordStore.minimumLength
        )
    }

    // MARK: - Shortcut

    private func configureShortcutSection() {
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.onCapture = { [weak self] shortcut in
            LockShortcutStore.save(shortcut)
            self?.tap.reloadShortcut()
            self?.onShortcutChanged?()
        }
    }

    private func addShortcutSection(to stack: NSStackView) {
        let reset = NSButton(
            title: NSLocalizedString("maclock.settings.shortcut.reset", comment: ""),
            target: self,
            action: #selector(resetShortcut)
        )
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [recorder, reset, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        NSLayoutConstraint.activate([
            recorder.widthAnchor.constraint(equalToConstant: 140),
            recorder.heightAnchor.constraint(equalToConstant: 26),
        ])
        let hint = NSTextField(wrappingLabelWithString: NSLocalizedString("maclock.settings.shortcut.hint", comment: ""))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = Metrics.contentWidth
        stack.addArrangedSubview(header(NSLocalizedString("maclock.settings.section.shortcut", comment: "")))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(8, after: row)
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(16, after: hint)
        stack.addArrangedSubview(separator())
    }

    @objc private func resetShortcut() {
        LockShortcutStore.resetToDefault()
        recorder.shortcut = LockShortcutStore.current
        tap.reloadShortcut()
        onShortcutChanged?()
    }

    // MARK: - General

    private func configureGeneralSection() {
        loginToggle.target = self
        loginToggle.action = #selector(toggleLoginItem(_:))
        loginStatus.font = .systemFont(ofSize: 11)
        loginStatus.textColor = .secondaryLabelColor
        loginStatus.preferredMaxLayoutWidth = Metrics.contentWidth
        openLoginSettings.bezelStyle = .inline
        openLoginSettings.controlSize = .small
        openLoginSettings.target = self
        openLoginSettings.action = #selector(openLoginItemSettings)
        openLoginSettings.isHidden = true
    }

    private func addGeneralSection(to stack: NSStackView) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [loginStatus, openLoginSettings, spacer])
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 8
        let version = NSTextField(labelWithString: versionText())
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(header(NSLocalizedString("maclock.settings.section.general", comment: "")))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(loginToggle)
        stack.setCustomSpacing(6, after: loginToggle)
        stack.addArrangedSubview(statusRow)
        stack.setCustomSpacing(16, after: statusRow)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(version)
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try loginItems.registerMainApp()
            } else {
                try loginItems.unregisterMainApp()
            }
        } catch {
            show(loginStatus, error.localizedDescription, isError: true)
        }
        refreshLoginItem()
    }

    @objc private func openLoginItemSettings() {
        try? loginItems.openSettings()
    }

    private func refreshLoginItem() {
        let status = loginItems.status
        loginToggle.state = status == .enabled ? .on : .off
        openLoginSettings.isHidden = status != .requiresApproval
        switch status {
        case .enabled:
            show(loginStatus, NSLocalizedString("maclock.settings.loginitem.enabled", comment: ""), isError: false)
        case .requiresApproval:
            show(loginStatus, NSLocalizedString("maclock.settings.loginitem.approval", comment: ""), isError: true)
        case .notFound:
            show(loginStatus, NSLocalizedString("maclock.settings.loginitem.notfound", comment: ""), isError: true)
        default:
            show(loginStatus, "", isError: false)
        }
    }

    private func versionText() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        let value = (build == nil || build == short) ? short : "\(short) (\(build!))"
        return NSLocalizedString("maclock.settings.version", comment: "") + " " + value
    }

    // MARK: - Building blocks

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func statusRow(icon: NSImageView, label: NSTextField) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func trailingRow(_ control: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func show(_ label: NSTextField, _ text: String, isError: Bool) {
        label.stringValue = text
        label.textColor = isError ? .systemRed : .secondaryLabelColor
        label.isHidden = text.isEmpty
    }
}

extension SettingsContentViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refreshRule()
        show(passwordStatus, "", isError: false)
    }
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

/// Backs the SwiftUI `Settings` scene (⌘,) with the very same controller the
/// status-bar menu opens, so there is only one settings surface.
struct SettingsView: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> NSViewController {
        guard let delegate = NSApp.delegate as? AppDelegate, let flow = delegate.onboarding else {
            let placeholder = NSViewController()
            placeholder.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
            return placeholder
        }
        return SettingsContentViewController(flow: flow, loginItems: delegate.loginItems, tap: delegate.tap)
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}
