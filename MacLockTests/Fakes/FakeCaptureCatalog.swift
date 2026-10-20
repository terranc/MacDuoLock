import Foundation
@testable import MacLock

final class FakeCaptureCatalog: CaptureDeviceCataloging {
    var currentDevices: [CaptureDeviceSnapshot] = []
    private let changes = RestartableSnapshotStream()
    var startCount = 0
    var stopCount = 0

    var deviceChanges: AsyncStream<[CaptureDeviceSnapshot]> { changes.stream }

    func start() {
        startCount += 1
        changes.open()
    }

    func stop() {
        stopCount += 1
        changes.close()
    }

    func emit(_ devices: [CaptureDeviceSnapshot]) {
        currentDevices = devices
        changes.yield(devices)
    }
}
