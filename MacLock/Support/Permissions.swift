import AVFoundation
import ApplicationServices
import Foundation

enum Permissions {
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
