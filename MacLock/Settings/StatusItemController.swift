import AppKit

@MainActor
final class StatusItemController: NSObject {
    private var item: NSStatusItem?
    private weak var gate: SessionGate?
    var onLockNow: (() -> Void)?
    var onDetectPhone: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var isDetecting = false {
        didSet {
            if oldValue != isDetecting { refresh() }
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
        menu.addItem(statusHeader(state))
        menu.addItem(.separator())
        let lock = item(NSLocalizedString("maclock.menu.locknow", comment: ""), "lock.fill", #selector(lockNow))
        // Display only — the chord is delivered by the event tap / Carbon hot key,
        // since a status-item menu's key equivalents fire only while it is open.
        let shortcut = LockShortcutStore.current
        lock.keyEquivalent = shortcut.keyEquivalent
        lock.keyEquivalentModifierMask = shortcut.cocoaModifiers
        menu.addItem(lock)
        let detectTitle = detecting
            ? NSLocalizedString("maclock.menu.detect.busy", comment: "")
            : NSLocalizedString("maclock.menu.detect", comment: "")
        let detectItem = item(detectTitle, "iphone", #selector(detectPhone))
        detectItem.isEnabled = !detecting
        menu.addItem(detectItem)
        menu.addItem(item(NSLocalizedString("maclock.menu.settings", comment: ""), "gearshape", #selector(settings)))
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

    @objc private func lockNow() { onLockNow?() }
    @objc private func detectPhone() {
        guard !isDetecting else { return }
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
