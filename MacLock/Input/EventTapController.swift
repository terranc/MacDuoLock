import AppKit
import ApplicationServices
import Carbon
import Foundation

enum EventTapError: Error {
    case notTrusted
    case createFailed
}

final class EventTapController: TapCommanding {
    var onBackdoor: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localChordMonitor: Any?
    private var globalChordMonitor: Any?
    private var carbonHandler: EventHandlerRef?
    private var carbonHotKeys: [EventHotKeyRef] = []
    private var restartWork: DispatchWorkItem?
    /// When false the tap only intercepts the toggle chord (desktop / wait-T).
    private var swallowEscapes = false

    func startTap() {
        swallowEscapes = true
        scheduleTapRestart()
    }

    func stopTap() {
        swallowEscapes = false
        scheduleTapRestart()
    }

    /// Always-on listeners so the chord works at the desktop after the overlay goes away.
    func installPersistentChordWatch() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            MacLockLog.file("ax prompt trusted=\(AXIsProcessTrusted())")
        }
        registerCarbonChord()
        if localChordMonitor == nil {
            localChordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if self?.noteChord(event, via: "local") == true { return nil }
                return event
            }
        }
        if globalChordMonitor == nil {
            globalChordMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.noteChord(event, via: "global")
            }
        }
        scheduleTapRestart()
    }

    private func fireChord(via source: String) {
        MacLockLog.file("chord heard via \(source)")
        DispatchQueue.main.async { [weak self] in self?.onBackdoor?() }
    }

    private func noteChord(_ event: NSEvent, via source: String) -> Bool {
        if event.isARepeat { return false }
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        guard EscapeChord.isBackdoorUnlock(keyCode: Int64(event.keyCode), flags: flags) else { return false }
        fireChord(via: source)
        return true
    }

    private func scheduleTapRestart() {
        restartWork?.cancel()
        let swallow = swallowEscapes
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stop()
            do {
                try self.start()
                MacLockLog.file("tap running swallow=\(swallow) ax=\(AXIsProcessTrusted())")
            } catch {
                MacLockLog.file("tap start failed ax=\(AXIsProcessTrusted()) err=\(error)")
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if type == .keyDown, !isRepeat, EscapeChord.isBackdoorUnlock(keyCode: code, flags: event.flags) {
                    controller.fireChord(via: "tap")
                    return nil
                }
                if controller.swallowEscapes,
                   type == .keyDown || type == .keyUp || type == .flagsChanged,
                   EscapeChord.shouldSwallow(keyCode: code, flags: event.flags) {
                    return nil
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

    /// Re-arm every listener against the currently stored shortcut. Called after
    /// the user records a new chord in Settings.
    func reloadShortcut() {
        registerHotKeys()
        scheduleTapRestart()
    }

    private func registerCarbonChord() {
        installCarbonHandlerIfNeeded()
        registerHotKeys()
    }

    private func installCarbonHandlerIfNeeded() {
        guard carbonHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let install = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<EventTapController>.fromOpaque(userData).takeUnretainedValue()
                controller.fireChord(via: "carbon")
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonHandler
        )
        MacLockLog.file("carbon handler install=\(install)")
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        let shortcut = LockShortcutStore.current
        let modifiers = carbonModifiers(shortcut.flags)
        for (index, code) in shortcut.keyCodes.enumerated() {
            let hotKeyID = EventHotKeyID(signature: OSType(0x4D4C4348), id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(code), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                carbonHotKeys.append(ref)
            }
            MacLockLog.file("carbon hotkey code=\(code) mods=\(modifiers) status=\(status)")
        }
    }

    private func unregisterHotKeys() {
        for ref in carbonHotKeys {
            UnregisterEventHotKey(ref)
        }
        carbonHotKeys.removeAll()
    }

    private func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        return result
    }
}
