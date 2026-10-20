import Foundation

struct RemoteProcessSnapshot: Equatable {
    var name: String
    var path: String = ""
}

struct RemoteHIDSnapshot: Equatable {
    var product: String
    var manufacturer: String
    var creator: String
    var transport: String
}

struct RemoteWindowSnapshot: Equatable {
    var owner: String
    var title: String
}

enum RemoteSessionReason: Equatable {
    case sessionProcess(String)
    case virtualHID(String)
    case controlledWindow(String)
    case injectedProcess(String)
}

/// Classifies inbound remote-control sessions. Idle agents (UURemoteServer
/// sitting in the background, ToDesk waiting for a call) must not match —
/// only a live session, a virtual HID owned by a remote helper, a
/// "being controlled" window, or injected events from those helpers.
enum RemoteControlCatalog {
    /// Processes that exist only while someone is actively controlling this Mac.
    static let sessionProcessNames: Set<String> = [
        "todesksession",
        "teamviewerdesktop",
        "screensharingagent",
        "applevncserver",
        "anydeskservice",
    ]

    /// Substrings of process / HID creator / product names used by inbound
    /// remote-control injectors. Short tokens like "remote" are intentionally
    /// absent so ordinary apps are not treated as a session.
    static let injectorTokens: [String] = [
        "uuremoteserver",
        "uuremoteservice",
        "uuremote",
        "todesk",
        "teamviewer",
        "anydesk",
        "rustdesk",
        "sunlogin",
        "orayremote",
        "oray",
        "splashtop",
        "screensharing",
        "applevnc",
        "parsec",
        "chromeremotedesktop",
        "aeoflight",
    ]

    static let hidExcludeTokens: [String] = [
        "karabiner",
        "pqrs",
        "keyboard backlight",
        "corebrightness",
    ]

    static let controlledWindowTitles: [String] = [
        "本机被控中",
        "被控中",
        "本机正在被他人远程控制",
        "正在被",
        "being controlled",
        "controlled by",
    ]

    static func reason(
        processes: [RemoteProcessSnapshot],
        hid: [RemoteHIDSnapshot],
        windows: [RemoteWindowSnapshot],
        injectedName: String? = nil
    ) -> RemoteSessionReason? {
        for process in processes {
            if isSessionProcess(name: process.name) {
                return .sessionProcess(process.name)
            }
        }
        for device in hid {
            if let label = virtualHIDLabel(device) {
                return .virtualHID(label)
            }
        }
        for window in windows {
            if isControlledWindow(owner: window.owner, title: window.title) {
                let label = window.title.isEmpty ? window.owner : window.title
                return .controlledWindow(label)
            }
        }
        if let injectedName, isInjectorProcess(name: injectedName, path: "") {
            return .injectedProcess(injectedName)
        }
        return nil
    }

    static func isSessionProcess(name: String) -> Bool {
        sessionProcessNames.contains(normalize(name))
    }

    static func isInjectorProcess(name: String, path: String) -> Bool {
        containsInjectorToken("\(name) \(path)")
    }

    static func isControlledWindow(owner: String, title: String) -> Bool {
        guard containsInjectorToken(owner) || containsInjectorToken(title) else { return false }
        let lowered = title.lowercased()
        return controlledWindowTitles.contains { lowered.contains($0.lowercased()) }
    }

    static func virtualHIDLabel(_ device: RemoteHIDSnapshot) -> String? {
        let blob = "\(device.product) \(device.manufacturer) \(device.creator) \(device.transport)"
        if containsAnyToken(blob, hidExcludeTokens) { return nil }
        guard containsInjectorToken(blob) else { return nil }
        if !device.product.isEmpty { return device.product }
        if !device.creator.isEmpty { return device.creator }
        return device.manufacturer
    }

    static func containsInjectorToken(_ text: String) -> Bool {
        containsAnyToken(text, injectorTokens)
    }

    private static func containsAnyToken(_ text: String, _ tokens: [String]) -> Bool {
        let haystack = normalize(text)
        return tokens.contains { haystack.contains($0) }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum RemoteShieldPolicy {
    static let defaultsKey = "skipShieldForRemoteSession"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
