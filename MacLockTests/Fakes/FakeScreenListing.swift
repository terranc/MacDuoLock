import CoreGraphics
import Foundation
@testable import MacLock

struct FakeScreenListing: ScreenListing {
    var screens: [ScreenDescriptor]
}

@MainActor
final class OverlaySpy: OverlayCommanding {
    var isPresented = false
    var lastReason: OverlayReason?
    var dismissSyncCount = 0
    var rebuildCount = 0
    var log: [String] = []

    func apply(_ command: OverlayCommand) {
        switch command {
        case .stay:
            log.append("stay")
        case .present(let reason):
            isPresented = true
            lastReason = reason
            log.append("present:\(reason)")
        case .dismissSync:
            dismissSync()
        }
    }

    func dismissSync() {
        dismissSyncCount += 1
        isPresented = false
        lastReason = nil
        log.append("dismissSync")
    }

    func rebuild() {
        rebuildCount += 1
        log.append("rebuild")
    }
}

final class TapSpy: TapCommanding {
    var startCount = 0
    var stopCount = 0
    func startTap() { startCount += 1 }
    func stopTap() { stopCount += 1 }
}

final class PresenceSpy: PresenceControlling {
    var started: [UInt64] = []
    var stopCount = 0
    func start(generation: UInt64) { started.append(generation) }
    func stop() { stopCount += 1 }
}
