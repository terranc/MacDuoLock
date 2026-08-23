import Foundation

struct CaptureDeviceSnapshot: Equatable, Sendable {
    var uniqueID: String
    var localizedName: String
    var isContinuityCamera: Bool
    var isDeskView: Bool
    var isConnected: Bool = true
    var isSuspended: Bool = false
    var deviceTypeRaw: String
}

enum MatchReason: String, Equatable, Sendable {
    case uniqueID
    case exactLocalizedName
    case unboundContinuity
}

struct PresenceEvidence: Equatable, Sendable {
    var generation: UInt64
    var matchReason: MatchReason
    var uniqueIDFingerprint: String
    var truncatedLocalizedName: String
    var continuityCount: Int
    var elapsedMs: Int
}

struct PresenceMatcher: Codable, Equatable {
    var preferredUniqueID: String?
    var preferredLocalizedName: String?
    var allowIPad: Bool
    var allowDeskView: Bool

    static let v1Default = PresenceMatcher(
        preferredUniqueID: nil,
        preferredLocalizedName: nil,
        allowIPad: false,
        allowDeskView: false
    )
}

func isEligible(_ device: CaptureDeviceSnapshot, matcher: PresenceMatcher) -> Bool {
    guard device.isContinuityCamera else { return false }
    guard device.isConnected, !device.isSuspended else { return false }
    if device.isDeskView && !matcher.allowDeskView { return false }
    let unbound = matcher.preferredUniqueID == nil && matcher.preferredLocalizedName == nil
    if unbound { return true }
    if let id = matcher.preferredUniqueID, device.uniqueID == id { return true }
    if let name = matcher.preferredLocalizedName, device.localizedName == name { return true }
    return false
}

func matchReason(for device: CaptureDeviceSnapshot, matcher: PresenceMatcher) -> MatchReason? {
    guard isEligible(device, matcher: matcher) else { return nil }
    if let id = matcher.preferredUniqueID, device.uniqueID == id { return .uniqueID }
    if let name = matcher.preferredLocalizedName, device.localizedName == name { return .exactLocalizedName }
    return .unboundContinuity
}

func uniqueIDFingerprint(_ uniqueID: String) -> String {
    let digest = PasswordHasher.hash(password: uniqueID, salt: Data(repeating: 0, count: 16), iterations: 1)
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
}

func truncatedLocalizedName(_ name: String) -> String {
    String(name.prefix(24))
}
