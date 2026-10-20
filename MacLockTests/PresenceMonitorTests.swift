import XCTest
@testable import MacLock

@MainActor
final class PresenceMonitorTests: XCTestCase {
    private func phone(id: String = "uid-1", name: String = "“terranc”的相机") -> CaptureDeviceSnapshot {
        CaptureDeviceSnapshot(
            uniqueID: id,
            localizedName: name,
            isContinuityCamera: true,
            isDeskView: false,
            deviceTypeRaw: "continuity"
        )
    }

    func testSnapshotStreamDeliversAgainAfterClose() async {
        let pipe = RestartableSnapshotStream()
        pipe.open()
        let first = Task {
            var batches = 0
            for await _ in pipe.stream { batches += 1 }
            return batches
        }
        pipe.yield([phone()])
        try? await Task.sleep(nanoseconds: 30_000_000)
        pipe.close()
        let firstCount = await first.value
        XCTAssertEqual(firstCount, 1)

        pipe.open()
        let second = Task {
            for await batch in pipe.stream {
                return batch
            }
            return [CaptureDeviceSnapshot]()
        }
        pipe.yield([phone(id: "uid-2")])
        let batch = await second.value
        XCTAssertEqual(batch.first?.uniqueID, "uid-2")
    }

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
        monitor.pollInterval = 0.05
        monitor.start(generation: 1)
        monitor.stop()
        hits.removeAll()
        monitor.start(generation: 2)
        catalog.emit([
            CaptureDeviceSnapshot(
                uniqueID: "uid-1",
                localizedName: "x",
                isContinuityCamera: true,
                isDeskView: false,
                deviceTypeRaw: "continuity"
            ),
        ])
        let deadline = Date().addingTimeInterval(1)
        while hits.last != 2 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(hits.contains(1))
        XCTAssertEqual(hits.last, 2)
        monitor.stop()
    }

    func testLateAppearanceWithoutNotificationStillMatches() async {
        let catalog = FakeCaptureCatalog()
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "uid-1"
        let monitor = PresenceMonitor(
            catalog: catalog,
            matcher: { matcher },
            isCameraAuthorized: { true }
        )
        monitor.pollInterval = 0.05
        var evidence: PresenceEvidence?
        monitor.onMatched = { evidence = $0 }
        monitor.start(generation: 4)
        XCTAssertNil(evidence)

        catalog.currentDevices = [
            CaptureDeviceSnapshot(
                uniqueID: "uid-1",
                localizedName: "“terranc”的相机",
                isContinuityCamera: true,
                isDeskView: false,
                deviceTypeRaw: "continuity"
            ),
        ]

        let deadline = Date().addingTimeInterval(1)
        while evidence == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(evidence?.generation, 4)
        XCTAssertEqual(evidence?.matchReason, .uniqueID)
        monitor.stop()
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
