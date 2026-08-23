import AVFoundation
import Foundation

@MainActor
final class PresenceMonitor: PresenceControlling {
    let catalog: CaptureDeviceCataloging
    var matcher: () -> PresenceMatcher
    var isCameraAuthorized: () -> Bool
    var onMatched: ((PresenceEvidence) -> Void)?

    private var generation: UInt64 = 0
    private var startedAt: Date?
    private var changeTask: Task<Void, Never>?
    private var running = false

    init(
        catalog: CaptureDeviceCataloging,
        matcher: @escaping () -> PresenceMatcher = { .v1Default },
        isCameraAuthorized: @escaping () -> Bool = { false }
    ) {
        self.catalog = catalog
        self.matcher = matcher
        self.isCameraAuthorized = isCameraAuthorized
    }

    func start(generation: UInt64) {
        stop()
        self.generation = generation
        startedAt = Date()
        running = true
        guard isCameraAuthorized() else { return }
        catalog.start()
        evaluate(catalog.currentDevices)
        let gen = generation
        changeTask = Task { [weak self] in
            guard let self else { return }
            for await devices in self.catalog.deviceChanges {
                if Task.isCancelled { break }
                await MainActor.run {
                    guard self.running, self.generation == gen else { return }
                    self.evaluate(devices)
                }
            }
        }
    }

    func stop() {
        running = false
        changeTask?.cancel()
        changeTask = nil
        catalog.stop()
    }

    private func evaluate(_ devices: [CaptureDeviceSnapshot]) {
        guard running else { return }
        let m = matcher()
        let continuity = devices.filter(\.isContinuityCamera).count
        let elapsed = Int((Date().timeIntervalSince(startedAt ?? Date())) * 1000)
        let summary = devices.map {
            "\($0.localizedName) cont=\($0.isContinuityCamera) conn=\($0.isConnected) sus=\($0.isSuspended)"
        }.joined(separator: "; ")
        MacLockLog.file("presence eval gen=\(generation) elapsedMs=\(elapsed) [\(summary)]")
        for device in devices {
            if let reason = matchReason(for: device, matcher: m) {
                let evidence = PresenceEvidence(
                    generation: generation,
                    matchReason: reason,
                    uniqueIDFingerprint: uniqueIDFingerprint(device.uniqueID),
                    truncatedLocalizedName: truncatedLocalizedName(device.localizedName),
                    continuityCount: continuity,
                    elapsedMs: elapsed
                )
                onMatched?(evidence)
                return
            }
        }
    }
}
