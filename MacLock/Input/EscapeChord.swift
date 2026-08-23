import AppKit
import CoreGraphics
import Foundation

/// User-configurable chord that toggles the shield.
struct LockShortcut: Codable, Equatable {
    /// Usually one code. The factory default carries both ANSI grave (50) and
    /// ISO extra grave (10) so the same physical key works on either layout.
    var keyCodes: [Int64]
    /// `CGEventFlags` raw value, restricted to control/option/shift/command.
    var modifiers: UInt64
    /// Character handed to `NSMenuItem.keyEquivalent`.
    var keyEquivalent: String
    /// Human-readable key name for the recorder and the menu, e.g. "`" or "F5".
    var label: String

    /// A chord with none of these would fire during ordinary typing.
    static let requiredModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    static let trackedModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    static let `default` = LockShortcut(
        keyCodes: [50, 10],
        modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue,
        keyEquivalent: "`",
        label: "`"
    )

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    /// Canonical macOS ordering: ⌃⌥⇧⌘.
    var displayString: String {
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        return text + label
    }

    func matches(keyCode: Int64, flags eventFlags: CGEventFlags) -> Bool {
        keyCodes.contains(keyCode) && eventFlags.intersection(Self.trackedModifiers) == flags
    }

    /// Nil when the keystroke carries no ⌃/⌥/⌘, or when the key has no name we
    /// can render — either would produce a chord the user cannot see or trust.
    static func from(_ event: NSEvent) -> LockShortcut? {
        var raw: CGEventFlags = []
        if event.modifierFlags.contains(.control) { raw.insert(.maskControl) }
        if event.modifierFlags.contains(.option) { raw.insert(.maskAlternate) }
        if event.modifierFlags.contains(.shift) { raw.insert(.maskShift) }
        if event.modifierFlags.contains(.command) { raw.insert(.maskCommand) }
        guard !raw.intersection(requiredModifiers).isEmpty else { return nil }
        let keyCode = Int64(event.keyCode)
        guard let (equivalent, label) = names(for: keyCode, event: event) else { return nil }
        return LockShortcut(
            keyCodes: [keyCode],
            modifiers: raw.rawValue,
            keyEquivalent: equivalent,
            label: label
        )
    }

    private static func names(for keyCode: Int64, event: NSEvent) -> (String, String)? {
        if let special = specialKey(keyCode) { return special }
        let base = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard let scalar = base.unicodeScalars.first, scalar.value > 0x20, scalar.value != 0x7F else {
            return nil
        }
        return (String(scalar), String(scalar).uppercased())
    }

    /// Symbols rather than words so the label needs no translation.
    private static func specialKey(_ keyCode: Int64) -> (String, String)? {
        func fn(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }
        switch keyCode {
        case 36: return ("\r", "↩")
        case 48: return ("\t", "⇥")
        case 49: return (" ", "␣")
        case 51: return ("\u{8}", "⌫")
        case 53: return ("\u{1b}", "⎋")
        case 123: return (fn(NSLeftArrowFunctionKey), "←")
        case 124: return (fn(NSRightArrowFunctionKey), "→")
        case 125: return (fn(NSDownArrowFunctionKey), "↓")
        case 126: return (fn(NSUpArrowFunctionKey), "↑")
        case 122: return (fn(NSF1FunctionKey), "F1")
        case 120: return (fn(NSF2FunctionKey), "F2")
        case 99: return (fn(NSF3FunctionKey), "F3")
        case 118: return (fn(NSF4FunctionKey), "F4")
        case 96: return (fn(NSF5FunctionKey), "F5")
        case 97: return (fn(NSF6FunctionKey), "F6")
        case 98: return (fn(NSF7FunctionKey), "F7")
        case 100: return (fn(NSF8FunctionKey), "F8")
        case 101: return (fn(NSF9FunctionKey), "F9")
        case 109: return (fn(NSF10FunctionKey), "F10")
        case 103: return (fn(NSF11FunctionKey), "F11")
        case 111: return (fn(NSF12FunctionKey), "F12")
        default: return nil
        }
    }
}

enum LockShortcutStore {
    private static let defaultsKey = "app.maclock.lockShortcut"
    /// Cached: the CGEvent tap callback consults this on every key down, and it
    /// runs off the main thread. Writes only happen from the settings UI.
    private static var cached = loadFromDefaults()

    static var current: LockShortcut { cached }

    static func save(_ shortcut: LockShortcut) {
        cached = shortcut
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func resetToDefault() {
        cached = .default
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func loadFromDefaults() -> LockShortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(LockShortcut.self, from: data) else {
            return .default
        }
        return shortcut
    }
}

/// Extensible deny table. Gestures, hot corners, Siri, Globe, Dictation are out of scope.
enum EscapeChord {
    static var backdoorKeyCodes: Set<Int64> { Set(LockShortcutStore.current.keyCodes) }

    /// The configured toggle chord. Unlocks when shielded, locks at the desktop.
    static func isBackdoorUnlock(keyCode: Int64, flags: CGEventFlags) -> Bool {
        LockShortcutStore.current.matches(keyCode: keyCode, flags: flags)
    }

    static func shouldSwallow(keyCode: Int64, flags: CGEventFlags) -> Bool {
        if isBackdoorUnlock(keyCode: keyCode, flags: flags) { return false }
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let opt = flags.contains(.maskAlternate)
        let ctrl = flags.contains(.maskControl)

        // Allow Control+Command+Q (lock screen).
        if cmd && ctrl && !opt && keyCode == 12 { return false }
        // Allow Control+Space / Control+Option+Space (IME).
        if ctrl && !cmd && keyCode == 49 { return false }
        // Allow Command+V paste into password.
        if cmd && !shift && !opt && !ctrl && keyCode == 9 { return false }

        if cmd && keyCode == 48 { return true } // Tab / Shift-Tab app switcher
        if cmd && opt && keyCode == 53 { return true } // Force Quit
        if cmd && shift && (keyCode == 20 || keyCode == 21 || keyCode == 23) { return true } // 3/4/5 screenshots
        if cmd && (keyCode == 4 || keyCode == 13 || keyCode == 46) { return true } // H / W / M
        if cmd && opt && keyCode == 4 { return true } // Option-H
        if cmd && keyCode == 12 { return true } // Q
        if cmd && opt && keyCode == 2 { return true } // Option-D Dock
        if ctrl && cmd && keyCode == 3 { return true } // Control-Command-F
        if cmd && keyCode == 50 { return true } // `
        if cmd && keyCode == 49 { return true } // Spotlight (Cmd-Space)
        if ctrl && (keyCode == 126 || keyCode == 125) { return true } // Mission Control arrows
        if keyCode == 160 { return true } // F3 Mission Control
        return false
    }
}
