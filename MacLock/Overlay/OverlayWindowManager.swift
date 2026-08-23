import AppKit

@MainActor
final class OverlayWindowManager: OverlayCommanding {
    var screens: any ScreenListing
    /// Tests set false so XCTest does not raise a real screen-saver overlay on the developer machine.
    var attachToScreen = true

    private(set) var windows: [ShieldWindow] = []
    private(set) var isPresented = false
    private(set) var lastReason: OverlayReason?
    private(set) var dismissSyncCount = 0
    private(set) var rebuildCount = 0
    private(set) var savedPresentationOptions: NSApplication.PresentationOptions = []

    var onBackdoor: (() -> Void)?
    let passwordPanel = PasswordPanelController()
    private var localKeyMonitor: Any?
    private var savedActivationPolicy: NSApplication.ActivationPolicy?

    init(screens: any ScreenListing = NSScreenListing()) {
        self.screens = screens
    }

    func apply(_ command: OverlayCommand) {
        switch command {
        case .stay:
            break
        case .present(let reason):
            present(reason: reason)
        case .dismissSync:
            dismissSync()
        }
    }

    func present(reason: OverlayReason) {
        if isPresented { tearDownWindows() }
        isPresented = true
        lastReason = reason
        let descriptors = screens.screens
        MacLockLog.file("overlay present \(reason) screens=\(descriptors.count) attach=\(attachToScreen)")
        for descriptor in descriptors {
            let role: ShieldWindow.Role = descriptor.isPrimary ? .primary : .auxiliary
            let window = ShieldWindow(role: role, contentRect: descriptor.frame)
            if role == .primary {
                passwordPanel.view.removeFromSuperview()
                passwordPanel.configure(reason: reason)
                let panel = passwordPanel.view
                panel.frame = NSRect(origin: .zero, size: descriptor.frame.size)
                panel.autoresizingMask = [.width, .height]
                window.contentView = panel
            } else {
                let aux = AuxiliaryShieldView(frame: NSRect(origin: .zero, size: descriptor.frame.size))
                aux.autoresizingMask = [.width, .height]
                aux.onMouseDown = { [weak self] in
                    self?.windows.first(where: { $0.role == .primary })?.makeKeyAndOrderFront(nil)
                }
                window.contentView = aux
            }
            window.setFrame(descriptor.frame, display: false)
            if attachToScreen {
                if savedActivationPolicy == nil {
                    savedActivationPolicy = NSApp.activationPolicy()
                }
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                if role == .primary {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderFrontRegardless()
                }
                window.setFrame(descriptor.frame, display: true)
                window.sharingType = .none
                window.makeKey()
            }
            windows.append(window)
        }
        if attachToScreen {
            savedPresentationOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [
                .hideDock, .hideMenuBar, .disableAppleMenu,
                .disableProcessSwitching, .disableForceQuit,
                .disableSessionTermination, .disableHideApplication,
            ]
            installBackdoorMonitor()
            focusPasswordField()
            DispatchQueue.main.async { [weak self] in
                self?.focusPasswordField()
            }
        }
    }

    private func focusPasswordField() {
        guard attachToScreen, let window = primaryWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(passwordPanel.field)
        passwordPanel.field.selectText(nil)
    }

    func dismissSync() {
        dismissSyncCount += 1
        MacLockLog.file("overlay dismissSync count=\(dismissSyncCount)")
        tearDownWindows()
        isPresented = false
        lastReason = nil
        removeBackdoorMonitor()
        if attachToScreen {
            NSApp.presentationOptions = savedPresentationOptions
            if let savedActivationPolicy {
                NSApp.setActivationPolicy(savedActivationPolicy)
                self.savedActivationPolicy = nil
            }
        }
    }

    private func installBackdoorMonitor() {
        removeBackdoorMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if EscapeChord.isBackdoorUnlock(keyCode: Int64(event.keyCode), flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) {
                self?.onBackdoor?()
                return nil
            }
            return event
        }
    }

    private func removeBackdoorMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    func rebuild() {
        guard isPresented, let reason = lastReason else { return }
        rebuildCount += 1
        present(reason: reason)
    }

    var primaryWindow: ShieldWindow? { windows.first(where: { $0.role == .primary }) }
    var auxiliaryWindows: [ShieldWindow] { windows.filter { $0.role == .auxiliary } }

    private func tearDownWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
