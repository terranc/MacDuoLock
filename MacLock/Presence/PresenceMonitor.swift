import Foundation

/// Start, notification stream, and poll share generation/didMatch; splitting
/// them would hide the "one scan window" contract.
@MainActor
final class PresenceMonitor: PresenceControlling {
    let catalog: CaptureDeviceCataloging
    var matcher: () -> PresenceMatcher
    var isCameraAuthorized: () -> Bool
    var onMatched: ((PresenceEvidence) -> Void)?
    /// Continuity Camera often joins DiscoverySession after unlock without a
    /// connect notification. Re-read currentDevices on this interval.
    var pollInterval: TimeInterval = 0.3

    private var generation: UInt64 = 0
    private var startedAt: Date?
    private var changeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var running = false
    private var didMatch = false
    private var lastLoggedSummary: String?

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
        didMatch = false
        lastLoggedSummary = nil
        guard isCameraAuthorized() else { return }
        catalog.start()
        evaluate(catalog.currentDevices)
        guard running, !didMatch else { return }
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
        startPolling(generation: gen)
    }

    func stop() {
        running = false
        changeTask?.cancel()
        changeTask = nil
        pollTask?.cancel()
        pollTask = nil
        catalog.stop()
    }

    private func startPolling(generation gen: UInt64) {
        let interval = pollInterval
        guard interval > 0 else { return }
        pollTask = Task { [weak self] in
            let ns = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { break }
                await MainActor.run {
                    guard let self, self.running, self.generation == gen, !self.didMatch else { return }
                    self.evaluate(self.catalog.currentDevices)
                }
            }
        }
    }

    private func evaluate(_ devices: [CaptureDeviceSnapshot]) {
        guard running, !didMatch else { return }
        let m = matcher()
        let continuity = devices.filter(\.isContinuityCamera).count
        let elapsed = Int((Date().timeIntervalSince(startedAt ?? Date())) * 1000)
        let summary = devices.map {
            "\($0.localizedName) cont=\($0.isContinuityCamera) conn=\($0.isConnected) sus=\($0.isSuspended)"
        }.joined(separator: "; ")
        if summary != lastLoggedSummary {
            lastLoggedSummary = summary
            MacLockLog.file("presence eval gen=\(generation) elapsedMs=\(elapsed) [\(summary)]")
        }
        for device in devices {
            if let reason = matchReason(for: device, matcher: m) {
                didMatch = true
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
