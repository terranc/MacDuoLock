import AppKit
import XCTest
@testable import MacLock

@MainActor
final class PermissionDragGuideTests: XCTestCase {
    private let guideSize = NSSize(width: 280, height: 372)

    func testPlacesBesideSettingsWithoutOverlapping() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let settings = NSRect(x: 300, y: 125, width: 700, height: 650)
        let guide = PermissionGuidePlacement.frame(size: guideSize, settingsFrame: settings, visibleFrame: visible)

        XCTAssertTrue(visible.contains(guide))
        XCTAssertGreaterThan(guide.minX, settings.maxX)
        XCTAssertFalse(guide.intersects(settings))
    }

    func testPlacesOnLeftWhenSettingsIsAtRightEdge() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let settings = NSRect(x: 740, y: 125, width: 700, height: 650)
        let guide = PermissionGuidePlacement.frame(size: guideSize, settingsFrame: settings, visibleFrame: visible)

        XCTAssertTrue(visible.contains(guide))
        XCTAssertLessThan(guide.maxX, settings.minX)
        XCTAssertFalse(guide.intersects(settings))
    }

    func testUsesSecondaryDisplayWithNegativeCoordinates() {
        let visible = NSRect(x: -1600, y: -120, width: 1600, height: 950)
        let settings = NSRect(x: -1100, y: 10, width: 700, height: 650)
        let guide = PermissionGuidePlacement.frame(size: guideSize, settingsFrame: settings, visibleFrame: visible)

        XCTAssertTrue(visible.contains(guide))
        XCTAssertLessThan(guide.maxX, 0)
        XCTAssertFalse(guide.intersects(settings))
    }

    func testUsesSpaceBelowOnNarrowDisplay() {
        let visible = NSRect(x: 0, y: 25, width: 800, height: 1100)
        let settings = NSRect(x: 30, y: 550, width: 740, height: 550)
        let guide = PermissionGuidePlacement.frame(size: guideSize, settingsFrame: settings, visibleFrame: visible)

        XCTAssertTrue(visible.contains(guide))
        XCTAssertLessThan(guide.maxY, settings.minY)
        XCTAssertFalse(guide.intersects(settings))
    }

    func testKeepsEveryControlOnscreenWhenNoAdjacentSpaceExists() {
        let visible = NSRect(x: 0, y: 25, width: 800, height: 700)
        let settings = NSRect(x: -30, y: -20, width: 840, height: 760)
        let guide = PermissionGuidePlacement.frame(size: guideSize, settingsFrame: settings, visibleFrame: visible)

        XCTAssertTrue(visible.contains(guide))
        XCTAssertEqual(guide.size, guideSize)
    }

    func testPanelCannotStealKeyboardFocusFromSystemSettings() throws {
        _ = NSApplication.shared
        let controller = PermissionDragGuide(isAuthorized: { false }, onReturnToSetup: {})
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        defer { controller.dismiss() }

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isVisible, "constructing a guide must wait for System Settings")
    }

    func testDraggableIconSuppliesRealFileURLToOtherApps() throws {
        _ = NSApplication.shared
        let appURL = URL(fileURLWithPath: "/Applications/MacDuoLock.app", isDirectory: true)
        let icon = PermissionAppDragView(appURL: appURL)
        let item = icon.draggingItem()
        let writer = try XCTUnwrap(item.item as? NSURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(pasteboard.writeObjects([writer]))
        let urlString = try XCTUnwrap(pasteboard.string(forType: .fileURL))
        let draggedURL = try XCTUnwrap(URL(string: urlString))
        XCTAssertTrue(draggedURL.isFileURL)
        XCTAssertEqual(draggedURL.standardizedFileURL, appURL.standardizedFileURL)
        XCTAssertFalse(icon.needsPanelToBecomeKey)
        XCTAssertTrue(icon.acceptsFirstMouse(for: nil))
    }

    func testClosingGuideStopsIllustrationAndKeepsOnlyReturnAction() throws {
        _ = NSApplication.shared
        let controller = PermissionDragGuide(isAuthorized: { false }, onReturnToSetup: {})
        let content = try XCTUnwrap(controller.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap { descendants($0) }
        }
        let views = descendants(content)
        let illustration = try XCTUnwrap(views.compactMap { $0 as? PermissionDragIllustrationView }.first)
        let buttons = views.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map(\.title), [NSLocalizedString("maclock.setup.drag.return", comment: "")])
        illustration.update(direction: .left, animated: true)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(illustration.isAnimating)
        }

        controller.close()

        XCTAssertFalse(illustration.isAnimating)
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }

    func testDismissDoesNotReturnToSetupAndAuthorizedPresentReturnsOnce() {
        _ = NSApplication.shared
        var returns = 0
        let controller = PermissionDragGuide(isAuthorized: { true }, onReturnToSetup: { returns += 1 })

        controller.dismiss()
        XCTAssertEqual(returns, 0)
        controller.present()
        XCTAssertEqual(returns, 1)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.dismiss()
        XCTAssertEqual(returns, 1)
    }
}
