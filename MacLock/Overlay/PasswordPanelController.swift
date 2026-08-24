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

/// Capsule around the secure field. Drawn in `draw(_:)`, never `wantsLayer` —
/// a layer-backed ancestor makes `NSSecureTextField`'s field editor desync.
private final class CapsuleView: NSView {
    var isFocused = false {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.height / 2, yRadius: inset.height / 2)
        ShieldStyle.fieldFill.setFill()
        path.fill()
        (isFocused ? ShieldStyle.fieldBorderFocused : ShieldStyle.fieldBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Secure field. Do not replace its cell class — that breaks first responder.
final class ShieldSecureField: NSSecureTextField {
    var onFocusChange: ((Bool) -> Void)?
    var onEdit: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            polishEditor()
            onFocusChange?(true)
            onEdit?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}

    /// Strip editor chrome. Do not change isRichText / cell class / fieldEditor.
    func polishEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = ShieldStyle.primaryText
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        let font = self.font ?? .systemFont(ofSize: 15)
        editor.markedTextAttributes = [
            .font: font,
            .foregroundColor: ShieldStyle.primaryText,
        ]
        editor.typingAttributes = [
            .font: font,
            .foregroundColor: ShieldStyle.primaryText,
            .underlineStyle: 0,
        ]
        let length = editor.textStorage?.length ?? editor.string.utf16.count
        let range = NSRange(location: 0, length: length)
        editor.textStorage?.removeAttribute(.underlineStyle, range: range)
        editor.textStorage?.removeAttribute(.underlineColor, range: range)
        editor.textStorage?.removeAttribute(.backgroundColor, range: range)
        editor.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        editor.layoutManager?.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        editor.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }
}

/// Round icon button drawn without CALayer so it cannot layer-back the field.
private final class RoundIconButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { false }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1.0 : 0.35; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let oval = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        ShieldStyle.buttonFill.setFill()
        oval.fill()
        if let image {
            let size = NSSize(width: 13, height: 13)
            let rect = NSRect(
                x: ((bounds.width - size.width) / 2).rounded(),
                y: ((bounds.height - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
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
    private var isBusy = false
    private var placeholderKey = "maclock.password.placeholder"

    override func loadView() {
        let root = BlackFillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.autoresizingMask = [.width, .height]
        configureIcon()
        configureField()
        configureSubmit()
        configureLabels()
        [lockIcon, hint, capsule, forgot].forEach { root.addSubview($0) }
        [ghost, field, submit].forEach { capsule.addSubview($0) }
        activateConstraints(in: root)
        view = root
    }

    private func configureIcon() {
        lockIcon.image = ShieldStyle.symbol("lock.fill", pointSize: 40, weight: .light)
        lockIcon.contentTintColor = ShieldStyle.icon
        lockIcon.imageScaling = .scaleNone
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.wantsLayer = false
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
        field.onEdit = { [weak self] in self?.refreshGhost() }
        ghost.font = .systemFont(ofSize: 15)
        ghost.textColor = ShieldStyle.tertiaryText
        ghost.alignment = .left
        ghost.drawsBackground = false
        ghost.isBezeled = false
        ghost.isEditable = false
        ghost.isSelectable = false
        ghost.refusesFirstResponder = true
        ghost.translatesAutoresizingMaskIntoConstraints = false
        setPlaceholder("maclock.password.placeholder")
    }

    private func configureSubmit() {
        submit.isBordered = false
        submit.bezelStyle = .shadowlessSquare
        submit.imagePosition = .imageOnly
        submit.image = ShieldStyle.symbol("arrow.right", pointSize: 13, weight: .semibold)
        submit.contentTintColor = ShieldStyle.primaryText
        submit.wantsLayer = false
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
        spinner.wantsLayer = false
        spinner.isHidden = true
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
        hint.refusesFirstResponder = true
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
            setIcon(named: "lock.fill")
            setPlaceholder("maclock.password.placeholder")
            showInfo(NSLocalizedString("maclock.unlock.prompt", comment: ""))
            forgot.isHidden = true
            resetInput()
        }
        refreshGhost()
    }

    /// Drop whatever was typed last time. Relock must always open on an empty field.
    func resetInput() {
        field.abortEditing()
        field.stringValue = ""
        (field.cell as? NSTextFieldCell)?.stringValue = ""
        refreshGhost()
    }

    func enterRecoveryMode() {
        recoveryMode = true
        field.stringValue = ""
        field.isEnabled = true
        submit.isEnabled = true
        setIcon(named: "key.fill")
        setPlaceholder("maclock.recovery.placeholder")
        showInfo(NSLocalizedString("maclock.recovery.prompt", comment: ""))
        forgot.isHidden = true
        restoreFieldFocus()
        refreshGhost()
    }

    /// Neutral status text: the prompt, a waiting message, a recovery instruction.
    func showInfo(_ text: String) {
        hint.textColor = ShieldStyle.secondaryText
        hint.stringValue = text
    }

    /// Rejection feedback: keep the typed value and first responder so the user
    /// can edit and retry. Do not recreate the field editor.
    func showError(_ text: String) {
        hint.textColor = .systemRed
        hint.stringValue = text
        restoreFieldFocus()
        field.polishEditor()
        refreshGhost()
    }

    private func setPlaceholder(_ key: String) {
        placeholderKey = key
        field.placeholderString = nil
        (field.cell as? NSTextFieldCell)?.placeholderString = nil
        (field.cell as? NSTextFieldCell)?.placeholderAttributedString = nil
        ghost.stringValue = NSLocalizedString(key, comment: "")
        refreshGhost()
    }

    private func setIcon(named name: String) {
        lockIcon.image = ShieldStyle.symbol(name, pointSize: 40, weight: .light)
    }

    var isPlaceholderVisible: Bool { !ghost.isHidden }

    func refreshGhost() {
        let editor = field.currentEditor()?.string ?? ""
        ghost.isHidden = !editor.isEmpty || !field.stringValue.isEmpty
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        submit.isEnabled = !busy
        submit.isHidden = busy
        if busy {
            attachSpinner()
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
            restoreFieldFocus()
            field.polishEditor()
            refreshGhost()
        }
    }

    private func attachSpinner() {
        guard spinner.superview == nil else { return }
        capsule.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: submit.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: submit.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func restoreFieldFocus() {
        guard field.isEnabled else { return }
        guard let window = view.window ?? field.window else { return }
        if window.firstResponder === field.currentEditor() {
            field.polishEditor()
            return
        }
        window.makeFirstResponder(field)
        field.polishEditor()
    }

    func revealForgot() {
        forgot.isHidden = false
    }

    @objc private func submitClicked() {
        guard !isBusy else { return }
        if let editor = field.currentEditor() {
            (editor as? NSTextView)?.unmarkText()
            field.stringValue = editor.string
        } else {
            field.validateEditing()
        }
        onSubmit?(field.stringValue)
    }

    @objc private func forgotClicked() {
        enterRecoveryMode()
        onForgot?()
    }
}

extension PasswordPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        field.polishEditor()
        refreshGhost()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        capsule.isFocused = false
        refreshGhost()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            submitClicked()
            return true
        }
        return false
    }
}
