import AppKit
import QuartzCore

enum PermissionDragDirection: String, CaseIterable {
    case left, right, up, down

    static func toward(settingsFrame: NSRect, guideFrame: NSRect) -> Self {
        if settingsFrame.maxX <= guideFrame.minX { return .left }
        if settingsFrame.minX >= guideFrame.maxX { return .right }
        if settingsFrame.minY >= guideFrame.maxY { return .up }
        if settingsFrame.maxY <= guideFrame.minY { return .down }
        let dx = settingsFrame.midX - guideFrame.midX
        let dy = settingsFrame.midY - guideFrame.midY
        return abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
    }

    var titleKey: String { "title." + rawValue }
}

@MainActor
final class PermissionDragIllustrationView: NSView {
    let appIcon: PermissionAppDragView
    private(set) var direction: PermissionDragDirection = .left
    private(set) var isAnimating = false
    private let reduceMotion: () -> Bool
    private let ghost = CALayer()
    private var animationRequested = false
    private var isDragging = false
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter

    init(appURL: URL, reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        appIcon = PermissionAppDragView(appURL: appURL)
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(x: 0, y: 0, width: 248, height: 112))
        wantsLayer = true
        addSubview(appIcon)
        ghost.contents = appIcon.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        ghost.contentsGravity = .resizeAspect
        ghost.bounds = NSRect(x: 0, y: 0, width: 30, height: 30)
        ghost.opacity = 0
        layer?.addSublayer(ghost)
        appIcon.onDraggingChanged = { [weak self] dragging in
            self?.isDragging = dragging
            self?.refreshAnimation()
        }
        workspaceNotifications.addObserver(self, selector: #selector(displayOptionsChanged(_:)),
                                           name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        positionIcon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { workspaceNotifications.removeObserver(self) }

    override var intrinsicContentSize: NSSize { NSSize(width: 248, height: 112) }

    func update(direction: PermissionDragDirection, animated: Bool) {
        if self.direction != direction {
            self.direction = direction
            positionIcon()
            stopAnimation()
            needsDisplay = true
        }
        animationRequested = animated
        refreshAnimation()
    }

    @objc private func displayOptionsChanged(_ notification: Notification) { refreshAnimation() }

    private var targetRect: NSRect {
        switch direction {
        case .left: return NSRect(x: 4, y: 24, width: 82, height: 64)
        case .right: return NSRect(x: 162, y: 24, width: 82, height: 64)
        case .up: return NSRect(x: 100, y: 76, width: 48, height: 36)
        case .down: return NSRect(x: 100, y: 0, width: 48, height: 36)
        }
    }

    private func positionIcon() {
        switch direction {
        case .left: appIcon.frame = NSRect(x: 174, y: 24, width: 64, height: 64)
        case .right: appIcon.frame = NSRect(x: 10, y: 24, width: 64, height: 64)
        case .up: appIcon.frame = NSRect(x: 100, y: 0, width: 48, height: 48)
        case .down: appIcon.frame = NSRect(x: 100, y: 64, width: 48, height: 48)
        }
    }

    private func refreshAnimation() {
        guard animationRequested, !isDragging, !reduceMotion() else { stopAnimation(); return }
        guard !isAnimating else { return }
        let start = NSPoint(x: appIcon.frame.midX, y: appIcon.frame.midY)
        let rowHeight: CGFloat = targetRect.width < 60 ? 4 : 9
        let end = NSPoint(x: targetRect.midX, y: targetRect.minY + 9 + rowHeight * 1.5)
        let movement = CAKeyframeAnimation(keyPath: "position")
        movement.values = [NSValue(point: start), NSValue(point: start), NSValue(point: end), NSValue(point: end)]
        movement.keyTimes = [0, 0.15, 0.78, 1]
        movement.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
                                    CAMediaTimingFunction(name: .linear)]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.55, 0.45, 0, 0]
        fade.keyTimes = [0, 0.15, 0.60, 0.80, 1]
        let animation = CAAnimationGroup()
        animation.animations = [movement, fade]
        animation.duration = 2.8
        animation.beginTime = ghost.convertTime(CACurrentMediaTime(), from: nil)
        animation.repeatCount = .infinity
        ghost.add(animation, forKey: "permission.drag")
        isAnimating = true
    }

    private func stopAnimation() {
        guard isAnimating else { return }
        ghost.removeAnimation(forKey: "permission.drag")
        isAnimating = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let target = targetRect
        let compact = target.width < 60
        NSColor.controlBackgroundColor.setFill()
        let outline = NSBezierPath(roundedRect: target.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.stroke()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
        for index in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: target.minX + 7 + CGFloat(index) * 6,
                                       y: target.maxY - 10, width: 3, height: 3)).fill()
        }
        let rowHeight: CGFloat = compact ? 4 : 9
        for index in 0..<3 {
            let row = NSRect(x: target.minX + 8, y: target.minY + 6 + CGFloat(index) * (rowHeight + 3),
                             width: target.width - 16, height: rowHeight)
            if index == 1 {
                NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
                let drop = NSBezierPath(roundedRect: row.insetBy(dx: -2, dy: -1), xRadius: 3, yRadius: 3)
                drop.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
                drop.setLineDash([3, 2], count: 2, phase: 0)
                drop.stroke()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: row, xRadius: 2, yRadius: 2).fill()
            }
        }
        drawArrow()
    }

    private func drawArrow() {
        let start: NSPoint
        let end: NSPoint
        switch direction {
        case .left: start = NSPoint(x: 157, y: 56); end = NSPoint(x: 105, y: 56)
        case .right: start = NSPoint(x: 91, y: 56); end = NSPoint(x: 143, y: 56)
        case .up: start = NSPoint(x: 124, y: 53); end = NSPoint(x: 124, y: 69)
        case .down: start = NSPoint(x: 124, y: 59); end = NSPoint(x: 124, y: 43)
        }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy), ux = dx / length, uy = dy / length
        let arrow = NSBezierPath()
        arrow.move(to: start)
        arrow.line(to: end)
        arrow.move(to: NSPoint(x: end.x - ux * 7 - uy * 5, y: end.y - uy * 7 + ux * 5))
        arrow.line(to: end)
        arrow.line(to: NSPoint(x: end.x - ux * 7 + uy * 5, y: end.y - uy * 7 - ux * 5))
        arrow.lineWidth = 3
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.controlAccentColor.setStroke()
        arrow.stroke()
    }
}
