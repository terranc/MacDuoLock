import AppKit
import XCTest
@testable import MacLock

@MainActor
final class OverlayWindowManagerTests: XCTestCase {
    override func setUp() {
        _ = NSApplication.shared
    }

    func testShieldsRemainReadableByRemoteCaptureAfterRebuild() {
        let listing = FakeScreenListing(screens: [
            // Keep even the ordered windows offscreen; never cover the developer's desktop.
            ScreenDescriptor(displayID: 1, frame: CGRect(x: -3000, y: -3000, width: 100, height: 80), isPrimary: true),
            ScreenDescriptor(displayID: 2, frame: CGRect(x: -2900, y: -3000, width: 100, height: 80), isPrimary: false),
        ])
        for attachToScreen in [false, true] {
            let manager = OverlayWindowManager(screens: listing)
            manager.attachToScreen = attachToScreen
            defer { manager.dismissSync() }

            manager.present(reason: .passwordOnly)
            XCTAssertEqual(manager.windows.count, 2)
            for window in manager.windows {
                XCTAssertEqual(window.sharingType, .readOnly, "remote capture must include the shield")
            }

            manager.rebuild()
            XCTAssertEqual(manager.windows.count, 2)
            for window in manager.windows {
                XCTAssertEqual(window.sharingType, .readOnly, "display changes must preserve remote visibility")
            }
        }
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

    func testHelpCanOpenAndCloseWithoutLosingPassword() throws {
        let (panel, window) = makeOffscreenKeyPanel()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(panel.field))
        pump()
        panel.field.currentEditor()?.insertText("partial-password")
        let responder = window.firstResponder
        XCTAssertTrue(panel.helpCard.isHidden)

        panel.helpButton.performClick(nil)
        XCTAssertFalse(panel.helpCard.isHidden)
        XCTAssertEqual(panel.helpCard.window?.level, window.level)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(panel.field.currentEditor()?.string, "partial-password")
        panel.helpClose.performClick(nil)
        XCTAssertTrue(panel.helpCard.isHidden)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(panel.field.currentEditor()?.string, "partial-password")
        panel.helpButton.performClick(nil)
        let editor = try XCTUnwrap(panel.field.currentEditor() as? NSTextView)
        XCTAssertTrue(panel.control(panel.field, textView: editor,
                                    doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(panel.helpCard.isHidden)
        panel.helpButton.performClick(nil)
        panel.configure(reason: .lockNow)
        XCTAssertTrue(panel.helpCard.isHidden, "a new lock starts with help dismissed")
    }

    func testSubmitTracksLatestEditorTextEvenWhenCellIsStale() throws {
        let (panel, window) = makeOffscreenKeyPanel()
        defer { window.close() }
        XCTAssertFalse(panel.submit.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(panel.field))
        pump()
        let editor = try XCTUnwrap(panel.field.currentEditor() as? NSTextView)
        editor.string = " "
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.field))
        XCTAssertTrue(panel.submit.isEnabled, "spaces are valid password characters")
        XCTAssertEqual(panel.submit.contentTintColor, .black)

        // Deletion may reach the editor before it reaches the control's cell.
        window.makeFirstResponder(nil)
        panel.field.stringValue = "stale-cell"
        XCTAssertTrue(window.makeFirstResponder(panel.field))
        let editingAgain = try XCTUnwrap(panel.field.currentEditor() as? NSTextView)
        editingAgain.string = ""
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.field))
        XCTAssertFalse(panel.submit.isEnabled)
        XCTAssertTrue(panel.isPlaceholderVisible)
        var submitted = false
        panel.onSubmit = { _ in submitted = true }
        panel.field.sendAction(panel.field.action, to: panel.field.target)
        XCTAssertFalse(submitted, "Return must not submit an empty editor")

        editingAgain.insertText("pasted-password")
        XCTAssertTrue(panel.submit.isEnabled)
        panel.resetInput()
        XCTAssertFalse(panel.submit.isEnabled)
        XCTAssertTrue(panel.isPlaceholderVisible)
    }

    func testSubmitRestoresTypedStateAfterBusyAndKeepsUnavailableDisabled() {
        let panel = PasswordPanelController()
        _ = panel.view
        panel.configure(reason: .passwordOnly)
        panel.field.stringValue = "wrong-password"
        panel.showError("Incorrect password")
        XCTAssertTrue(panel.submit.isEnabled)
        panel.setBusy(true)
        XCTAssertTrue(panel.submit.isHidden)
        XCTAssertFalse(panel.submit.isEnabled)
        panel.setBusy(false)
        XCTAssertFalse(panel.submit.isHidden)
        XCTAssertTrue(panel.submit.isEnabled)
        XCTAssertEqual(panel.field.stringValue, "wrong-password")
        XCTAssertEqual(panel.hint.stringValue, "Incorrect password")
        panel.resetInput()
        panel.setBusy(true)
        panel.setBusy(false)
        XCTAssertFalse(panel.submit.isEnabled)
        panel.configure(reason: .keychainUnavailable)
        panel.field.stringValue = "password"
        panel.setBusy(true)
        panel.setBusy(false)
        XCTAssertFalse(panel.field.isEnabled)
        XCTAssertFalse(panel.submit.isEnabled)
    }

    func testSubmitReadsFieldEditorWhenCellIsStale() {
        let (panel, window) = makeOffscreenKeyPanel()
        defer { window.close() }
        var submitted: String?
        panel.onSubmit = { submitted = $0 }

        XCTAssertTrue(window.makeFirstResponder(panel.field))
        pump()
        guard let editor = panel.field.currentEditor() as? NSTextView else {
            XCTFail("missing field editor")
            return
        }
        // Real typing lives in the field editor. The cell can lag (IME commit,
        // layer-backed ancestors), which is what made a just-changed password
        // look "wrong" on the shield.
        panel.field.stringValue = ""
        (panel.field.cell as? NSTextFieldCell)?.stringValue = ""
        editor.string = "newly-set-password"

        panel.field.sendAction(panel.field.action, to: panel.field.target)
        pump()
        XCTAssertEqual(submitted, "newly-set-password")
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

    func testDetectMenuRowMatchesSystemItemMetrics() throws {
        let menu = StatusItemController().makeMenu(for: .unlocked, detecting: false)
        let row = try XCTUnwrap(menu.items.first { $0.view != nil }?.view)
        XCTAssertEqual(row.frame.height, 24)
        row.setFrameSize(NSSize(width: 206, height: 24))
        row.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(row.subviews.first { $0 is NSImageView })
        let title = try XCTUnwrap(row.subviews.first { $0 is NSTextField })
        XCTAssertEqual(icon.frame, NSRect(x: 16, y: 5.5, width: 14, height: 13))
        XCTAssertEqual(title.frame.origin.x, 34)
        XCTAssertEqual(title.frame.origin.y, 4)
        XCTAssertEqual(title.frame.height, 16)
    }

    func testDetectMenuDisabledAndRelabeledWhileDetecting() {
        let idle = StatusItemController().makeMenu(for: .unlocked, detecting: false)
        XCTAssertFalse(idle.autoenablesItems)
        let idleDetect = idle.items.first {
            $0.title == NSLocalizedString("maclock.menu.detect", comment: "")
        }
        XCTAssertNotNil(idleDetect)
        XCTAssertNotNil(idleDetect?.view, "custom view keeps the status menu open on click")
        XCTAssertTrue(idleDetect?.isEnabled ?? false)

        let busy = StatusItemController().makeMenu(for: .unlocked, detecting: true)
        XCTAssertFalse(busy.autoenablesItems)
        let busyDetect = busy.items.first {
            $0.title == NSLocalizedString("maclock.menu.detect.busy", comment: "")
        }
        XCTAssertNotNil(busyDetect)
        XCTAssertNotNil(busyDetect?.view)
        XCTAssertFalse(busyDetect?.isEnabled ?? true)
        XCTAssertNil(idle.items.first {
            $0.title == NSLocalizedString("maclock.menu.detect.busy", comment: "")
        })
    }

    func testDetectingMutatesExistingMenuItemInPlace() {
        let controller = StatusItemController()
        let menu = controller.makeMenu(for: .unlocked, detecting: false)
        let detect = menu.items.first {
            $0.title == NSLocalizedString("maclock.menu.detect", comment: "")
        }
        XCTAssertNotNil(detect)
        XCTAssertTrue(detect?.isEnabled ?? false)

        controller.isDetecting = true
        XCTAssertTrue(detect === menu.items.first {
            $0.title == NSLocalizedString("maclock.menu.detect.busy", comment: "")
        })
        XCTAssertEqual(detect?.title, NSLocalizedString("maclock.menu.detect.busy", comment: ""))
        XCTAssertFalse(detect?.isEnabled ?? true)
        XCTAssertFalse(menu.autoenablesItems)

        controller.isDetecting = false
        XCTAssertEqual(detect?.title, NSLocalizedString("maclock.menu.detect", comment: ""))
        XCTAssertTrue(detect?.isEnabled ?? false)
    }

    func testStatusMenuCarriesQuitAndLockKeyEquivalents() {
        let menu = StatusItemController().makeMenu(for: .monitoring)
        let quitItem = menu.items.first { $0.keyEquivalent == "q" }
        XCTAssertNotNil(quitItem, "quit item must advertise ⌘Q")
        XCTAssertEqual(quitItem?.keyEquivalentModifierMask, .command)

        let shortcut = LockShortcutStore.current
        let lockItem = menu.items.first { $0.keyEquivalent == shortcut.keyEquivalent }
        XCTAssertNotNil(lockItem, "lock item must advertise the configured chord")
        XCTAssertEqual(lockItem?.keyEquivalentModifierMask, shortcut.cocoaModifiers)

        let settingsItem = menu.items.first { $0.keyEquivalent == "," }
        XCTAssertNotNil(settingsItem, "settings item must advertise ⌘,")
        XCTAssertEqual(settingsItem?.keyEquivalentModifierMask, .command)
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

    /// A grouped SwiftUI Form is a scroll view underneath, so an imposed height
    /// leaves a visible scroller. Assert the content actually fits.
    func testSettingsWindowFitsWithoutScrolling() {
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
        let window = NSWindow(contentViewController: settings)
        window.layoutIfNeeded()
        settings.view.layoutSubtreeIfNeeded()

        let scrollViews = Self.descendants(of: settings.view).compactMap { $0 as? NSScrollView }
        XCTAssertFalse(scrollViews.isEmpty, "expected the grouped form's scroll view to exist")
        for scrollView in scrollViews {
            let document = scrollView.documentView?.frame.height ?? 0
            let clip = scrollView.contentView.bounds.height
            print("[settings] doc=\(document) clip=\(clip) window=\(window.frame.size)")
            XCTAssertLessThanOrEqual(
                document, clip + 1,
                "settings content overflows its window, so a scroller appears"
            )
        }
    }

    func testCenteredOriginUsesTheGivenVisibleFrame() {
        // A secondary display to the right, with a menu bar / Dock inset.
        let visible = NSRect(x: 1920, y: 25, width: 1440, height: 830)
        let origin = NSWindow.centeredOrigin(for: NSSize(width: 480, height: 485), in: visible)
        XCTAssertEqual(origin.x, 1920 + (1440 - 480) / 2, accuracy: 1)
        XCTAssertEqual(origin.y, 25 + (830 - 485) / 2, accuracy: 1)

        // Window larger than the screen must not wander off the left edge more
        // than symmetry demands.
        let wide = NSWindow.centeredOrigin(for: NSSize(width: 2000, height: 900), in: visible)
        XCTAssertEqual(wide.x, 1920 + (1440 - 2000) / 2, accuracy: 1)
    }

    /// The complaint was a blank Dock tile, so assert the render is actually
    /// opaque where the art belongs and clear outside the rounded tile.
    func testDockIconRendersNonBlankAndMatchesStatusSymbols() throws {
        XCTAssertEqual(StatusItemController.symbolName(for: .shielded), "lock.shield.fill")
        XCTAssertEqual(StatusItemController.symbolName(for: .disarmed), "shield.slash")
        XCTAssertEqual(StatusItemController.symbolName(for: .monitoring), "lock.shield")

        let icon = try XCTUnwrap(DockIcon.image(symbol: StatusItemController.symbolName(for: .monitoring)))
        XCTAssertEqual(icon.size.width, 512, accuracy: 1)
        XCTAssertEqual(icon.size.height, 512, accuracy: 1)

        var rect = NSRect(origin: .zero, size: icon.size)
        let cgImage = try XCTUnwrap(icon.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let centre = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        XCTAssertGreaterThan(centre.alphaComponent, 0.9, "the middle of the icon must not be transparent")

        let tile = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 5)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(tile.redComponent, tile.greenComponent, accuracy: 0.01)
        XCTAssertEqual(tile.greenComponent, tile.blueComponent, accuracy: 0.01)
        XCTAssertLessThan(tile.redComponent, 0.2, "the Dock tile must match the charcoal app palette")

        let corner = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1))
        XCTAssertLessThan(corner.alphaComponent, 0.1, "outside the rounded tile must stay clear")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeSettingsModel() -> SettingsModel {
        SettingsModel(flow: makeOnboardingFlow(), loginItems: LoginItemService(), tap: EventTapController())
    }

    private func makeOnboardingFlow() -> OnboardingFlow {
        let secrets = GateSecretsStore(keychain: FakeKeychain())
        let passwords = PasswordStore(secrets: secrets, clock: FakeClock())
        let gate = SessionGate(
            secrets: secrets,
            overlay: OverlaySpy(),
            tap: TapSpy(),
            presence: PresenceSpy(),
            clock: FakeClock()
        )
        return OnboardingFlow(passwords: passwords, secrets: secrets, gate: gate)
    }

    /// Regression: `NSWindow(contentViewController:)` adopts the SwiftUI size
    /// only on the next layout pass. Centring before that placed a near-zero
    /// frame at the screen centre, and the window grew up and right from there.
    func testSettingsWindowIsCentredOnItsScreenAtInit() throws {
        let screen = try XCTUnwrap(NSScreen.active, "no display available")
        let content = SettingsContentViewController(
            flow: makeOnboardingFlow(),
            loginItems: LoginItemService(),
            tap: EventTapController()
        )
        let controller = SettingsWindowController(content: content)
        let window = try XCTUnwrap(controller.window)

        XCTAssertGreaterThan(window.frame.width, 400, "window must already carry its real width")
        XCTAssertGreaterThan(window.frame.height, 300, "window must already carry its real height")

        let expected = NSWindow.centeredOrigin(for: window.frame.size, in: screen.visibleFrame)
        XCTAssertEqual(window.frame.origin.x, expected.x, accuracy: 2)
        XCTAssertEqual(window.frame.origin.y, expected.y, accuracy: 2)
    }

    /// Regression: the fields are cleared on success, which fires SwiftUI's
    /// onChange and used to wipe the confirmation before it was ever drawn.
    func testSettingsSecureFieldsCommitIntoTheModelBeforeSave() async {
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
        let window = NSWindow(contentViewController: settings)
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: -2800, y: -2800, width: 520, height: 420), display: true)
        window.makeKeyAndOrderFront(nil)
        settings.view.layoutSubtreeIfNeeded()
        pump()
        defer { window.close() }

        let fields = Self.descendants(of: settings.view).compactMap { $0 as? NSSecureTextField }
        XCTAssertGreaterThanOrEqual(fields.count, 2, "new + confirm fields")
        XCTAssertTrue(window.makeFirstResponder(fields[0]))
        pump()
        fields[0].currentEditor()?.insertText("commit-me-now")
        pump()
        XCTAssertTrue(window.makeFirstResponder(fields[1]))
        pump()
        fields[1].currentEditor()?.insertText("commit-me-now")
        pump()

        let model = settings.model
        XCTAssertEqual(model.newPassword, "commit-me-now", "new-password binding lagged the field editor")
        XCTAssertEqual(model.confirmPassword, "commit-me-now", "confirm binding lagged the field editor")
        await model.updatePassword()
        XCTAssertFalse(model.passwordFailed, model.passwordMessage)
        let verified = await passwords.verify("commit-me-now")
        XCTAssertEqual(verified, .accepted)
    }

    func testSuccessMessageSurvivesTheProgrammaticFieldReset() async {
        let model = makeSettingsModel()
        model.newPassword = "abcd"
        model.confirmPassword = "abcd"
        await model.updatePassword()

        XCTAssertFalse(model.passwordFailed)
        XCTAssertFalse(model.passwordMessage.isEmpty, "a successful update must report success")
        XCTAssertEqual(model.newPassword, "")
        XCTAssertEqual(model.confirmPassword, "")

        // Both fields changed, so onChange fires twice after the reset.
        model.noteEdit()
        model.noteEdit()
        XCTAssertFalse(model.passwordMessage.isEmpty, "the reset must not clear the confirmation")
    }

    func testTypingAgainClearsTheMessage() async {
        let model = makeSettingsModel()
        model.newPassword = "ab"
        model.confirmPassword = "ab"
        await model.updatePassword()
        XCTAssertTrue(model.passwordFailed, "two characters is below the minimum")
        XCTAssertFalse(model.passwordMessage.isEmpty)

        model.newPassword = "abcd"
        model.noteEdit()
        XCTAssertTrue(model.passwordMessage.isEmpty, "a real edit clears the previous message")
    }
}
