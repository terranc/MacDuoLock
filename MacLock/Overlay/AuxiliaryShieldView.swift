import AppKit

/// Secondary displays get the same opaque black, plus a faint mark so a
/// multi-monitor setup does not read as a dead/asleep screen.
final class AuxiliaryShieldView: NSView {
    var onMouseDown: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        buildMark()
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    private func buildMark() {
        let icon = NSImageView()
        icon.image = ShieldStyle.symbol("lock.fill", pointSize: 28, weight: .light)
        icon.contentTintColor = ShieldStyle.ghostText
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false

        let wordmark = NSTextField(labelWithString: "MacLock")
        wordmark.font = .systemFont(ofSize: 11, weight: .medium)
        wordmark.textColor = ShieldStyle.ghostText
        wordmark.alignment = .center
        wordmark.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(wordmark)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            wordmark.centerXAnchor.constraint(equalTo: centerXAnchor),
            wordmark.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}
