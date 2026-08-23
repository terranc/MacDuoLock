import Foundation

enum ContinuityDeviceMatcher {
    static func eligible(_ device: CaptureDeviceSnapshot, matcher: PresenceMatcher) -> Bool {
        isEligible(device, matcher: matcher)
    }
}

enum PresenceMatcherStore {
    static let uniqueIDKey = "app.maclock.matcher.uniqueID"
    static let nameKey = "app.maclock.matcher.localizedName"

    static func load() -> PresenceMatcher {
        let defaults = UserDefaults.standard
        return PresenceMatcher(
            preferredUniqueID: defaults.string(forKey: uniqueIDKey),
            preferredLocalizedName: defaults.string(forKey: nameKey),
            allowIPad: false,
            allowDeskView: false
        )
    }

    static func save(_ matcher: PresenceMatcher) {
        let defaults = UserDefaults.standard
        defaults.set(matcher.preferredUniqueID, forKey: uniqueIDKey)
        defaults.set(matcher.preferredLocalizedName, forKey: nameKey)
    }
}

enum PresenceDiagnostics {
    static func report(requestIfNeeded: Bool = false) async -> String {
        var lines: [String] = []
        let status = Permissions.cameraStatus()
        lines.append("camera TCC=\(status.rawValue) authorized=\(Permissions.cameraAuthorized())")
        if requestIfNeeded && status == .notDetermined {
            let granted = await Permissions.requestCamera()
            lines.append("requestAccess granted=\(granted)")
        }
        let catalog = AVCaptureDeviceCatalog()
        catalog.start()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let devices = catalog.currentDevices
        catalog.stop()
        if devices.isEmpty {
            lines.append("continuity devices: none")
        }
        for device in devices {
            lines.append(
                "device continuity=\(device.isContinuityCamera) desk=\(device.isDeskView) name=\(device.localizedName) id=\(device.uniqueID)"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func firstBindableDevice() async -> CaptureDeviceSnapshot? {
        if Permissions.cameraStatus() == .notDetermined {
            _ = await Permissions.requestCamera()
        }
        guard Permissions.cameraAuthorized() else { return nil }
        let catalog = AVCaptureDeviceCatalog()
        catalog.start()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let match = catalog.currentDevices.first { $0.isContinuityCamera && !$0.isDeskView }
        catalog.stop()
        return match
    }
}
