import AppKit
import CoreGraphics
import Foundation

struct ScreenDescriptor: Equatable {
    var displayID: CGDirectDisplayID
    var frame: CGRect
    var isPrimary: Bool
}

protocol ScreenListing {
    var screens: [ScreenDescriptor] { get }
}

struct NSScreenListing: ScreenListing {
    var screens: [ScreenDescriptor] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.map { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
            return ScreenDescriptor(displayID: id, frame: screen.frame, isPrimary: id == mainID)
        }
    }
}

extension NSScreen {
    /// The screen the user is actually working on. `NSScreen.main` tracks the
    /// key window, which is unreliable for an accessory app that is only just
    /// being activated — the pointer is where the user clicked the menu bar.
    static var active: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

extension NSWindow {
    /// `NSWindow.center()` centers on the screen holding the menu bar, not on
    /// the screen the user is looking at.
    func centerOnActiveScreen() {
        guard let screen = NSScreen.active else { return }
        setFrameOrigin(Self.centeredOrigin(for: frame.size, in: screen.visibleFrame))
    }

    /// Pure geometry, split out so it can be asserted without real displays.
    static func centeredOrigin(for size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: (visibleFrame.midY - size.height / 2).rounded()
        )
    }
}
