import CoreGraphics
import Darwin
import Foundation
import AppKit
import ApplicationServices

enum RemoteSessionStatus: Equatable {
    case local
    case remote
    case application(bundleIdentifier: String, processIdentifier: Int32)
    case unavailable

    var isRemote: Bool {
        switch self {
        case .remote, .application: return true
        case .local, .unavailable: return false
        }
    }

    init(whitelist: Self, vnc: Self) {
        if whitelist.isRemote { self = whitelist }
        else if vnc.isRemote { self = vnc }
        else if whitelist == .local, vnc == .local { self = .local }
        else { self = .unavailable }
    }

    static func sourceIsAvailable(_ source: Self) -> Bool {
        switch source {
        case .application(let bundleIdentifier, let pid):
            guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated && app.bundleIdentifier == bundleIdentifier
        case .remote:
            return Self(screenCaptured: true, connections: readConnections()).isRemote
        case .local, .unavailable:
            return false
        }
    }

    init(screenCaptured: Bool?, connections: String?) {
        guard let screenCaptured else { self = .unavailable; return }
        guard screenCaptured else { self = .local; return }
        guard let connections else { self = .unavailable; return }
        self = connections.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 6, ["tcp", "tcp4", "tcp6"].contains(fields[0]),
                  fields[3].hasSuffix(".5900"), fields[5] == "ESTABLISHED",
                  let separator = fields[4].lastIndex(of: "."),
                  let port = UInt16(fields[4][fields[4].index(after: separator)...]), port > 0 else { return false }
            guard let address = fields[4][..<separator].split(separator: "%", maxSplits: 1).first else { return false }
            let host = String(address)
            guard host != "0.0.0.0", !host.allSatisfy({ $0 == "0" || $0 == ":" }) else { return false }
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
        } ? .remote : .local
    }

    static func read() -> Self {
        let result = RemoteControlSessionReader.read()
        if let window = result.windows.first(where: { RemoteControlCatalog.activeApplication(in: [$0]) != nil }),
           let pid = window.processIdentifier {
            return .application(bundleIdentifier: window.bundleIdentifier, processIdentifier: pid)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let captured = session?["CGSSessionScreenIsCaptured"] as? Bool
        let vnc = Self(screenCaptured: captured, connections: captured == true ? readConnections() : nil)
        return Self(whitelist: result.isComplete ? .local : .unavailable, vnc: vnc)
    }

    private static func readConnections() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-an", "-p", "tcp"]
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
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output as Data, encoding: .utf8)
    }
}

// debt: The capture key is undocumented and TCP/5900 only covers conventional VNC.
// Add other protocols only with verified live-session evidence; missing signals keep the shield up.
@MainActor
final class LiveRemoteSessionDetector {
    private let readStatus: () -> RemoteSessionStatus
    private let clock: any Clocking
    private let sourceAvailable: (RemoteSessionStatus) -> Bool
    private var timer: DispatchSourceTimer?
    private var lastStatus: RemoteSessionStatus?
    private var lastConfirmed: RemoteSessionStatus?
    private var lastConfirmedAt: TimeInterval?
    private var preparingUnlock = false
    private var unlockEvidenceUntil: TimeInterval?
    private var unavailableGraceUntil: TimeInterval?
    private var enabled = true
    private var sleeping = false
    private(set) var isActive = false
    var onChange: ((Bool) -> Void)?

    init(readStatus: @escaping () -> RemoteSessionStatus = RemoteSessionStatus.read,
         clock: any Clocking = SystemClock(),
         sourceAvailable: @escaping (RemoteSessionStatus) -> Bool = RemoteSessionStatus.sourceIsAvailable) {
        self.readStatus = readStatus
        self.clock = clock
        self.sourceAvailable = sourceAvailable
    }

    func start() {
        stop()
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        reset()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reset()
        if enabled { refresh(notify: false) }
    }

    func reset() {
        preparingUnlock = false
        clearEvidence()
    }

    /// Preflight updates the cache before the gate runs, without onChange reentry.
    func prepare(for event: SessionEvent) {
        guard enabled else { reset(); return }
        switch event {
        case .willSleep:
            sleeping = true
            reset()
            return
        case .lockNow, .chordToggle, .disarmVerified, .recoveryVerified, .passwordRotated:
            reset()
            return
        case .screenLocked:
            beginUnlockPreparation()
        case .screenUnlocked:
            sleeping = false
            finishUnlockPreparation()
        case .didLaunch(let snapshot), .didWake(let snapshot), .reconcile(let snapshot):
            if case .didWake = event { sleeping = false }
            if case .didLaunch = event { sleeping = false }
            guard snapshot.onConsole else { reset(); return }
            if snapshot.screenLocked { beginUnlockPreparation() }
            else { finishUnlockPreparation() }
        default:
            return
        }
        refresh(notify: false)
    }

    private func beginUnlockPreparation() {
        guard !preparingUnlock else { return }
        preparingUnlock = true
        if let confirmedAt = lastConfirmedAt, clock.uptime - confirmedAt < 3,
           let source = lastConfirmed, sourceAvailable(source) {
            unlockEvidenceUntil = clock.uptime + 180
            MacLockLog.file("remote unlock preflight cached")
        }
    }

    private func finishUnlockPreparation() {
        guard preparingUnlock else { return }
        if let until = unlockEvidenceUntil, clock.uptime < until,
           let source = lastConfirmed, sourceAvailable(source) {
            unavailableGraceUntil = clock.uptime + 3
            MacLockLog.file("remote unlock using preflight evidence")
        }
        preparingUnlock = false
        unlockEvidenceUntil = nil
    }

    private func clearEvidence() {
        isActive = false
        lastConfirmed = nil
        lastConfirmedAt = nil
        unlockEvidenceUntil = nil
        unavailableGraceUntil = nil
    }

    func refresh(notify: Bool = true) {
        let wasActive = isActive
        guard enabled, !sleeping else {
            reset()
            if notify, wasActive { onChange?(false) }
            return
        }
        let status = readStatus()
        if status != lastStatus {
            MacLockLog.file("remote session status=\(status)")
            lastStatus = status
        }
        if status.isRemote {
            lastConfirmed = status
            lastConfirmedAt = clock.uptime
            unavailableGraceUntil = clock.uptime + 3
            if preparingUnlock { unlockEvidenceUntil = clock.uptime + 180 }
            isActive = true
        } else if status == .unavailable, let source = lastConfirmed, sourceAvailable(source),
                  let until = preparingUnlock ? unlockEvidenceUntil : unavailableGraceUntil,
                  clock.uptime < until {
            isActive = true
        } else {
            clearEvidence()
        }
        if wasActive != isActive {
            MacLockLog.file("remote active=\(isActive) preparingUnlock=\(preparingUnlock)")
            if notify { onChange?(isActive) }
        }
    }
}

enum RemoteShieldPolicy {
    static let defaultsKey = "skipShieldForRemoteSession"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
