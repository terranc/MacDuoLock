import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    private var item: NSStatusItem?
    private weak var gate: SessionGate?
    private weak var detectItem: NSMenuItem?
    var onLockNow: (() -> Void)?
    var onDetectPhone: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var isDetecting = false {
        didSet {
            if oldValue != isDetecting { applyDetectingAppearance() }
        }
    }

    func install(gate: SessionGate) {
        self.gate = gate
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        self.item = item
        refresh()
    }

    func refresh() {
        let state = gate?.state ?? .disarmed
        applyButtonImage(for: state)
        item?.menu = makeMenu(for: state, detecting: isDetecting)
    }

    /// Split out from `refresh()` so the key equivalents can be asserted without
    /// standing up a real status item.
    func makeMenu(for state: GateState, detecting: Bool = false) -> NSMenu {
        let menu = NSMenu()
        // Autoenable would re-enable the busy detect row (validateMenuItem is easy
        // to miss from Swift) and replacing `item.menu` while tracking dismisses it.
        menu.autoenablesItems = false
        menu.addItem(statusHeader(state))
        menu.addItem(.separator())
        let lock = item(NSLocalizedString("maclock.menu.locknow", comment: ""), "lock.fill", #selector(lockNow))
        // Display only — the chord is delivered by the event tap / Carbon hot key,
        // since a status-item menu's key equivalents fire only while it is open.
        let shortcut = LockShortcutStore.current
        lock.keyEquivalent = shortcut.keyEquivalent
        lock.keyEquivalentModifierMask = shortcut.cocoaModifiers
        menu.addItem(lock)
        menu.addItem(makeDetectItem(detecting: detecting))
        let settingsItem = item(NSLocalizedString("maclock.menu.settings", comment: ""), "gearshape", #selector(settings))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = item(NSLocalizedString("maclock.menu.quit", comment: ""), "xmark.circle", #selector(quit))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
        return menu
    }

    private func applyButtonImage(for state: GateState) {
        let name: String
        switch state {
        case .shielded: name = "lock.shield.fill"
        case .disarmed: name = "shield.slash"
        default: name = "lock.shield"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MacLock")
        image?.isTemplate = true
        item?.button?.image = image
        item?.button?.toolTip = "MacLock — " + statusTitle(state)
    }

    /// Disabled header row rendered as small secondary text, the way system
    /// menu-bar extras label their current state.
    private func statusHeader(_ state: GateState) -> NSMenuItem {
        let status = NSMenuItem(title: statusTitle(state), action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.attributedTitle = NSAttributedString(
            string: statusTitle(state),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return status
    }

    private func statusTitle(_ state: GateState) -> String {
        switch state {
        case .disarmed: return NSLocalizedString("maclock.menu.status.disarmed", comment: "")
        case .monitoring: return NSLocalizedString("maclock.menu.status.monitoring", comment: "")
        case .checkingPresence: return NSLocalizedString("maclock.menu.status.checking", comment: "")
        case .unlocked: return NSLocalizedString("maclock.menu.status.unlocked", comment: "")
        case .shielded: return NSLocalizedString("maclock.menu.status.shielded", comment: "")
        }
    }

    private func item(_ title: String, _ symbol: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        it.image = image
        return it
    }

    private func makeDetectItem(detecting: Bool) -> NSMenuItem {
        let title = Self.detectTitle(detecting: detecting)
        let it = NSMenuItem(title: title, action: #selector(detectPhone), keyEquivalent: "")
        it.target = self
        it.isEnabled = !detecting
        // Clicks on an NSMenuItem.view do not dismiss the menu; a regular item would.
        let row = DetectMenuRow(title: title, symbol: "iphone", width: Self.detectRowWidth)
        row.setBusy(detecting)
        row.onActivate = { [weak self] in self?.detectPhone() }
        it.view = row
        detectItem = it
        return it
    }

    private func applyDetectingAppearance() {
        guard let detectItem else { return }
        detectItem.title = Self.detectTitle(detecting: isDetecting)
        detectItem.isEnabled = !isDetecting
        (detectItem.view as? DetectMenuRow)?.setBusy(isDetecting)
        detectItem.menu?.itemChanged(detectItem)
    }

    private static func detectTitle(detecting: Bool) -> String {
        detecting
            ? NSLocalizedString("maclock.menu.detect.busy", comment: "")
            : NSLocalizedString("maclock.menu.detect", comment: "")
    }

    private static var detectRowWidth: CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let titles = [detectTitle(detecting: false), detectTitle(detecting: true)]
        let text = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 80
        return DetectMenuRow.titleX + text + 20
    }

    @objc private func lockNow() { onLockNow?() }
    @objc private func detectPhone() {
        guard !isDetecting else { return }
        isDetecting = true
        onDetectPhone?()
    }
    @objc private func settings() { onSettings?() }
    @objc private func quit() { onQuit?() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(detectPhone) {
            return !isDetecting
        }
        return menuItem.action != nil
    }
}

/// Menu row that stays in the open status menu. AppKit does not auto-dismiss
/// (or auto-gray) items with a custom view, so this draws the disabled chrome.
private final class DetectMenuRow: NSView {
    var onActivate: (() -> Void)?
    private(set) var isBusy = false
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    // Matches NSContextMenuItemView: 24pt row, icon at (16, 5.5, 14×13), title at x=34.
    static let rowHeight: CGFloat = 24
    static let titleX: CGFloat = 34
    private static let iconFrame = NSRect(x: 16, y: 5.5, width: 14, height: 13)
    private static let titleY: CGFloat = 4
    private static let titleHeight: CGFloat = 16
    private static let titleTrailing: CGFloat = 12

    init(title: String, symbol: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        autoresizingMask = [.width]
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        titleField.stringValue = title
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.refusesFirstResponder = true
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        addSubview(iconView)
        addSubview(titleField)
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var allowsVibrancy: Bool { true }

    override func layout() {
        super.layout()
        iconView.frame = Self.iconFrame
        titleField.frame = NSRect(
            x: Self.titleX,
            y: Self.titleY,
            width: max(0, bounds.width - Self.titleX - Self.titleTrailing),
            height: Self.titleHeight
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard !isBusy, bounds.contains(loc) else { return }
        onActivate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        applyChrome()
        if enclosingMenuItem?.isHighlighted == true, !isBusy {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        titleField.stringValue = DetectMenuRow.idleOrBusyTitle(busy)
        applyChrome()
        needsDisplay = true
    }

    private func applyChrome() {
        let highlighted = enclosingMenuItem?.isHighlighted == true && !isBusy
        let color: NSColor
        if isBusy {
            color = .disabledControlTextColor
        } else if highlighted {
            color = .selectedMenuItemTextColor
        } else {
            color = .controlTextColor
        }
        titleField.textColor = color
        iconView.contentTintColor = color
    }

    private static func idleOrBusyTitle(_ busy: Bool) -> String {
        busy
            ? NSLocalizedString("maclock.menu.detect.busy", comment: "")
            : NSLocalizedString("maclock.menu.detect", comment: "")
    }
}
