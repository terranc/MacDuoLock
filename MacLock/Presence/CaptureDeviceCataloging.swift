import AVFoundation
import Foundation

protocol CaptureDeviceCataloging: AnyObject {
    var currentDevices: [CaptureDeviceSnapshot] { get }
    var deviceChanges: AsyncStream<[CaptureDeviceSnapshot]> { get }
    func start()
    func stop()
}

final class AVCaptureDeviceCatalog: CaptureDeviceCataloging {
    private var session: AVCaptureDevice.DiscoverySession?
    private var continuation: AsyncStream<[CaptureDeviceSnapshot]>.Continuation?
    private var observers: [NSObjectProtocol] = []

    var currentDevices: [CaptureDeviceSnapshot] {
        snapshots(from: session)
    }

    lazy var deviceChanges: AsyncStream<[CaptureDeviceSnapshot]> = {
        AsyncStream { [weak self] cont in
            self?.continuation = cont
        }
    }()

    func start() {
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
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        session = nil
        continuation?.finish()
        continuation = nil
    }

    private func emit() {
        continuation?.yield(currentDevices)
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
