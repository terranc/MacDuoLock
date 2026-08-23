import AppKit

/// Opaque black backdrop. The shield must never let the desktop show through,
/// so this draws with `isOpaque = true` rather than a translucent layer.
private final class BlackFillView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
    }
}

private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Design tokens for the minimal high-contrast shield. Kept in one place so the
/// primary panel and the auxiliary shield stay visually consistent.
enum ShieldStyle {
    static let primaryText = NSColor(white: 1, alpha: 1.0)
    static let secondaryText = NSColor(white: 1, alpha: 0.55)
    static let tertiaryText = NSColor(white: 1, alpha: 0.40)
    static let ghostText = NSColor(white: 1, alpha: 0.12)
    static let icon = NSColor(white: 1, alpha: 0.85)
    static let fieldFill = NSColor(white: 1, alpha: 0.10)
    static let fieldBorder = NSColor(white: 1, alpha: 0.18)
    static let fieldBorderFocused = NSColor(white: 1, alpha: 0.45)
    static let buttonFill = NSColor(white: 1, alpha: 0.16)

    static let fieldWidth: CGFloat = 320
    static let fieldHeight: CGFloat = 44

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

/// Capsule that hosts the secure field. Owns the focus ring we draw ourselves,
/// because the system focus ring is close to invisible on a pure black backdrop.
private final class CapsuleView: NSView {
    var isFocused = false {
        didSet { updateBorder() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = ShieldStyle.fieldFill.cgColor
        layer?.borderWidth = 1
        updateBorder()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private func updateBorder() {
        let color = isFocused ? ShieldStyle.fieldBorderFocused : ShieldStyle.fieldBorder
        layer?.borderColor = color.cgColor
    }
}

/// Secure field with the system focus ring suppressed; focus is reported upward
/// so `CapsuleView` can draw the highlight instead.
final class ShieldSecureField: NSSecureTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}
}

/// Round icon button embedded at the trailing edge of the capsule.
private final class RoundIconButton: NSButton {
    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1.0 : 0.35 }
    }
}

@MainActor
final class PasswordPanelController: NSViewController {
    let field: ShieldSecureField = {
        let field = ShieldSecureField(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.textColor = ShieldStyle.primaryText
        field.font = .systemFont(ofSize: 15)
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.placeholderString = nil
        (field.cell as? NSTextFieldCell)?.placeholderString = nil
        (field.cell as? NSTextFieldCell)?.placeholderAttributedString = nil
        field.cell?.sendsActionOnEndEditing = false
        return field
    }()

    private let capsule = CapsuleView(frame: .zero)
    private let lockIcon = NSImageView()
    private let ghost = PassThroughLabel(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let submit: NSButton = RoundIconButton(title: "", target: nil, action: nil)
    let hint = NSTextField(labelWithString: "")
    let forgot = NSButton(title: NSLocalizedString("maclock.forgot", comment: ""), target: nil, action: nil)

    var onSubmit: ((String) -> Void)?
    var onForgot: (() -> Void)?
    private(set) var recoveryMode = false

    override func loadView() {
        let root = BlackFillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.autoresizingMask = [.width, .height]
        configureIcon()
        configureField()
        configureSubmit()
        configureLabels()
        [lockIcon, hint, capsule, forgot].forEach { root.addSubview($0) }
        [field, ghost, submit, spinner].forEach { capsule.addSubview($0) }
        activateConstraints(in: root)
        view = root
    }

    private func configureIcon() {
        lockIcon.image = ShieldStyle.symbol("lock.fill", pointSize: 40, weight: .light)
        lockIcon.contentTintColor = ShieldStyle.icon
        lockIcon.imageScaling = .scaleNone
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureField() {
        capsule.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(submitClicked)
        field.delegate = self
        field.onFocusChange = { [weak self] focused in
            self?.capsule.isFocused = focused
        }
        ghost.stringValue = NSLocalizedString("maclock.password.placeholder", comment: "")
        ghost.font = .systemFont(ofSize: 15)
        ghost.textColor = ShieldStyle.tertiaryText
        ghost.alignment = .left
        ghost.drawsBackground = false
        ghost.isBezeled = false
        ghost.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSubmit() {
        submit.isBordered = false
        submit.bezelStyle = .regularSquare
        submit.imagePosition = .imageOnly
        submit.image = ShieldStyle.symbol("arrow.right", pointSize: 13, weight: .semibold)
        submit.contentTintColor = ShieldStyle.primaryText
        submit.wantsLayer = true
        submit.layer?.cornerRadius = 15
        submit.layer?.backgroundColor = ShieldStyle.buttonFill.cgColor
        submit.toolTip = NSLocalizedString("maclock.submit", comment: "")
        submit.setAccessibilityLabel(NSLocalizedString("maclock.submit", comment: ""))
        submit.translatesAutoresizingMaskIntoConstraints = false
        submit.target = self
        submit.action = #selector(submitClicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLabels() {
        hint.isEditable = false
        hint.isBezeled = false
        hint.drawsBackground = false
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = ShieldStyle.secondaryText
        hint.alignment = .center
        hint.maximumNumberOfLines = 3
        hint.lineBreakMode = .byWordWrapping
        hint.translatesAutoresizingMaskIntoConstraints = false

        forgot.isBordered = false
        forgot.font = .systemFont(ofSize: 11)
        forgot.contentTintColor = ShieldStyle.tertiaryText
        forgot.attributedTitle = NSAttributedString(
            string: NSLocalizedString("maclock.forgot", comment: ""),
            attributes: [
                .foregroundColor: ShieldStyle.tertiaryText,
                .font: NSFont.systemFont(ofSize: 11),
            ]
        )
        forgot.translatesAutoresizingMaskIntoConstraints = false
        forgot.target = self
        forgot.action = #selector(forgotClicked)
        forgot.isHidden = true
    }

    private func activateConstraints(in root: NSView) {
        NSLayoutConstraint.activate([
            capsule.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            capsule.widthAnchor.constraint(equalToConstant: ShieldStyle.fieldWidth),
            capsule.heightAnchor.constraint(equalToConstant: ShieldStyle.fieldHeight),

            field.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: submit.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            ghost.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            ghost.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            ghost.centerYAnchor.constraint(equalTo: field.centerYAnchor),

            submit.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -7),
            submit.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            submit.widthAnchor.constraint(equalToConstant: 30),
            submit.heightAnchor.constraint(equalToConstant: 30),

            spinner.centerXAnchor.constraint(equalTo: submit.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: submit.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            hint.bottomAnchor.constraint(equalTo: capsule.topAnchor, constant: -22),
            hint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hint.widthAnchor.constraint(equalToConstant: 420),

            lockIcon.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -26),
            lockIcon.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            forgot.topAnchor.constraint(equalTo: capsule.bottomAnchor, constant: 24),
            forgot.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])
    }

    func configure(reason: OverlayReason) {
        switch reason {
        case .keychainUnavailable:
            field.isEnabled = false
            submit.isEnabled = false
            forgot.isHidden = true
            showInfo(NSLocalizedString("maclock.keychain.waiting", comment: ""))
        case .recoveryRotate:
            field.isEnabled = true
            submit.isEnabled = true
            forgot.isHidden = true
            showInfo(NSLocalizedString("maclock.recovery.rotate", comment: ""))
        default:
            recoveryMode = false
            field.isEnabled = true
            submit.isEnabled = true
            field.stringValue = ""
            field.placeholderString = nil
            setIcon(named: "lock.fill")
            ghost.stringValue = NSLocalizedString("maclock.password.placeholder", comment: "")
            showInfo(NSLocalizedString("maclock.unlock.prompt", comment: ""))
            refreshGhost()
            forgot.isHidden = true
        }
    }

    func enterRecoveryMode() {
        recoveryMode = true
        field.stringValue = ""
        field.isEnabled = true
        submit.isEnabled = true
        field.placeholderString = nil
        setIcon(named: "key.fill")
        ghost.stringValue = NSLocalizedString("maclock.recovery.placeholder", comment: "")
        showInfo(NSLocalizedString("maclock.recovery.prompt", comment: ""))
        forgot.isHidden = true
        refreshGhost()
    }

    /// Neutral status text: the prompt, a waiting message, a recovery instruction.
    func showInfo(_ text: String) {
        hint.textColor = ShieldStyle.secondaryText
        hint.stringValue = text
    }

    /// Rejection feedback: red text, capsule shake, and a cleared field so the
    /// user retypes rather than editing a wrong value they cannot see.
    func showError(_ text: String) {
        hint.textColor = .systemRed
        hint.stringValue = text
        field.stringValue = ""
        refreshGhost()
        shakeCapsule()
    }

    private func setIcon(named name: String) {
        lockIcon.image = ShieldStyle.symbol(name, pointSize: 40, weight: .light)
    }

    private func shakeCapsule() {
        guard let layer = capsule.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        let origin = layer.position.x
        animation.values = [0, -10, 9, -7, 5, -3, 0].map { origin + $0 }
        animation.duration = 0.42
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "shake")
    }

    private func refreshGhost() {
        ghost.isHidden = !field.stringValue.isEmpty
    }

    func setBusy(_ busy: Bool) {
        field.isEnabled = !busy
        submit.isEnabled = !busy
        submit.isHidden = busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    func revealForgot() {
        forgot.isHidden = false
    }

    @objc private func submitClicked() {
        onSubmit?(field.stringValue)
    }

    @objc private func forgotClicked() {
        enterRecoveryMode()
        onForgot?()
    }
}

extension PasswordPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refreshGhost()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        capsule.isFocused = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            submitClicked()
            return true
        }
        return false
    }
}
