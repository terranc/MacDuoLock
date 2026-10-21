import AppKit
import QuartzCore
import XCTest
@testable import MacLock

@MainActor
final class PermissionDragIllustrationTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/MacDuoLock.app", isDirectory: true)

    func testDirectionPointsTowardSeparatedSettingsWindow() {
        let guide = NSRect(x: 200, y: 200, width: 248, height: 350)
        let cases: [(NSRect, PermissionDragDirection)] = [
            (NSRect(x: -500, y: 100, width: 600, height: 650), .left),
            (NSRect(x: 500, y: 100, width: 600, height: 650), .right),
            (NSRect(x: 100, y: 600, width: 600, height: 650), .up),
            (NSRect(x: 100, y: -500, width: 600, height: 650), .down),
        ]
        for (settings, expected) in cases {
            XCTAssertEqual(PermissionDragDirection.toward(settingsFrame: settings, guideFrame: guide), expected)
        }
    }

    func testDirectionSupportsDisplaysWithNegativeCoordinates() {
        let guide = NSRect(x: -400, y: -500, width: 248, height: 350)
        let settings = NSRect(x: -1100, y: -600, width: 650, height: 700)
        XCTAssertEqual(PermissionDragDirection.toward(settingsFrame: settings, guideFrame: guide), .left)
    }

    func testOverlappingWindowsUseDominantCenterOffset() {
        let guide = NSRect(x: 0, y: 0, width: 248, height: 350)
        let cases: [(CGFloat, CGFloat, PermissionDragDirection)] = [
            (-100, 20, .left), (100, -20, .right), (20, 100, .up), (-20, -100, .down),
        ]
        for (dx, dy, expected) in cases {
            XCTAssertEqual(PermissionDragDirection.toward(settingsFrame: guide.offsetBy(dx: dx, dy: dy),
                                                         guideFrame: guide), expected)
        }
        XCTAssertEqual(PermissionDragDirection.toward(settingsFrame: guide, guideFrame: guide), .left)
        for direction in PermissionDragDirection.allCases {
            XCTAssertEqual(direction.titleKey, "title." + direction.rawValue)
        }
    }

    func testAnimationMovesDecorationTowardTargetAndKeepsDragHitAreaFixed() throws {
        _ = NSApplication.shared
        let view = PermissionDragIllustrationView(appURL: appURL, reduceMotion: { false })
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 248, height: 112))
        XCTAssertFalse(view.isAnimating)

        for direction in PermissionDragDirection.allCases {
            view.update(direction: direction, animated: false)
            let iconFrame = view.appIcon.frame
            view.update(direction: direction, animated: true)
            let animation = try animation(in: view)
            let movement = try XCTUnwrap(animation.animations?.first as? CAKeyframeAnimation)
            let points = try XCTUnwrap(movement.values as? [NSValue])
            let start = try XCTUnwrap(points.first).pointValue
            let end = try XCTUnwrap(points.last).pointValue
            switch direction {
            case .left: XCTAssertLessThan(end.x, start.x)
            case .right: XCTAssertGreaterThan(end.x, start.x)
            case .up: XCTAssertGreaterThan(end.y, start.y)
            case .down: XCTAssertLessThan(end.y, start.y)
            }
            XCTAssertEqual(view.appIcon.frame, iconFrame)
            XCTAssertTrue(view.bounds.contains(iconFrame))
            XCTAssertTrue(view.hitTest(NSPoint(x: iconFrame.midX, y: iconFrame.midY)) === view.appIcon)
            XCTAssertTrue(view.isAnimating)
        }
    }

    func testRepeatedUpdatesDoNotRestartAnimationButDirectionChangeDoes() throws {
        _ = NSApplication.shared
        let view = PermissionDragIllustrationView(appURL: appURL, reduceMotion: { false })
        view.update(direction: .left, animated: true)
        let startedAt = try animation(in: view).beginTime
        for _ in 0..<5 { view.update(direction: .left, animated: true) }
        XCTAssertEqual(try animation(in: view).beginTime, startedAt)
        view.update(direction: .right, animated: true)
        XCTAssertGreaterThan(try animation(in: view).beginTime, startedAt)
        view.update(direction: .right, animated: false)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(hasAnimation(in: view))
    }

    func testReduceMotionAndRealDraggingPauseAndResumeAnimation() {
        _ = NSApplication.shared
        var reduceMotion = true
        let view = PermissionDragIllustrationView(appURL: appURL, reduceMotion: { reduceMotion })
        view.update(direction: .left, animated: true)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(hasAnimation(in: view))

        reduceMotion = false
        view.update(direction: .left, animated: true)
        XCTAssertTrue(view.isAnimating)
        let iconFrame = view.appIcon.frame
        view.appIcon.onDraggingChanged?(true)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(hasAnimation(in: view))
        view.update(direction: .left, animated: true)
        XCTAssertFalse(view.isAnimating)
        view.appIcon.onDraggingChanged?(false)
        XCTAssertTrue(view.isAnimating)
        XCTAssertEqual(view.appIcon.frame, iconFrame)

        reduceMotion = true
        view.update(direction: .left, animated: true)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(hasAnimation(in: view))
        view.update(direction: .left, animated: false)
        reduceMotion = false
        view.appIcon.onDraggingChanged?(false)
        XCTAssertFalse(view.isAnimating)
    }

    private func hasAnimation(in view: NSView) -> Bool {
        view.layer?.sublayers?.contains { $0.animation(forKey: "permission.drag") != nil } ?? false
    }

    private func animation(in view: NSView) throws -> CAAnimationGroup {
        let layer = try XCTUnwrap(view.layer?.sublayers?.first { $0.animation(forKey: "permission.drag") != nil })
        return try XCTUnwrap(layer.animation(forKey: "permission.drag") as? CAAnimationGroup)
    }
}
