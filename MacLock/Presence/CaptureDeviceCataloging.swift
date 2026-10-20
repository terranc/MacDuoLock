import AVFoundation
import Foundation

protocol CaptureDeviceCataloging: AnyObject {
    var currentDevices: [CaptureDeviceSnapshot] { get }
    var deviceChanges: AsyncStream<[CaptureDeviceSnapshot]> { get }
    func start()
    func stop()
}

/// One subscriber, restartable: `close()` finishes the current stream so the
/// next `open()` is a live sequence. A lazy stream that is finished once
/// never delivers Continuity Camera devices that appear after the first scan.
final class RestartableSnapshotStream {
    private var continuation: AsyncStream<[CaptureDeviceSnapshot]>.Continuation?
    private var boxed: AsyncStream<[CaptureDeviceSnapshot]>?

    var stream: AsyncStream<[CaptureDeviceSnapshot]> {
        boxed ?? open()
    }

    @discardableResult
    func open() -> AsyncStream<[CaptureDeviceSnapshot]> {
        continuation?.finish()
        let next = AsyncStream<[CaptureDeviceSnapshot]> { [weak self] continuation in
            self?.continuation = continuation
        }
        boxed = next
        return next
    }

    func yield(_ devices: [CaptureDeviceSnapshot]) {
        continuation?.yield(devices)
    }

    func close() {
        continuation?.finish()
        continuation = nil
        boxed = nil
    }
}

final class AVCaptureDeviceCatalog: CaptureDeviceCataloging {
    private var session: AVCaptureDevice.DiscoverySession?
    private let changes = RestartableSnapshotStream()
    private var observers: [NSObjectProtocol] = []
    private var devicesObservation: NSKeyValueObservation?

    var currentDevices: [CaptureDeviceSnapshot] {
        snapshots(from: session)
    }

    var deviceChanges: AsyncStream<[CaptureDeviceSnapshot]> {
        changes.stream
    }

    func start() {
        tearDownObservations()
        let types: [AVCaptureDevice.DeviceType] = {
            var list: [AVCaptureDevice.DeviceType] = [.continuityCamera]
            if #available(macOS 14.0, *) {
                list.append(.external)
            } else {
                list.append(.externalUnknown)
            }
            return list
        }()
        session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        changes.open()
        installObservations()
    }

    func stop() {
        tearDownObservations()
        session = nil
        changes.close()
    }

    private func installObservations() {
        let center = NotificationCenter.default
        let connected = center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.emit()
        }
        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.emit()
        }
        observers = [connected, disconnected]
        devicesObservation = session?.observe(\.devices, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.emit() }
        }
    }

    private func tearDownObservations() {
        devicesObservation?.invalidate()
        devicesObservation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func emit() {
        changes.yield(currentDevices)
    }

    private func snapshots(from session: AVCaptureDevice.DiscoverySession?) -> [CaptureDeviceSnapshot] {
        guard let session else { return [] }
        return session.devices.map { device in
            let desk = device.deviceType == .deskViewCamera
            return CaptureDeviceSnapshot(
                uniqueID: device.uniqueID,
                localizedName: device.localizedName,
                isContinuityCamera: device.isContinuityCamera,
                isDeskView: desk,
                isConnected: device.isConnected,
                isSuspended: device.isSuspended,
                deviceTypeRaw: device.deviceType.rawValue
            )
        }
    }
}
