import AppKit

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private enum Metrics {
        /// Matches the settings window so the two feel like one app.
        static let contentWidth: CGFloat = 420
        static let sideInset: CGFloat = 24
    }

    private let flow: OnboardingFlow
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: NSLocalizedString("maclock.onboard.headline", comment: ""))
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordCaption = NSTextField(labelWithString: NSLocalizedString("maclock.onboard.field.password", comment: ""))
    private let confirmCaption = NSTextField(labelWithString: NSLocalizedString("maclock.password.confirm", comment: ""))
    private let passwordField = NSSecureTextField(string: "")
    private let confirmField = NSSecureTextField(string: "")
    private let ruleIcon = NSImageView()
    private let ruleLabel = NSTextField(labelWithString: "")
    private let errorIcon = NSImageView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: NSLocalizedString("maclock.onboard.continue", comment: ""), target: nil, action: nil)
    private lazy var errorRow = makeStatusRow(icon: errorIcon, label: errorLabel)
    /// Return in a secure field and the default button can both fire; this keeps
    /// `savePassword()` single-shot.
    private var isSaving = false
    var onFinished: (() -> Void)?

    init(flow: OnboardingFlow) {
        self.flow = flow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("maclock.onboard.title", comment: "")
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
        let content = buildView()
        window.contentView = content
        // Size to the content instead of a guessed height, so no dead band is
        // left under the form.
        window.setContentSize(content.fittingSize)
        window.centerOnActiveScreen()
        window.initialFirstResponder = passwordField
        window.defaultButtonCell = actionButton.cell as? NSButtonCell
    }

    required init?(coder: NSCoder) { nil }

    private func buildView() -> NSView {
        let root = NSView()
        configureHeader()
        configureFields()
        configureFeedback()
        configureButton()
        let stack = buildStack()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Metrics.contentWidth),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.sideInset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.sideInset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
        ])
        return root
    }

    private func buildStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let ruleRow = makeStatusRow(icon: ruleIcon, label: ruleLabel)
        stack.addArrangedSubview(iconView)
        stack.setCustomSpacing(14, after: iconView)
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(6, after: titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(26, after: subtitleLabel)
        stack.addArrangedSubview(passwordCaption)
        stack.addArrangedSubview(passwordField)
        stack.setCustomSpacing(16, after: passwordField)
        stack.addArrangedSubview(confirmCaption)
        stack.addArrangedSubview(confirmField)
        stack.setCustomSpacing(18, after: confirmField)
        stack.addArrangedSubview(ruleRow)
        stack.addArrangedSubview(errorRow)
        // Fixed gap rather than custom spacing: errorRow collapses when hidden,
        // and NSStackView drops the spacing that follows a collapsed view.
        let gap = NSView()
        gap.heightAnchor.constraint(equalToConstant: 14).isActive = true
        stack.addArrangedSubview(gap)
        stack.addArrangedSubview(actionButton)
        return stack
    }

    private func configureHeader() {
        let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = .controlAccentColor
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleNone
        iconView.heightAnchor.constraint(equalToConstant: 40).isActive = true

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center

        subtitleLabel.stringValue = NSLocalizedString("maclock.onboard.clock", comment: "")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.preferredMaxLayoutWidth = Metrics.contentWidth
    }

    private func configureFields() {
        for caption in [passwordCaption, confirmCaption] {
            caption.font = .systemFont(ofSize: 11, weight: .medium)
            caption.textColor = .secondaryLabelColor
        }
        for field in [passwordField, confirmField] {
            field.bezelStyle = .roundedBezel
            field.drawsBackground = true
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = nil
            field.delegate = self
            field.target = self
            field.action = #selector(continueClicked)
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
    }

    private func configureFeedback() {
        ruleLabel.font = .systemFont(ofSize: 11)
        ruleLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorRow.isHidden = true
        refreshRule()
    }

    private func configureButton() {
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(continueClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A leading-aligned `icon + text` row; the trailing spacer keeps the pair
    /// left-aligned inside a width-aligned stack.
    private func makeStatusRow(icon: NSImageView, label: NSTextField) -> NSStackView {
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func refreshRule() {
        let satisfied = passwordField.stringValue.count >= PasswordStore.minimumLength
        let name = satisfied ? "checkmark.circle.fill" : "circle"
        let color: NSColor = satisfied ? .systemGreen : .tertiaryLabelColor
        ruleIcon.image = symbol(name)
        ruleIcon.contentTintColor = color
        ruleLabel.textColor = satisfied ? .secondaryLabelColor : .tertiaryLabelColor
        ruleLabel.stringValue = String(
            format: NSLocalizedString("maclock.onboard.short", comment: ""),
            PasswordStore.minimumLength
        )
    }

    private func showError(_ message: String) {
        errorIcon.image = symbol("exclamationmark.triangle.fill")
        errorIcon.contentTintColor = .systemRed
        errorLabel.stringValue = message
        errorRow.isHidden = false
    }

    private func clearError() {
        errorLabel.stringValue = ""
        errorRow.isHidden = true
    }

    @objc private func continueClicked() {
        guard !isSaving else { return }
        Task { await savePassword() }
    }

    private func savePassword() async {
        isSaving = true
        defer { isSaving = false }
        clearError()
        actionButton.isEnabled = false
        defer { actionButton.isEnabled = true }
        do {
            try await flow.complete(password: passwordField.stringValue, confirm: confirmField.stringValue)
            window?.close()
            onFinished?()
        } catch let storeError as PasswordStoreError {
            showError(storeError.localizedDescription)
        } catch {
            showError(error.localizedDescription)
        }
    }
}

extension OnboardingWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refreshRule()
        clearError()
    }
}
