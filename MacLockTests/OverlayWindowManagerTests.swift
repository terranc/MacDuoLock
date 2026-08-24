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
        // Asserted against the factory default rather than LockShortcutStore, so
        // a developer who customised the chord does not fail this test.
        let shortcut = LockShortcut.default
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        XCTAssertTrue(shortcut.matches(keyCode: 50, flags: flags))
        XCTAssertTrue(shortcut.matches(keyCode: 10, flags: flags))
        XCTAssertFalse(shortcut.matches(keyCode: 50, flags: [.maskCommand, .maskAlternate]))
        XCTAssertFalse(EscapeChord.shouldSwallow(keyCode: 50, flags: flags))
        XCTAssertTrue(EscapeChord.shouldSwallow(keyCode: 50, flags: .maskCommand))
        XCTAssertEqual(shortcut.displayString, "⌃⌥⌘`")
    }

    func testCustomShortcutMatchesOnlyItsOwnChord() {
        let custom = LockShortcut(
            keyCodes: [37],
            modifiers: CGEventFlags([.maskControl, .maskShift]).rawValue,
            keyEquivalent: "l",
            label: "L"
        )
        XCTAssertTrue(custom.matches(keyCode: 37, flags: [.maskControl, .maskShift]))
        XCTAssertFalse(custom.matches(keyCode: 37, flags: [.maskControl]))
        XCTAssertFalse(custom.matches(keyCode: 50, flags: [.maskControl, .maskShift]))
        XCTAssertEqual(custom.displayString, "⌃⇧L")
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

    func testShowErrorKeepsTypedPasswordAndClearsCellPlaceholder() {
        let panel = PasswordPanelController()
        _ = panel.view
        panel.configure(reason: .passwordOnly)
        panel.field.stringValue = "wrong-pass"
        panel.showError("nope")
        XCTAssertEqual(panel.field.stringValue, "wrong-pass")
        XCTAssertNil(panel.field.placeholderAttributedString)
        XCTAssertTrue(panel.field.isEnabled)
    }

    func testSetBusyLeavesFieldEnabled() {
        let panel = PasswordPanelController()
        _ = panel.view
        panel.configure(reason: .passwordOnly)
        panel.setBusy(true)
        XCTAssertTrue(panel.field.isEnabled)
        panel.setBusy(false)
        XCTAssertTrue(panel.field.isEnabled)
    }

    func testPasswordFieldAcceptsFocusAndTypingHidesPlaceholder() {
        let (panel, window) = makeOffscreenKeyPanel()
        defer { window.close() }

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.makeFirstResponder(panel.field), "password field must become first responder")
        pump()
        XCTAssertNotNil(panel.field.currentEditor(), "field editor must exist after focus")
        XCTAssertTrue(panel.isPlaceholderVisible, "empty focused field still shows placeholder")

        panel.field.currentEditor()?.insertText("abc")
        panel.refreshGhost()
        pump()

        XCTAssertEqual(panel.field.stringValue, "abc")
        XCTAssertFalse(panel.isPlaceholderVisible, "placeholder must hide once characters are present")
        XCTAssertTrue(panel.field.isEnabled)
    }

    func testRelockClearsPreviousPasswordAndShowsPlaceholder() {
        let listing = FakeScreenListing(screens: [
            ScreenDescriptor(displayID: 1, frame: .init(x: 0, y: 0, width: 800, height: 600), isPrimary: true),
        ])
        let manager = OverlayWindowManager(screens: listing)
        manager.attachToScreen = false
        manager.present(reason: .passwordOnly)
        manager.passwordPanel.field.stringValue = "leftover-secret"
        manager.passwordPanel.refreshGhost()
        XCTAssertFalse(manager.passwordPanel.isPlaceholderVisible)
        manager.dismissSync()
        manager.present(reason: .lockNow)
        XCTAssertEqual(manager.passwordPanel.field.stringValue, "")
        XCTAssertTrue(
            manager.passwordPanel.isPlaceholderVisible,
            "relock must open on an empty field with placeholder, not leftover text"
        )
        manager.dismissSync()
    }

    func testSelectAllAndReplaceLeavesNoUnderline() {
        let (panel, window) = makeOffscreenKeyPanel()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(panel.field))
        pump()
        guard let editor = panel.field.currentEditor() as? NSTextView else {
            XCTFail("missing field editor")
            return
        }
        editor.insertText("abc")
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.selectedRange = all
        editor.setMarkedText(
            "x",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: all
        )
        panel.field.polishEditor()
        pump()

        XCTAssertFalse(hasUnderline(editor), "replacing a selection must not leave an underline under old/empty text")
        let markedUnderline = (editor.markedTextAttributes?[.underlineStyle] as? Int) ?? 0
        XCTAssertEqual(markedUnderline, 0, "IME marked text must not use underline in the password field")
    }

    func testPasswordErrorKeepsFocusWithoutEditorChrome() {
        let (panel, window) = makeOffscreenKeyPanel()
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(panel.field))
        pump()
        panel.field.currentEditor()?.insertText("badpw")
        panel.refreshGhost()

        panel.setBusy(true)
        panel.setBusy(false)
        panel.showError(NSLocalizedString("maclock.unlock.wrong", comment: ""))
        pump()

        XCTAssertEqual(panel.field.stringValue, "badpw")
        let responder = window.firstResponder
        XCTAssertTrue(
            responder === panel.field || responder === panel.field.currentEditor(),
            "focus must stay in the password field after error, got \(String(describing: responder))"
        )
        let editor = panel.field.currentEditor() as? NSTextView
        XCTAssertNotNil(editor)
        XCTAssertFalse(editor?.drawsBackground ?? true, "field editor must not paint a background")
        XCTAssertEqual(editor?.backgroundColor, NSColor.clear)
        let underline = (editor?.typingAttributes[.underlineStyle] as? Int) ?? 0
        XCTAssertEqual(underline, 0, "no extra underline after error")
        XCTAssertFalse(panel.isPlaceholderVisible)
    }

    private func makeOffscreenKeyPanel() -> (PasswordPanelController, ShieldWindow) {
        let panel = PasswordPanelController()
        panel.configure(reason: .passwordOnly)
        let window = ShieldWindow(
            role: .primary,
            contentRect: NSRect(x: -2400, y: -2400, width: 800, height: 600)
        )
        window.level = .normal
        window.collectionBehavior = []
        window.contentView = panel.view
        window.setFrameOrigin(NSPoint(x: -2400, y: -2400))
        window.makeKeyAndOrderFront(nil)
        panel.view.layoutSubtreeIfNeeded()
        return (panel, window)
    }

    private func pump() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func hasUnderline(_ editor: NSTextView) -> Bool {
        let storage = editor.textStorage
        let length = storage?.length ?? 0
        let full = NSRange(location: 0, length: max(length, (editor.string as NSString).length))
        var found = false
        storage?.enumerateAttribute(.underlineStyle, in: full) { value, _, _ in
            if let v = value as? Int, v != 0 { found = true }
        }
        if length > 0,
           editor.layoutManager?.temporaryAttribute(
            .underlineStyle,
            atCharacterIndex: 0,
            effectiveRange: nil
           ) != nil {
            found = true
        }
        return found
    }

    /// These two windows are laid out entirely in code and cannot be eyeballed in
    /// CI, so assert they resolve to a sane size instead of collapsing to zero.
    func testSettingsAndOnboardingProduceSaneLayouts() {
        let secrets = GateSecretsStore(keychain: FakeKeychain())
        let passwords = PasswordStore(secrets: secrets, clock: FakeClock())
        let gate = SessionGate(
            secrets: secrets,
            overlay: OverlaySpy(),
            tap: TapSpy(),
            presence: PresenceSpy(),
            clock: FakeClock()
        )
        let flow = OnboardingFlow(passwords: passwords, secrets: secrets, gate: gate)

        let settings = SettingsContentViewController(
            flow: flow,
            loginItems: LoginItemService(),
            tap: EventTapController()
        )
        // SwiftUI-hosted: assert a plausible box rather than an exact size, so
        // the test does not break every time the form gains a row.
        let settingsSize = settings.view.fittingSize
        XCTAssertGreaterThan(settingsSize.width, 380)
        XCTAssertGreaterThan(settingsSize.height, 300)

        let onboarding = OnboardingWindowController(flow: flow)
        guard let content = onboarding.window?.contentView else {
            return XCTFail("onboarding window has no content view")
        }
        XCTAssertEqual(content.fittingSize.width, 468, accuracy: 1)
        XCTAssertGreaterThan(content.fittingSize.height, 250)
        // The window must hug its content: no dead band under the form.
        XCTAssertEqual(content.frame.height, content.fittingSize.height, accuracy: 1)
    }
}
