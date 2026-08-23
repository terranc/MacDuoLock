import CoreGraphics
import Foundation

/// Extensible deny table. Gestures, hot corners, Siri, Globe, Dictation are out of scope.
enum EscapeChord {
    /// ANSI grave (50) and ISO extra grave (10).
    static let backdoorKeyCodes: Set<Int64> = [50, 10]

    static func isBackdoorUnlock(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let present = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return backdoorKeyCodes.contains(keyCode) && present == chord
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
