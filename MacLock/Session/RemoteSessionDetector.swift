import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.hid

protocol RemoteSessionDetecting: AnyObject {
    var isActive: Bool { get }
    var onChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
    func noteInjected(pid: pid_t)
}

/// Polls IOHIDUserDevice, inbound session processes, and "being controlled"
/// windows. Idle UU/ToDesk agents do not count; a live virtual HID or a
/// session-only helper does.
final class LiveRemoteSessionDetector: RemoteSessionDetecting {
    private(set) var isActive = false
    var onChange: ((Bool) -> Void)?
    private(set) var lastReason: RemoteSessionReason?

    private var timer: DispatchSourceTimer?
    private var injectedName: String?
    private var injectedUntil: TimeInterval = 0
    private var notifyPort: IONotificationPortRef?
    private var hidAddedIter: io_iterator_t = 0
    private var hidRemovedIter: io_iterator_t = 0

    func start() {
        stop()
        installHIDNotifications()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        tearDownHIDNotifications()
    }

    func noteInjected(pid: pid_t) {
        guard pid > 0 else { return }
        var nameBuf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &nameBuf, 256) > 0 else { return }
        let name = String(cString: nameBuf)
        guard RemoteControlCatalog.isInjectorProcess(name: name, path: "") else { return }
        injectedName = name
        injectedUntil = ProcessInfo.processInfo.systemUptime + 2.5
        refresh()
    }

    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        let recentInjected: String?
        if let name = injectedName, now < injectedUntil {
            recentInjected = name
        } else {
            recentInjected = nil
            injectedName = nil
        }
        let reason = RemoteControlCatalog.reason(
            processes: processSnapshots(),
            hid: hidSnapshots(),
            windows: windowSnapshots(),
            injectedName: recentInjected
        )
        lastReason = reason
        let next = reason != nil
        guard next != isActive else { return }
        isActive = next
        MacLockLog.file("remote session \(next) reason=\(String(describing: reason))")
        onChange?(next)
    }

    private func processSnapshots() -> [RemoteProcessSnapshot] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let count = Int(filled) / MemoryLayout<pid_t>.size
        var result: [RemoteProcessSnapshot] = []
        for pid in pids.prefix(count) where pid > 0 {
            var nameBuf = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &nameBuf, 64) > 0 else { continue }
            let name = String(cString: nameBuf)
            guard !name.isEmpty else { continue }
            let blob = RemoteControlCatalog.normalize(name)
            let interesting =
                RemoteControlCatalog.sessionProcessNames.contains(blob)
                || RemoteControlCatalog.containsInjectorToken(name)
            guard interesting else { continue }
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
            result.append(RemoteProcessSnapshot(name: name, path: String(cString: pathBuf)))
        }
        return result
    }

    private func hidSnapshots() -> [RemoteHIDSnapshot] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDUserDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var devices: [RemoteHIDSnapshot] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            devices.append(hidSnapshot(service))
        }
        return devices
    }

    private func hidSnapshot(_ service: io_object_t) -> RemoteHIDSnapshot {
        let props = properties(service)
        var creator = string(props, "IOUserClientCreator")
        if creator.isEmpty {
            creator = childCreator(service)
        }
        return RemoteHIDSnapshot(
            product: string(props, kIOHIDProductKey as String),
            manufacturer: string(props, kIOHIDManufacturerKey as String),
            creator: creator,
            transport: string(props, kIOHIDTransportKey as String)
        )
    }

    private func childCreator(_ service: io_object_t) -> String {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return ""
        }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            let value = string(properties(child), "IOUserClientCreator")
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func windowSnapshots() -> [RemoteWindowSnapshot] {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            guard !owner.isEmpty || !title.isEmpty else { return nil }
            return RemoteWindowSnapshot(owner: owner, title: title)
        }
    }

    private func properties(_ service: io_object_t) -> [String: Any] {
        var dict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = dict?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return props
    }

    private func string(_ props: [String: Any], _ key: String) -> String {
        if let value = props[key] as? String { return value }
        if let value = props[key] as? NSNumber { return value.stringValue }
        return ""
    }

    private func installHIDNotifications() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        var added: io_iterator_t = 0
        var removed: io_iterator_t = 0
        let matchingAdd = IOServiceMatching("IOHIDUserDevice")
        let matchingRemove = IOServiceMatching("IOHIDUserDevice")
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        _ = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matchingAdd,
            { refcon, iterator in
                LiveRemoteSessionDetector.drain(iterator)
                Unmanaged<LiveRemoteSessionDetector>.fromOpaque(refcon!).takeUnretainedValue().refresh()
            },
            selfPtr, &added
        )
        _ = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, matchingRemove,
            { refcon, iterator in
                LiveRemoteSessionDetector.drain(iterator)
                Unmanaged<LiveRemoteSessionDetector>.fromOpaque(refcon!).takeUnretainedValue().refresh()
            },
            selfPtr, &removed
        )
        hidAddedIter = added
        hidRemovedIter = removed
        Self.drain(added)
        Self.drain(removed)
    }

    private func tearDownHIDNotifications() {
        if hidAddedIter != 0 { IOObjectRelease(hidAddedIter); hidAddedIter = 0 }
        if hidRemovedIter != 0 { IOObjectRelease(hidRemovedIter); hidRemovedIter = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while true {
            let obj = IOIteratorNext(iterator)
            if obj == 0 { break }
            IOObjectRelease(obj)
        }
    }

    deinit {
        timer?.cancel()
        tearDownHIDNotifications()
    }
}
