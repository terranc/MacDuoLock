import XCTest
@testable import MacLock

@MainActor
final class PresenceMonitorTests: XCTestCase {
    func testStartWithMatchingDevicesFiresWithoutLaterChange() {
        let catalog = FakeCaptureCatalog()
        catalog.currentDevices = [
            CaptureDeviceSnapshot(
                uniqueID: "uid-1",
                localizedName: "厨房间",
                isContinuityCamera: true,
                isDeskView: false,
                deviceTypeRaw: "continuity"
            ),
        ]
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "uid-1"
        let monitor = PresenceMonitor(
            catalog: catalog,
            matcher: { matcher },
            isCameraAuthorized: { true }
        )
        var evidence: PresenceEvidence?
        monitor.onMatched = { evidence = $0 }
        monitor.start(generation: 7)
        XCTAssertEqual(catalog.startCount, 1)
        XCTAssertEqual(evidence?.generation, 7)
        XCTAssertEqual(evidence?.matchReason, .uniqueID)
    }

    func testStaleGenerationChangesAreDropped() async {
        let catalog = FakeCaptureCatalog()
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "uid-1"
        let monitor = PresenceMonitor(
            catalog: catalog,
            matcher: { matcher },
            isCameraAuthorized: { true }
        )
        var hits: [UInt64] = []
        monitor.onMatched = { hits.append($0.generation) }
        monitor.start(generation: 1)
        monitor.stop()
        hits.removeAll()
        monitor.start(generation: 2)
        for _ in 0..<20 { await Task.yield() }
        catalog.emit([
            CaptureDeviceSnapshot(
                uniqueID: "uid-1",
                localizedName: "x",
                isContinuityCamera: true,
                isDeskView: false,
                deviceTypeRaw: "continuity"
            ),
        ])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(hits.contains(1))
        XCTAssertEqual(hits.last, 2)
    }

    func testUnauthorizedDoesNotEnumerate() {
        let catalog = FakeCaptureCatalog()
        let monitor = PresenceMonitor(
            catalog: catalog,
            matcher: { .v1Default },
            isCameraAuthorized: { false }
        )
        monitor.start(generation: 1)
        XCTAssertEqual(catalog.startCount, 0)
    }
}
