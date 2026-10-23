import XCTest
@testable import MacLock

final class RemoteControlCatalogTests: XCTestCase {
    private let uuBundleIdentifier = "com.netease.uuremote"

    func testKnownBundleIdentifiersResolveToExpectedApplication() {
        let identities = [
            ("com.netease.uuremote", "UU 远程"),
            ("com.youqu.todesk.mac", "ToDesk"),
            ("com.oray.sunlogin.macclient", "向日葵 / AweSun"),
            ("de.RayLink", "RayLink"),
            ("com.teamviewer.TeamViewer", "TeamViewer"),
            ("com.teamviewer.TeamViewerHost", "TeamViewer"),
            ("com.teamviewer.TeamViewerQS", "TeamViewer"),
            ("com.philandro.anydesk", "AnyDesk"),
            ("com.philandro.anydesk-custom123", "AnyDesk"),
            ("com.carriez.rustdesk", "RustDesk"),
            ("com.splashtop.Splashtop-Streamer", "Splashtop"),
            ("com.google.chromeremotedesktop.me2me-host", "Chrome Remote Desktop"),
            ("com.google.chrome.remote_desktop.native-messaging-host", "Chrome Remote Desktop"),
            ("com.google.chrome.remote_desktop.remote-assistance-host-v2", "Chrome Remote Desktop"),
            ("com.realvnc.vncserver", "RealVNC"),
            ("com.realvnc.vncagent", "RealVNC")
        ]
        for (bundleIdentifier, name) in identities {
            XCTAssertEqual(RemoteControlCatalog.application(for: bundleIdentifier)?.name, name, bundleIdentifier)
        }
    }

    func testAdditionalHostBundleIdentifiersAreRegistered() {
        for bundleIdentifier in [
            "com.p5sys.jump.connect", "com.prosoftnet.remotepcSuite",
            "com.prosoftnet.remotepcDesktop", "com.zoho.assist.Zoho"
        ] {
            XCTAssertNotNil(RemoteControlCatalog.application(for: bundleIdentifier), bundleIdentifier)
        }
    }

    func testSimilarNamesAndBundleIdentifiersDoNotEstablishIdentity() {
        for bundleIdentifier in [
            "", "UU 远程", "AnyDesk", "com.example.remotecontrol",
            "com.netease.uuremote.helper", "com.philandro.anydeskish",
            "com.teamviewer.TeamViewerHost.unrelated"
        ] {
            XCTAssertNil(RemoteControlCatalog.application(for: bundleIdentifier), bundleIdentifier)
        }
    }

    func testUULocalControlledStatusWithDisconnectButtonMatches() {
        let window = RemoteControlWindowSnapshot(
            bundleIdentifier: uuBundleIdentifier,
            texts: ["本机被控", "本机被控中"],
            enabledButtons: ["断开所有远控"]
        )
        XCTAssertEqual(RemoteControlCatalog.activeApplication(in: [window]), "UU 远程")
    }

    func testUUNavigationLabelDoesNotProveAnActiveSession() {
        let window = RemoteControlWindowSnapshot(
            bundleIdentifier: uuBundleIdentifier,
            texts: ["UU 远程", "本机被控"],
            enabledButtons: ["断开所有远控"]
        )
        XCTAssertNil(RemoteControlCatalog.activeApplication(in: [window]))
    }

    func testChromeHostSharingStatusWithStopSharingMatches() {
        let window = RemoteControlWindowSnapshot(
            bundleIdentifier: "com.google.chromeremotedesktop.me2me-host",
            texts: ["Your desktop is currently shared with alex@example.com."],
            enabledButtons: ["Stop Sharing"]
        )
        XCTAssertEqual(RemoteControlCatalog.activeApplication(in: [window]), "Chrome Remote Desktop")
    }

    func testEnglishStatusAndButtonNormalizeCaseAndWhitespace() {
        let window = RemoteControlWindowSnapshot(
            bundleIdentifier: "com.teamviewer.TeamViewerHost",
            texts: ["\n  YOUR \t Desktop  IS   BEING   Controlled  By Alex.  \n"],
            enabledButtons: ["  DiSConNecT \t ALL \n"]
        )
        XCTAssertEqual(RemoteControlCatalog.activeApplication(in: [window]), "TeamViewer")
    }

    func testInactiveOutboundRequestAndHelpTextDoNotProveLocalControl() {
        let texts = [
            "本机未被远程控制", "本机没有被远程控制", "当前没有远程连接",
            "正在远程控制对方电脑", "正在控制远程设备", "远程用户请求控制您的电脑",
            "有人正在申请远程控制您的设备", "本机正在被 Alex 请求远程控制",
            "允许他人远程控制本机", "如何退出：本机被控中", "设置：本机被控中",
            "Your desktop is not being controlled.", "Your screen is not shared with anyone.",
            "Your desktop is shared with no one.", "Your screen is shared with nobody.",
            "This computer is not being accessed.", "Connected to a remote computer.",
            "Someone is requesting access to your device.", "Someone wants to control your computer.",
            "Allow someone to access your computer.", "Your desktop can be shared with others.",
            "How to stop: Your desktop is being controlled.",
            "Settings: Your desktop is being controlled."
        ]
        for text in texts {
            let window = RemoteControlWindowSnapshot(
                bundleIdentifier: uuBundleIdentifier,
                texts: [text], enabledButtons: ["Disconnect", "断开所有远控"]
            )
            XCTAssertNil(RemoteControlCatalog.activeApplication(in: [window]), text)
        }
    }

    func testIdentityStatusAndEnabledDisconnectAreAllRequired() {
        let windows = [
            RemoteControlWindowSnapshot(bundleIdentifier: uuBundleIdentifier, texts: [], enabledButtons: []),
            RemoteControlWindowSnapshot(bundleIdentifier: uuBundleIdentifier, texts: [], enabledButtons: ["断开所有远控"]),
            RemoteControlWindowSnapshot(bundleIdentifier: uuBundleIdentifier, texts: ["本机被控中"], enabledButtons: []),
            RemoteControlWindowSnapshot(bundleIdentifier: uuBundleIdentifier, texts: ["本机被控中", "断开所有远控"], enabledButtons: []),
            RemoteControlWindowSnapshot(bundleIdentifier: uuBundleIdentifier, texts: ["屏幕录制中"], enabledButtons: ["停止共享"])
        ]
        for window in windows {
            XCTAssertNil(RemoteControlCatalog.activeApplication(in: [window]), "\(window)")
        }
    }

    func testDisplayNameOrWindowTitleCannotReplaceKnownBundleIdentity() {
        for bundleIdentifier in ["", "UU 远程", "com.example.remotecontrol"] {
            let window = RemoteControlWindowSnapshot(
                bundleIdentifier: bundleIdentifier,
                texts: ["UU 远程", "TeamViewer", "本机被控中"],
                enabledButtons: ["断开所有远控"]
            )
            XCTAssertNil(RemoteControlCatalog.activeApplication(in: [window]), bundleIdentifier)
        }
    }

    func testStatusAndDisconnectMustBelongToTheSameWindow() {
        let statusWindow = RemoteControlWindowSnapshot(
            bundleIdentifier: uuBundleIdentifier, texts: ["本机被控中"], enabledButtons: []
        )
        let buttonWindow = RemoteControlWindowSnapshot(
            bundleIdentifier: uuBundleIdentifier, texts: [], enabledButtons: ["断开所有远控"]
        )
        XCTAssertNil(RemoteControlCatalog.activeApplication(in: [statusWindow, buttonWindow]))
    }

    func testSimulatedRustDeskConnectionManagerRequiresAnActiveDesktopMode() {
        for mode in ["Screen sharing", "Share screen", "屏幕共享", "共享屏幕"] {
            for connectionStatus in [["Connection Manager", "Connected"], ["连接管理器", "已连接"]] {
                let window = RemoteControlWindowSnapshot(
                    bundleIdentifier: "com.carriez.rustdesk",
                    texts: connectionStatus + [mode], enabledButtons: ["Disconnect"]
                )
                XCTAssertEqual(RemoteControlCatalog.activeApplication(in: [window]), "RustDesk", "\(window)")
            }
        }
    }

    func testRustDeskNonDesktopModesOverrideOtherActiveSignals() {
        for mode in [
            "Transfer file", "File transfer", "Terminal", "View camera", "Port Forward",
            "文件传输", "传输文件", "终端", "查看摄像头", "端口转发"
        ] {
            let window = RemoteControlWindowSnapshot(
                bundleIdentifier: "com.carriez.rustdesk",
                texts: ["Connection Manager", "Connected", "Screen sharing",
                        "This computer is being controlled by Alex.", mode],
                enabledButtons: ["Disconnect"]
            )
            XCTAssertNil(RemoteControlCatalog.activeApplication(in: [window]), mode)
        }
    }

    func testRustDeskRequiresDesktopModeAndHostStatusInTheSameWindow() {
        let incompleteTexts = [
            ["Connection Manager", "Connected"],
            ["Connected", "Screen sharing"],
            ["Connection Manager", "Screen sharing"],
            ["This computer is being controlled by Alex."]
        ]
        for texts in incompleteTexts {
            let window = RemoteControlWindowSnapshot(
                bundleIdentifier: "com.carriez.rustdesk", texts: texts, enabledButtons: ["Disconnect"]
            )
            XCTAssertNil(RemoteControlCatalog.activeApplication(in: [window]), "\(texts)")
        }
        let statusWindow = RemoteControlWindowSnapshot(
            bundleIdentifier: "com.carriez.rustdesk",
            texts: ["Connection Manager", "Connected"], enabledButtons: ["Disconnect"]
        )
        let modeWindow = RemoteControlWindowSnapshot(
            bundleIdentifier: "com.carriez.rustdesk", texts: ["Screen sharing"], enabledButtons: []
        )
        XCTAssertNil(RemoteControlCatalog.activeApplication(in: [statusWindow, modeWindow]))
        let disabledDisconnect = RemoteControlWindowSnapshot(
            bundleIdentifier: "com.carriez.rustdesk",
            texts: ["Connection Manager", "Connected", "Screen sharing", "Disconnect"], enabledButtons: []
        )
        XCTAssertNil(RemoteControlCatalog.activeApplication(in: [disabledDisconnect]))
    }

    func testSimulatedGenericHostSignalsMatchEachKnownBundleIdentity() {
        for app in RemoteControlCatalog.applications {
            let bundleIdentifiers = app.bundleIdentifiers + app.bundlePrefixes.map { $0 + "simulated-client" }
            for bundleIdentifier in bundleIdentifiers {
                var texts = ["This computer is being controlled by Alex."]
                if bundleIdentifier == "com.carriez.rustdesk" { texts.append("Screen sharing") }
                let window = RemoteControlWindowSnapshot(
                    bundleIdentifier: bundleIdentifier,
                    texts: texts,
                    enabledButtons: ["Disconnect"]
                )
                XCTAssertEqual(RemoteControlCatalog.activeApplication(in: [window]), app.name, bundleIdentifier)
            }
        }
    }
}
