import AppKit
import Foundation
import Security

enum RemoteControlHostProcessReader {
    static func processes() -> [RemoteControlHostProcess] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let identifier = identity(of: app),
                  let catalog = RemoteControlCatalog.application(for: identifier),
                  catalog.hostSigningIdentifiers.contains(identifier) else { return nil }
            return RemoteControlHostProcess(
                name: catalog.name,
                signingIdentifier: identifier,
                processIdentifier: app.processIdentifier
            )
        }
    }

    static func identity(of app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? signingIdentifier(of: app)
    }

    static func signingIdentifier(of app: NSRunningApplication) -> String? {
        guard let url = app.executableURL ?? app.bundleURL else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess else { return nil }
        return (info as NSDictionary?)?[kSecCodeInfoIdentifier] as? String
    }
}

enum RemoteControlProcessSocketReader {
    private static var cache: [Int32: (time: TimeInterval, sockets: [RemoteControlProcessSocket])] = [:]

    static func sockets(for processIdentifier: Int32) -> [RemoteControlProcessSocket]? {
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = cache[processIdentifier], now - hit.time < 5 { return hit.sockets }
        if let sockets = readSockets(for: processIdentifier) {
            cache[processIdentifier] = (now, sockets)
            return sockets
        }
        if let hit = cache[processIdentifier], now - hit.time < 20 { return hit.sockets }
        return nil
    }

    private static func readSockets(for processIdentifier: Int32) -> [RemoteControlProcessSocket]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(processIdentifier), "-i"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = NSMutableData()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 0.5) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        let text = String(data: output as Data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : nil
        }
        return text.split(separator: "\n").compactMap { parse(String($0)) }
    }

    static func parse(_ line: String) -> RemoteControlProcessSocket? {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let node = fields.first(where: { $0 == "TCP" || $0 == "UDP" || $0 == "TCP6" || $0 == "UDP6" }),
              let index = fields.firstIndex(of: node) else { return nil }
        let name = fields.dropFirst(index + 1).joined(separator: " ")
        guard !name.isEmpty else { return nil }
        let kind: RemoteControlProcessSocket.Kind = node.hasPrefix("TCP") ? .tcp : .udp
        let endpoints = name.split(separator: "->", maxSplits: 1).map(String.init)
        let localPort = port(of: endpoints.first ?? "")
        let remotePort = endpoints.count > 1 ? port(of: endpoints[1]) : 0
        return RemoteControlProcessSocket(
            kind: kind,
            isEstablished: name.contains("ESTABLISHED"),
            isListening: name.contains("(LISTEN)"),
            localPort: localPort,
            remotePort: remotePort
        )
    }

    private static func port(of endpoint: String) -> UInt16 {
        let token = endpoint.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if let close = token.lastIndex(of: "]"),
           close < token.endIndex,
           token[close...].hasPrefix("]:"),
           let parsed = UInt16(token[token.index(close, offsetBy: 2)...].prefix(while: { $0.isNumber })) {
            return parsed
        }
        guard let colon = token.lastIndex(of: ":"),
              let parsed = UInt16(token[token.index(after: colon)...].prefix(while: { $0.isNumber })) else { return 0 }
        return parsed
    }
}
