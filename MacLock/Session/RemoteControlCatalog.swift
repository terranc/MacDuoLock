import Foundation

struct RemoteControlWindowSnapshot: Equatable {
    var bundleIdentifier: String
    var texts: [String]
    var enabledButtons: [String]
    var processIdentifier: Int32? = nil
}

enum RemoteControlCatalog {
    struct Application: Equatable {
        let name: String
        let bundleIdentifiers: [String]
        var bundlePrefixes: [String] = []
    }

    static let applications: [Application] = [
        Application(name: "UU 远程", bundleIdentifiers: ["com.netease.uuremote"]),
        Application(name: "ToDesk", bundleIdentifiers: ["com.youqu.todesk.mac"]),
        Application(name: "向日葵 / AweSun", bundleIdentifiers: ["com.oray.sunlogin.macclient"]),
        Application(name: "RayLink", bundleIdentifiers: ["de.RayLink"]),
        Application(name: "TeamViewer", bundleIdentifiers: ["com.teamviewer.TeamViewer", "com.teamviewer.TeamViewerHost", "com.teamviewer.TeamViewerQS"]),
        Application(name: "AnyDesk", bundleIdentifiers: ["com.philandro.anydesk"], bundlePrefixes: ["com.philandro.anydesk-"]),
        Application(name: "RustDesk", bundleIdentifiers: ["com.carriez.rustdesk"]),
        Application(name: "Splashtop", bundleIdentifiers: ["com.splashtop.Splashtop-Streamer"]),
        Application(name: "Chrome Remote Desktop", bundleIdentifiers: [
            "com.google.chromeremotedesktop.me2me-host",
            "com.google.chrome.remote_desktop.native-messaging-host",
            "com.google.chrome.remote_desktop.remote-assistance-host-v2",
        ]),
        Application(name: "RealVNC", bundleIdentifiers: ["com.realvnc.vncserver", "com.realvnc.vncagent"]),
        Application(name: "Jump Desktop Connect", bundleIdentifiers: ["com.p5sys.jump.connect"]),
        Application(name: "RemotePC", bundleIdentifiers: ["com.prosoftnet.remotepcSuite", "com.prosoftnet.remotepcDesktop"]),
        Application(name: "Zoho Assist", bundleIdentifiers: ["com.zoho.assist.Zoho"]),
    ]

    static func application(for bundleIdentifier: String) -> Application? {
        applications.first {
            $0.bundleIdentifiers.contains(bundleIdentifier)
                || $0.bundlePrefixes.contains { prefix in bundleIdentifier.hasPrefix(prefix) }
        }
    }

    /// Both signals must belong to one window in a known host application.
    /// Idle processes, outbound sessions and connection requests do not qualify.
    static func activeApplication(in windows: [RemoteControlWindowSnapshot]) -> String? {
        for window in windows {
            guard let app = application(for: window.bundleIdentifier),
                  window.enabledButtons.contains(where: { disconnectButtons.contains(normalize($0)) }) else { continue }
            let controlled = window.texts.contains(where: isControlledStatus)
            if window.bundleIdentifier == "com.carriez.rustdesk" {
                let texts = Set(window.texts.map(normalize))
                guard !texts.isDisjoint(with: ["screen sharing", "share screen", "屏幕共享", "共享屏幕"]),
                      texts.isDisjoint(with: ["transfer file", "file transfer", "terminal", "view camera", "port forward",
                                              "传输文件", "文件传输", "终端", "查看摄像头", "端口转发"]),
                      controlled || (!texts.isDisjoint(with: ["connection manager", "连接管理器"])
                                     && !texts.isDisjoint(with: ["connected", "已连接"])) else { continue }
            } else if !controlled {
                continue
            }
            return app.name
        }
        return nil
    }

    private static let disconnectButtons: Set<String> = [
        "断开", "断开连接", "断开远控", "断开所有远控", "结束远程控制", "结束会话", "结束共享", "停止共享", "停止分享",
        "disconnect", "disconnect all", "disconnect all clients", "stop sharing",
        "end session", "end remote session", "stop remote control", "close connection",
    ]

    // debt: App UI phrases vary by version and language; extend with verified host-state
    // fixtures when needed. Unknown layouts intentionally keep the password shield up.
    private static let statusPatterns: [NSRegularExpression] = [
        "^本机(被控中|正在被控|正在被控制)$",
        "^本机正在被他人远程控制$",
        "^本机正在被.*远程控制[。！]?$",
        "^正在被.*远程控制[。！]?$",
        "^您的(电脑|桌面|屏幕|设备)正在(被.+远程控制|与.+共享)[。！]?$",
        "^有人正在(远程控制|访问)您的(设备|电脑)[。！]?$",
        "^(您的|你的)(桌面|屏幕)(目前|当前)?(正在|正)?与.+共享[。！]?$",
        "^your (desktop|screen|desk) is (currently )?(being )?shared with .+$",
        "^your (desktop|screen|desk) is (currently )?being (controlled|viewed)( by .+)?[.!]?$",
        "^someone is (remotely )?(accessing|controlling) your (device|computer)[.!]?$",
        "^this (computer|device) is being (controlled|accessed)( by .+)?[.!]?$",
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    private static func isControlledStatus(_ text: String) -> Bool {
        let text = normalize(text)
        guard !["no one", "nobody", "请求", "申请", "等待"].contains(where: text.contains) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return statusPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
