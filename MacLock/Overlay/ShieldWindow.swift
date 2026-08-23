import AppKit

final class ShieldWindow: NSWindow {
    enum Role {
        case primary, auxiliary
    }

    let role: Role

    init(role: Role, contentRect: CGRect) {
        self.role = role
        super.init(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        hidesOnDeactivate = false
        canHide = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { role == .primary }
    override var canBecomeMain: Bool { role == .primary }
    override var acceptsFirstResponder: Bool { role == .primary }
}
