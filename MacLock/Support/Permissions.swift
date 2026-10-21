import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum AppPermission: CaseIterable, Identifiable {
    case accessibility
    case camera

    var id: Self { self }

    var settingsTitle: String {
        let key: String
        switch self {
        case .accessibility:
            key = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                ? "maclock.setup.accessibility.title.current" : "maclock.setup.accessibility.title"
        case .camera:
            key = "maclock.setup.camera.title"
        }
        return NSLocalizedString(key, comment: "")
    }
}

enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

enum Permissions {
    static func status(for permission: AppPermission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            return accessibilityTrusted() ? .authorized : .denied
        case .camera:
            switch cameraStatus() {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            case .authorized: return .authorized
            @unknown default: return .denied
            }
        }
    }

    static func request(_ permission: AppPermission) async {
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .camera:
            if cameraStatus() == .notDetermined {
                _ = await requestCamera()
            }
        }
    }

    static func settingsURL(for permission: AppPermission) -> URL {
        let pane: String
        switch permission {
        case .accessibility: pane = "Privacy_Accessibility"
        case .camera: pane = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    @MainActor
    static func openSettings(for permission: AppPermission) -> Bool {
        NSWorkspace.shared.open(settingsURL(for: permission))
    }

    static func cameraAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func cameraStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
