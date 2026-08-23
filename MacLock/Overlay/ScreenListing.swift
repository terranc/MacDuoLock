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
