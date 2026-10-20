import XCTest
@testable import MacLock

final class RemoteControlCatalogTests: XCTestCase {
    func testIdleUUAgentIsNotASession() {
        let reason = RemoteControlCatalog.reason(
            processes: [
                RemoteProcessSnapshot(name: "UURemote"),
                RemoteProcessSnapshot(name: "UURemoteService"),
                RemoteProcessSnapshot(name: "UURemoteServer"),
                RemoteProcessSnapshot(name: "UURemoteDaemon"),
            ],
            hid: [RemoteHIDSnapshot(product: "Keyboard Backlight", manufacturer: "Apple", creator: "pid 423, corebrightnessd", transport: "USB")],
            windows: [RemoteWindowSnapshot(owner: "UURemote", title: "")]
        )
        XCTAssertNil(reason)
    }

    func testToDeskSessionProcessMatches() {
        let reason = RemoteControlCatalog.reason(
            processes: [RemoteProcessSnapshot(name: "ToDesk_Session")],
            hid: [],
            windows: []
        )
        XCTAssertEqual(reason, .sessionProcess("ToDesk_Session"))
    }

    func testUUVirtualHIDCreatorMatches() {
        let reason = RemoteControlCatalog.reason(
            processes: [RemoteProcessSnapshot(name: "UURemoteServer")],
            hid: [RemoteHIDSnapshot(
                product: "Keyboard",
                manufacturer: "",
                creator: "pid 1024, UURemoteServer",
                transport: "Virtual"
            )],
            windows: []
        )
        XCTAssertEqual(reason, .virtualHID("Keyboard"))
    }

    func testKarabinerVirtualHIDIsExcluded() {
        let reason = RemoteControlCatalog.reason(
            processes: [RemoteProcessSnapshot(name: "UURemoteServer")],
            hid: [RemoteHIDSnapshot(
                product: "Karabiner DriverKit VirtualHIDKeyboard",
                manufacturer: "pqrs.org",
                creator: "pid 88, Karabiner-DriverKit-VirtualHIDDevice",
                transport: "Virtual"
            )],
            windows: []
        )
        XCTAssertNil(reason)
    }

    func testControlledWindowTitleMatches() {
        let reason = RemoteControlCatalog.reason(
            processes: [RemoteProcessSnapshot(name: "UURemote")],
            hid: [],
            windows: [RemoteWindowSnapshot(owner: "UURemote", title: "本机被控中")]
        )
        XCTAssertEqual(reason, .controlledWindow("本机被控中"))
    }

    func testInjectedUUProcessMatches() {
        let reason = RemoteControlCatalog.reason(
            processes: [],
            hid: [],
            windows: [],
            injectedName: "UURemoteServer"
        )
        XCTAssertEqual(reason, .injectedProcess("UURemoteServer"))
    }

    func testRandomAppInjectionDoesNotMatch() {
        let reason = RemoteControlCatalog.reason(
            processes: [],
            hid: [],
            windows: [],
            injectedName: "TextEdit"
        )
        XCTAssertNil(reason)
    }

    func testScreensharingAgentIsASession() {
        let reason = RemoteControlCatalog.reason(
            processes: [RemoteProcessSnapshot(name: "ScreensharingAgent")],
            hid: [],
            windows: []
        )
        XCTAssertEqual(reason, .sessionProcess("ScreensharingAgent"))
    }
}
