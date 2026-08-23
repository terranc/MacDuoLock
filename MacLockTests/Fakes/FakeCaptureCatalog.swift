import Foundation
@testable import MacLock

final class FakeCaptureCatalog: CaptureDeviceCataloging {
    var currentDevices: [CaptureDeviceSnapshot] = []
    private var listeners: [( [CaptureDeviceSnapshot]) -> Void] = []
    var startCount = 0
    var stopCount = 0

    var deviceChanges: AsyncStream<[CaptureDeviceSnapshot]> {
        AsyncStream { [weak self] cont in
            self?.listeners.append { cont.yield($0) }
        }
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func emit(_ devices: [CaptureDeviceSnapshot]) {
        currentDevices = devices
        listeners.forEach { $0(devices) }
    }
}
