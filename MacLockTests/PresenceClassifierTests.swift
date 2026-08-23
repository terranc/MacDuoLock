import XCTest
@testable import MacLock

final class PresenceClassifierTests: XCTestCase {
    private func device(
        id: String = "uid-1",
        name: String = "厨房",
        continuity: Bool = true,
        desk: Bool = false
    ) -> CaptureDeviceSnapshot {
        CaptureDeviceSnapshot(
            uniqueID: id,
            localizedName: name,
            isContinuityCamera: continuity,
            isDeskView: desk,
            deviceTypeRaw: desk ? "deskView" : "continuity"
        )
    }

    func testDisconnectedOrSuspendedNeverMatches() {
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "uid-1"
        XCTAssertFalse(isEligible(
            CaptureDeviceSnapshot(
                uniqueID: "uid-1",
                localizedName: "x",
                isContinuityCamera: true,
                isDeskView: false,
                isConnected: false,
                deviceTypeRaw: "continuity"
            ),
            matcher: matcher
        ))
        XCTAssertFalse(isEligible(
            CaptureDeviceSnapshot(
                uniqueID: "uid-1",
                localizedName: "x",
                isContinuityCamera: true,
                isDeskView: false,
                isSuspended: true,
                deviceTypeRaw: "continuity"
            ),
            matcher: matcher
        ))
    }

    func testNonContinuityNeverMatches() {
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "uid-1"
        XCTAssertFalse(isEligible(device(continuity: false), matcher: matcher))
    }

    func testUniqueIDHitsEvenWhenNameIsKitchen() {
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "uid-1"
        XCTAssertTrue(isEligible(device(name: "厨房间"), matcher: matcher))
        XCTAssertEqual(matchReason(for: device(name: "厨房间"), matcher: matcher), .uniqueID)
    }

    func testExactNameHitsWhenUniqueIDMisses() {
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "other"
        matcher.preferredLocalizedName = "Max"
        XCTAssertTrue(isEligible(device(id: "uid-9", name: "Max"), matcher: matcher))
        XCTAssertEqual(matchReason(for: device(id: "uid-9", name: "Max"), matcher: matcher), .exactLocalizedName)
    }

    func testBothMissIsFalseNoAnyDeviceFallback() {
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "a"
        matcher.preferredLocalizedName = "b"
        XCTAssertFalse(isEligible(device(id: "c", name: "d"), matcher: matcher))
    }

    func testUnboundMatchesAnyContinuityCamera() {
        XCTAssertTrue(isEligible(device(), matcher: PresenceMatcher.v1Default))
        XCTAssertEqual(matchReason(for: device(), matcher: PresenceMatcher.v1Default), .unboundContinuity)
        XCTAssertFalse(isEligible(device(continuity: false), matcher: PresenceMatcher.v1Default))
    }

    func testDeskViewRejectedEvenWithSameUniqueID() {
        var matcher = PresenceMatcher.v1Default
        matcher.preferredUniqueID = "uid-1"
        matcher.allowDeskView = false
        XCTAssertFalse(isEligible(device(desk: true), matcher: matcher))
    }

    func testDoesNotTreatLANIPAsPresence() {
        var matcher = PresenceMatcher.v1Default
        matcher.preferredLocalizedName = "192.168.0.9"
        matcher.preferredUniqueID = "192.168.0.9"
        let nearbyPhone = device(id: "continuity-xyz", name: "Terrance 的 iPhone")
        XCTAssertFalse(isEligible(nearbyPhone, matcher: matcher))
    }
}
