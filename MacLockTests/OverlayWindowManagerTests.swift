import AppKit
import XCTest
@testable import MacLock

@MainActor
final class OverlayWindowManagerTests: XCTestCase {
    override func setUp() {
        _ = NSApplication.shared
    }

    func testNScreensCreateNWindowsOnePrimaryKeyable() {
        let listing = FakeScreenListing(screens: [
            ScreenDescriptor(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 80), isPrimary: true),
            ScreenDescriptor(displayID: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 80), isPrimary: false),
            ScreenDescriptor(displayID: 3, frame: CGRect(x: 200, y: 0, width: 100, height: 80), isPrimary: false),
        ])
        let manager = OverlayWindowManager(screens: listing)
        manager.attachToScreen = false
        manager.present(reason: .passwordOnly)
        XCTAssertEqual(manager.windows.count, 3)
        XCTAssertEqual(manager.primaryWindow?.frame.size, CGSize(width: 100, height: 80))
        XCTAssertEqual(manager.primaryWindow?.contentView?.frame.size, CGSize(width: 100, height: 80))
        XCTAssertEqual(manager.windows.filter { $0.role == .primary }.count, 1)
        XCTAssertEqual(manager.auxiliaryWindows.count, 2)
        XCTAssertTrue(manager.primaryWindow?.canBecomeKey == true)
        XCTAssertTrue(manager.primaryWindow?.canBecomeMain == true)
        for aux in manager.auxiliaryWindows {
            XCTAssertFalse(aux.canBecomeKey)
            XCTAssertFalse(aux.canBecomeMain)
        }
        manager.dismissSync()
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertEqual(manager.dismissSyncCount, 1)
    }

    func testRebuildWhenPresented() {
        let listing = FakeScreenListing(screens: [
            ScreenDescriptor(displayID: 7, frame: .init(x: 0, y: 0, width: 10, height: 10), isPrimary: true),
        ])
        let manager = OverlayWindowManager(screens: listing)
        manager.attachToScreen = false
        manager.rebuild()
        XCTAssertEqual(manager.rebuildCount, 0)
        manager.present(reason: .relaunchWhileUnlocked)
        manager.rebuild()
        XCTAssertEqual(manager.rebuildCount, 1)
        XCTAssertEqual(manager.windows.count, 1)
        manager.dismissSync()
    }

    func testPrimaryUsesExplicitFlagNotNSScreenMain() {
        let listing = FakeScreenListing(screens: [
            ScreenDescriptor(displayID: 99, frame: .init(x: 0, y: 0, width: 10, height: 10), isPrimary: false),
            ScreenDescriptor(displayID: 5, frame: .init(x: 20, y: 0, width: 10, height: 10), isPrimary: true),
        ])
        let manager = OverlayWindowManager(screens: listing)
        manager.attachToScreen = false
        manager.present(reason: .passwordOnly)
        XCTAssertEqual(manager.primaryWindow?.frame.origin.x, 20)
        manager.dismissSync()
    }

    func testBackdoorChordIsControlOptionCommandGrave() {
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        XCTAssertTrue(EscapeChord.isBackdoorUnlock(keyCode: 50, flags: flags))
        XCTAssertTrue(EscapeChord.isBackdoorUnlock(keyCode: 10, flags: flags))
        XCTAssertFalse(EscapeChord.shouldSwallow(keyCode: 50, flags: flags))
        XCTAssertTrue(EscapeChord.shouldSwallow(keyCode: 50, flags: .maskCommand))
        XCTAssertFalse(EscapeChord.isBackdoorUnlock(keyCode: 50, flags: [.maskCommand, .maskAlternate]))
    }

    func testDismissSyncIsSynchronous() {
        let listing = FakeScreenListing(screens: [
            ScreenDescriptor(displayID: 1, frame: .init(x: 0, y: 0, width: 10, height: 10), isPrimary: true),
        ])
        let manager = OverlayWindowManager(screens: listing)
        manager.attachToScreen = false
        manager.present(reason: .passwordOnly)
        manager.dismissSync()
        XCTAssertFalse(manager.isPresented)
        XCTAssertEqual(manager.windows.count, 0)
    }
}
