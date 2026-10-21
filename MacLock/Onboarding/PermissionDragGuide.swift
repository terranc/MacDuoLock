import AppKit

private func dragGuideText(_ key: String) -> String {
    String(format: NSLocalizedString("maclock.setup.drag." + key, comment: ""),
           AppPermission.accessibility.settingsTitle)
}

enum PermissionGuidePlacement {
    static func frame(size: NSSize, settingsFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let gap: CGFloat = 12
        let available = visibleFrame.insetBy(dx: gap, dy: gap)
        let y = min(max(settingsFrame.maxY - size.height, available.minY), available.maxY - size.height)
        let right = NSRect(x: settingsFrame.maxX + gap, y: y, width: size.width, height: size.height)
        let left = NSRect(x: settingsFrame.minX - gap - size.width, y: y, width: size.width, height: size.height)
        if available.contains(right) { return right }
        if available.contains(left) { return left }

        let x = min(max(settingsFrame.midX - size.width / 2, available.minX), available.maxX - size.width)
        let below = NSRect(x: x, y: settingsFrame.minY - gap - size.height, width: size.width, height: size.height)
        if available.contains(below) { return below }
        let above = NSRect(x: x, y: settingsFrame.maxY + gap, width: size.width, height: size.height)
        if available.contains(above) { return above }

        // On a narrow display there is no non-overlapping space; keep the guide
        // at the edge with the most room, with all controls on screen.
        let moreRoomOnRight = available.maxX - settingsFrame.maxX >= settingsFrame.minX - available.minX
        return NSRect(x: moreRoomOnRight ? available.maxX - size.width : available.minX,
                      y: y, width: size.width, height: size.height)
    }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PermissionDragGuide: NSWindowController, NSWindowDelegate {
    private let isAuthorized: () -> Bool
    private let onReturnToSetup: () -> Void
    private let appURL = Bundle.main.bundleURL
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var timer: Timer?
    private var isFollowing = false
    private weak var directionTitle: NSTextField?
    private lazy var illustration = PermissionDragIllustrationView(appURL: appURL)

    init(isAuthorized: @escaping () -> Bool, onReturnToSetup: @escaping () -> Void) {
        self.isAuthorized = isAuthorized
        self.onReturnToSetup = onReturnToSetup
        let panel = PermissionGuidePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 330),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = AppPermission.accessibility.settingsTitle
        panel.identifier = NSUserInterfaceItemIdentifier("setup.drag.guide")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContent()
        if let content = panel.contentView {
            panel.setContentSize(NSSize(width: 280, height: max(330, content.fittingSize.height)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        workspaceNotifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func present() {
        if !isFollowing {
            isFollowing = true
            for notification in [NSWorkspace.didActivateApplicationNotification,
                                 NSWorkspace.didHideApplicationNotification,
                                 NSWorkspace.didTerminateApplicationNotification,
                                 NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
                workspaceNotifications.addObserver(self, selector: #selector(environmentChanged(_:)),
                                                   name: notification, object: nil)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged(_:)),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.followSettings() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        followSettings()
    }

    func dismiss() {
        isFollowing = false
        timer?.invalidate()
        timer = nil
        workspaceNotifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        illustration.update(direction: illustration.direction, animated: false)
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }

    @objc private func environmentChanged(_ notification: Notification) {
        followSettings()
    }

    private func followSettings() {
        guard isFollowing, let window else { return }
        if isAuthorized() {
            dismiss()
            onReturnToSetup()
            return
        }
        guard let settings = NSWorkspace.shared.frontmostApplication,
              settings.bundleIdentifier == "com.apple.systempreferences", !settings.isHidden,
              let settingsFrame = Self.settingsFrame(processID: settings.processIdentifier),
              let screen = NSScreen.screens.max(by: {
                  Self.intersectionArea($0.frame, settingsFrame) < Self.intersectionArea($1.frame, settingsFrame)
              }) else {
            illustration.update(direction: illustration.direction, animated: false)
            window.orderOut(nil)
            return
        }
        let frame = PermissionGuidePlacement.frame(size: window.frame.size, settingsFrame: settingsFrame,
                                                   visibleFrame: screen.visibleFrame)
        let direction = PermissionDragDirection.toward(settingsFrame: settingsFrame, guideFrame: frame)
        directionTitle?.stringValue = dragGuideText(direction.titleKey)
        window.setFrame(frame, display: true)
        if !window.isVisible { window.orderFrontRegardless() }
        illustration.update(direction: direction, animated: window.isVisible)
    }

    private static func settingsFrame(processID: pid_t) -> NSRect? {
        // Window metadata works before Accessibility is granted. Never read
        // window titles or contents, or request Screen Recording to place a guide.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]],
              let primaryScreen = NSScreen.screens.first else { return nil }
        let bounds = windows.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary), !rect.isEmpty else { return nil }
            return rect
        }.max { $0.width * $0.height < $1.width * $1.height }
        guard let bounds else { return nil }
        return NSRect(x: bounds.minX, y: primaryScreen.frame.maxY - bounds.maxY,
                      width: bounds.width, height: bounds.height)
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func makeContent() -> NSView {
        let content = NSView()
        let title = label("title.left", size: 15, weight: .semibold)
        directionTitle = title
        let instruction = label("instruction", size: 12)
        let caption = label("icon", size: 11)
        caption.alignment = .center
        caption.textColor = .secondaryLabelColor
        let enable = label("enable", size: 12)
        let back = button(dragGuideText("return"), action: #selector(returnToSetup(_:)))
        back.isBordered = false
        back.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, instruction, illustration, caption, enable, back])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
            illustration.widthAnchor.constraint(equalToConstant: 248),
            illustration.heightAnchor.constraint(equalToConstant: 112),
        ])
        for view in [title, instruction, caption, enable, back] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return content
    }

    private func label(_ key: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: dragGuideText(key))
        label.font = .systemFont(ofSize: size, weight: weight)
        label.preferredMaxLayoutWidth = 248
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        return button
    }

    @objc private func returnToSetup(_ sender: Any?) {
        dismiss()
        onReturnToSetup()
    }
}

@MainActor
final class PermissionAppDragView: NSImageView, NSDraggingSource {
    let appURL: URL
    var onDraggingChanged: ((Bool) -> Void)?

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        image = NSWorkspace.shared.icon(forFile: appURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityIdentifier("setup.drag.icon")
        setAccessibilityLabel(dragGuideText("icon"))
        setAccessibilityHelp(dragGuideText("icon.help"))
        toolTip = dragGuideText("icon.help")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        card.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.2).setStroke()
        card.stroke()
        image?.draw(in: bounds.insetBy(dx: 7, dy: 7), from: .zero, operation: .sourceOver, fraction: 1)
        let badge = NSRect(x: bounds.maxX - 21, y: bounds.minY + 2, width: 19, height: 19)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white]))?
            .draw(in: badge.insetBy(dx: 3, dy: 3), from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func draggingItem() -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        return item
    }

    override func mouseDragged(with event: NSEvent) {
        beginDraggingSession(with: [draggingItem()], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDraggingChanged?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDraggingChanged?(false)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
