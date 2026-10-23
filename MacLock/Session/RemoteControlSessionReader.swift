import AppKit
import ApplicationServices

struct RemoteControlReadResult {
    var windows: [RemoteControlWindowSnapshot]
    var isComplete: Bool
}

enum RemoteControlSessionReader {
    private enum Elements {
        case found([AXUIElement], isComplete: Bool)
        case missing
        case failed
    }

    private static let maximumNodes = 768
    private static let maximumDepth = 24
    private static let attributeNames = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXHiddenAttribute, kAXMinimizedAttribute, "AXVisible",
    ]

    static func windows() -> [RemoteControlWindowSnapshot] {
        read().windows
    }

    static func read() -> RemoteControlReadResult {
        guard AXIsProcessTrusted() else { return RemoteControlReadResult(windows: [], isComplete: false) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var result = RemoteControlReadResult(windows: [], isComplete: true)
        let applications = NSWorkspace.shared.runningApplications.filter {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return RemoteControlCatalog.application(for: bundleIdentifier) != nil
        }

        for app in applications {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                result.isComplete = false
                break
            }
            guard !app.isTerminated, !app.isHidden,
                  let bundleIdentifier = app.bundleIdentifier else {
                result.isComplete = false
                continue
            }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            guard case .found(let windows, let windowsComplete) = elements(
                of: application, attribute: kAXWindowsAttribute, limit: 16, deadline: deadline
            ), !windows.isEmpty else {
                result.isComplete = false
                continue
            }
            result.isComplete = result.isComplete && windowsComplete
            for window in windows {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    result.isComplete = false
                    break
                }
                var windowComplete = true
                let snapshot = snapshot(of: window, bundleIdentifier: bundleIdentifier,
                                        processIdentifier: app.processIdentifier,
                                        deadline: deadline, isComplete: &windowComplete)
                result.isComplete = result.isComplete && windowComplete
                guard let snapshot else { continue }
                result.windows.append(snapshot)
                if RemoteControlCatalog.activeApplication(in: [snapshot]) != nil {
                    result.isComplete = false
                    return result
                }
            }
        }
        return result
    }

    private static func snapshot(of window: AXUIElement, bundleIdentifier: String,
                                 processIdentifier: Int32, deadline: TimeInterval,
                                 isComplete: inout Bool) -> RemoteControlWindowSnapshot? {
        var result = RemoteControlWindowSnapshot(bundleIdentifier: bundleIdentifier, texts: [], enabledButtons: [])
        result.processIdentifier = processIdentifier
        var pending = [(window, 0)]
        var visited = 0
        let requiresCompleteWindow = bundleIdentifier == "com.carriez.rustdesk"

        while visited < maximumNodes, ProcessInfo.processInfo.systemUptime < deadline,
              let (element, depth) = pending.popLast() {
            visited += 1
            guard let values = attributes(of: element, deadline: deadline) else {
                isComplete = false
                if requiresCompleteWindow { return nil }
                continue
            }
            guard values[kAXHiddenAttribute] as? Bool != true,
                  values[kAXMinimizedAttribute] as? Bool != true,
                  values["AXVisible"] as? Bool != false,
                  let role = values[kAXRoleAttribute] as? String else {
                isComplete = false
                if requiresCompleteWindow { return nil }
                continue
            }
            guard !(depth > 0 && role == kAXWindowRole),
                  role != kAXMenuRole, role != kAXMenuBarRole, role != kAXMenuItemRole else { continue }

            var texts = strings([values[kAXTitleAttribute], values[kAXDescriptionAttribute]])
            if role == kAXStaticTextRole { texts += strings([values[kAXValueAttribute]]) }
            var buttons: [String] = []
            if role == kAXButtonRole, values[kAXEnabledAttribute] as? Bool == true {
                buttons = strings([
                    values[kAXTitleAttribute], values[kAXDescriptionAttribute], values[kAXValueAttribute],
                ])
            }
            result.texts += texts
            result.enabledButtons += buttons
            // Check new evidence against this window without repeatedly rescanning all its text.
            var evidence = result
            evidence.enabledButtons = buttons
            if !requiresCompleteWindow, !buttons.isEmpty,
               RemoteControlCatalog.activeApplication(in: [evidence]) != nil {
                isComplete = false
                return result
            }
            evidence.texts = texts
            evidence.enabledButtons = result.enabledButtons
            if !requiresCompleteWindow, !texts.isEmpty, !result.enabledButtons.isEmpty,
               RemoteControlCatalog.activeApplication(in: [evidence]) != nil {
                isComplete = false
                return result
            }

            let remaining = maximumNodes - visited - pending.count
            guard depth < maximumDepth, remaining > 0 else {
                isComplete = false
                if requiresCompleteWindow { return nil }
                continue
            }
            var children = elements(of: element, attribute: kAXVisibleChildrenAttribute,
                                    limit: remaining, deadline: deadline)
            if case .failed = children {
                isComplete = false
                if requiresCompleteWindow { return nil }
            }
            if case .found = children {
                // Keep the visible subtree, even when it is empty.
            } else {
                children = elements(of: element, attribute: kAXChildrenAttribute,
                                    limit: remaining, deadline: deadline)
            }
            switch children {
            case .found(let elements, let childrenComplete):
                if !childrenComplete {
                    isComplete = false
                    if requiresCompleteWindow { return nil }
                }
                pending += elements.reversed().map { ($0, depth + 1) }
            case .missing: break
            case .failed:
                isComplete = false
                if requiresCompleteWindow { return nil }
            }
        }
        // RustDesk also manages non-desktop sessions. Do not accept a partial
        // window before all session-mode labels have been checked.
        if !pending.isEmpty || ProcessInfo.processInfo.systemUptime >= deadline { isComplete = false }
        if requiresCompleteWindow, !isComplete { return nil }
        return result.texts.isEmpty && result.enabledButtons.isEmpty ? nil : result
    }

    private static func attributes(of element: AXUIElement, deadline: TimeInterval) -> [String: Any]? {
        guard prepare(element, deadline: deadline) else { return nil }
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributeNames as CFArray,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
              let values = result as? [Any], values.count == attributeNames.count else { return nil }
        for value in values where CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
            let value = value as! AXValue
            guard AXValueGetType(value) == .axError else { continue }
            var error = AXError.success
            guard AXValueGetValue(value, .axError, &error),
                  error == .attributeUnsupported || error == .noValue else { return nil }
        }
        return Dictionary(uniqueKeysWithValues: zip(attributeNames, values))
    }

    private static func elements(of element: AXUIElement, attribute: String, limit: Int,
                                 deadline: TimeInterval) -> Elements {
        guard prepare(element, deadline: deadline) else { return .failed }
        var result: CFArray?
        let error = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, limit + 1, &result)
        if error == .attributeUnsupported || error == .noValue { return .missing }
        guard error == .success, let elements = result as? [AXUIElement] else { return .failed }
        return .found(Array(elements.prefix(limit)), isComplete: elements.count <= limit)
    }

    private static func prepare(_ element: AXUIElement, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining))) == .success
    }

    private static func strings(_ values: [Any?]) -> [String] {
        values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
