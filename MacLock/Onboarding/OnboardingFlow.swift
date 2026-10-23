import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class OnboardingFlow {
    let passwords: PasswordStore
    let secrets: GateSecretsStore
    let gate: SessionGate

    init(passwords: PasswordStore, secrets: GateSecretsStore, gate: SessionGate) {
        self.passwords = passwords
        self.secrets = secrets
        self.gate = gate
    }

    func complete(password: String, confirm: String) async throws {
        guard password.count >= PasswordStore.minimumLength else {
            throw PasswordStoreError.tooShort(length: password.count)
        }
        guard password == confirm else { throw PasswordStoreError.mismatch }
        try await passwords.setPassword(password)
        secrets.clearCleanDisarm()
        gate.handle(.armVerified)
    }

    func armAfterPasswordConfirmed() {
        secrets.clearCleanDisarm()
        gate.handle(.armVerified)
    }
}

enum SetupStep: Int, CaseIterable {
    case welcome, permissions, password, ready
}

@MainActor
final class SetupModel: ObservableObject {
    private let flow: OnboardingFlow
    private let loginItems: LoginItemService
    private let statusProvider: (AppPermission) -> PermissionStatus
    private let permissionRequester: (AppPermission) async -> Void
    private let settingsOpener: @MainActor (AppPermission) -> Bool
    let needsPassword: Bool
    var onPermissionsChanged: (() -> Void)?
    var onSettingsOpened: ((AppPermission) -> Void)?

    @Published private(set) var step: SetupStep
    @Published private(set) var statuses: [AppPermission: PermissionStatus] = [:]
    @Published var selectedPermission: AppPermission = .accessibility
    @Published var password = ""
    @Published var confirmation = ""
    @Published var message = ""
    @Published private(set) var isSaving = false
    @Published private(set) var requesting: AppPermission?
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var loginMessage = ""

    init(
        flow: OnboardingFlow,
        loginItems: LoginItemService,
        permissionRequester: @escaping (AppPermission) async -> Void = Permissions.request(_:),
        settingsOpener: @escaping @MainActor (AppPermission) -> Bool = { @MainActor in Permissions.openSettings(for: $0) },
        statusProvider: @escaping (AppPermission) -> PermissionStatus = Permissions.status(for:)
    ) {
        self.flow = flow
        self.loginItems = loginItems
        self.statusProvider = statusProvider
        self.permissionRequester = permissionRequester
        self.settingsOpener = settingsOpener
        needsPassword = !flow.gate.hasPassword
        step = needsPassword ? .welcome : .permissions
        refresh()
    }

    var steps: [SetupStep] { needsPassword ? SetupStep.allCases : [.permissions, .ready] }
    var accessibilityGranted: Bool { statuses[.accessibility] == .authorized }
    var canSavePassword: Bool {
        accessibilityGranted && password.count >= PasswordStore.minimumLength
            && !confirmation.isEmpty && !isSaving
    }

    func refresh() {
        let next = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, statusProvider($0)) })
        if next != statuses {
            statuses = next
            flow.gate.cameraAuthorized = next[.camera] == .authorized
            onPermissionsChanged?()
        }
        loginStatus = loginItems.status
    }

    func advance() {
        refresh()
        message = ""
        switch step {
        case .welcome: step = .permissions
        case .permissions:
            guard accessibilityGranted else { return }
            step = flow.gate.hasPassword ? .ready : .password
        case .password, .ready: break
        }
    }

    func back() {
        message = ""
        switch step {
        case .permissions where needsPassword: step = .welcome
        case .password: step = .permissions
        default: break
        }
    }

    func savePassword() async {
        guard !isSaving, step == .password else { return }
        refresh()
        guard accessibilityGranted else {
            returnToPermissions()
            return
        }
        isSaving = true
        message = ""
        defer { isSaving = false }
        do {
            try await flow.complete(password: password, confirm: confirmation)
            password = ""
            confirmation = ""
            step = .ready
        } catch {
            message = error.localizedDescription
        }
    }

    func prepareToFinish() -> Bool {
        refresh()
        guard accessibilityGranted else {
            returnToPermissions()
            return false
        }
        return step == .ready
    }

    private func returnToPermissions() {
        step = .permissions
        selectedPermission = .accessibility
        message = String(format: NSLocalizedString("maclock.setup.accessibility.missing", comment: ""),
                         AppPermission.accessibility.settingsTitle)
    }

    func activatePermission(_ permission: AppPermission) async {
        guard requesting == nil else { return }
        selectedPermission = permission
        await requestSelectedPermission()
    }

    func requestSelectedPermission() async {
        let permission = selectedPermission
        guard requesting == nil else { return }
        refresh()
        message = ""
        guard statuses[permission] != .authorized, statuses[permission] != .restricted else { return }
        requesting = permission
        defer { requesting = nil }
        let firstCameraRequest = permission == .camera && statuses[permission] == .notDetermined
        await permissionRequester(permission)
        refresh()
        // A camera denial stays in the guide; a second click can open Settings.
        if !firstCameraRequest, statuses[permission] != .authorized {
            if settingsOpener(permission) {
                onSettingsOpened?(permission)
            } else {
                message = NSLocalizedString("maclock.setup.settings.failed", comment: "")
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try loginItems.registerMainApp() }
            else { try loginItems.unregisterMainApp() }
            loginMessage = loginItems.status == .requiresApproval
                ? NSLocalizedString("maclock.settings.loginitem.approval", comment: "") : ""
        } catch {
            loginMessage = error.localizedDescription
        }
        refresh()
    }
}
