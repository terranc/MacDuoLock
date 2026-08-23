import ApplicationServices
import Foundation

enum EventTapError: Error {
    case notTrusted
    case createFailed
}

final class EventTapController: TapCommanding {
    var onBackdoor: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func startTap() {
        try? start()
    }

    func stopTap() {
        stop()
    }

    func start() throws {
        guard AXIsProcessTrusted() else { throw EventTapError.notTrusted }
        let mask =
            (UInt64(1) << CGEventType.keyDown.rawValue)
            | (UInt64(1) << CGEventType.keyUp.rawValue)
            | (UInt64(1) << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if type == .tapDisabledByTimeout {
                    return Unmanaged.passUnretained(event)
                }
                if type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if type == .keyDown, EscapeChord.isBackdoorUnlock(keyCode: code, flags: event.flags) {
                    if let refcon {
                        let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
                        DispatchQueue.main.async { controller.onBackdoor?() }
                    }
                    return nil
                }
                if type == .keyDown || type == .keyUp || type == .flagsChanged {
                    if EscapeChord.shouldSwallow(keyCode: code, flags: event.flags) {
                        return nil
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw EventTapError.createFailed
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }
}
