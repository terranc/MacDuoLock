import XCTest
@testable import MacLock

@MainActor
final class SetupModelTests: XCTestCase {
    func testFirstSetupStartsAtWelcomeWithoutWritingSecrets() {
        let keychain = FakeKeychain()
        let flow = makeFlow(keychain: keychain)
        let model = makeModel(flow: flow, accessibility: .denied)

        XCTAssertTrue(model.needsPassword)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(model.steps, SetupStep.allCases)
        XCTAssertEqual(model.statuses[.accessibility], .denied)
        XCTAssertTrue(keychain.storage.isEmpty)
        XCTAssertFalse(flow.gate.armed)
    }

    func testMissingAccessibilityBlocksAdvancingAndSaving() async {
        let keychain = FakeKeychain()
        let flow = makeFlow(keychain: keychain)
        let model = makeModel(flow: flow, accessibility: .denied)
        model.advance()
        model.advance()
        model.password = "setup-password"
        model.confirmation = "setup-password"

        await model.savePassword()

        XCTAssertEqual(model.step, .permissions)
        XCTAssertFalse(model.canSavePassword)
        XCTAssertFalse(model.prepareToFinish())
        XCTAssertTrue(keychain.storage.isEmpty)
        XCTAssertFalse(flow.gate.armed)
    }

    func testAccessibilityRevokedBeforeSaveReturnsToPermissions() async {
        let keychain = FakeKeychain()
        let flow = makeFlow(keychain: keychain)
        var accessibility: PermissionStatus = .authorized
        let model = SetupModel(flow: flow, loginItems: LoginItemService(), statusProvider: {
            $0 == .accessibility ? accessibility : .notDetermined
        })
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .password)
        model.password = "setup-password"
        model.confirmation = "setup-password"
        accessibility = .denied

        await model.savePassword()

        XCTAssertEqual(model.step, .permissions)
        XCTAssertEqual(model.selectedPermission, .accessibility)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertTrue(keychain.storage.isEmpty)
        XCTAssertFalse(flow.gate.armed)
    }

    func testOptionalCameraStatesDoNotBlockSetup() async {
        for camera: PermissionStatus in [.notDetermined, .denied, .restricted] {
            let flow = makeFlow()
            let model = makeModel(flow: flow, camera: camera)
            model.advance()
            model.advance()
            XCTAssertEqual(model.step, .password, "camera status: \(camera)")
            model.password = "setup-password"
            model.confirmation = "setup-password"
            XCTAssertTrue(model.canSavePassword)

            await model.savePassword()

            XCTAssertEqual(model.step, .ready, "camera status: \(camera)")
            XCTAssertTrue(model.prepareToFinish())
            XCTAssertTrue(flow.gate.armed)
            XCTAssertFalse(flow.gate.cameraAuthorized)
        }
    }

    func testRefreshUpdatesGateCameraStateAndOnlyNotifiesOnChange() {
        let flow = makeFlow()
        flow.gate.cameraAuthorized = true
        var camera: PermissionStatus = .notDetermined
        let model = SetupModel(flow: flow, loginItems: LoginItemService(), statusProvider: {
            $0 == .camera ? camera : .authorized
        })
        var changes = 0
        model.onPermissionsChanged = { changes += 1 }
        XCTAssertFalse(flow.gate.cameraAuthorized)

        model.refresh()
        XCTAssertEqual(changes, 0)
        camera = .authorized
        model.refresh()
        XCTAssertTrue(flow.gate.cameraAuthorized)
        XCTAssertEqual(model.statuses[.camera], .authorized)
        XCTAssertEqual(changes, 1)
        model.refresh()
        XCTAssertEqual(changes, 1)
        camera = .denied
        model.refresh()
        XCTAssertFalse(flow.gate.cameraAuthorized)
        XCTAssertEqual(changes, 2)
        model.refresh()
        XCTAssertEqual(changes, 2)
    }

    func testMismatchedPasswordDoesNotCompleteSetup() async {
        let flow = makeFlow()
        let model = makeModel(flow: flow)
        model.advance()
        model.advance()
        model.password = "setup-password"
        model.confirmation = "different-password"

        await model.savePassword()

        XCTAssertEqual(model.step, .password)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertFalse(model.isSaving)
        XCTAssertFalse(flow.gate.hasPassword)
        XCTAssertFalse(flow.gate.armed)
    }

    func testShortPasswordDoesNotCompleteSetup() async {
        let flow = makeFlow()
        let model = makeModel(flow: flow)
        model.advance()
        model.advance()
        model.password = String(repeating: "a", count: PasswordStore.minimumLength - 1)
        model.confirmation = model.password
        XCTAssertFalse(model.canSavePassword)

        await model.savePassword()

        XCTAssertEqual(model.step, .password)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertFalse(model.isSaving)
        XCTAssertFalse(flow.gate.hasPassword)
        XCTAssertFalse(flow.gate.armed)
    }

    func testKeychainFailureDoesNotCompleteOrArmSetup() async {
        let keychain = FakeKeychain()
        let flow = makeFlow(keychain: keychain)
        let model = makeModel(flow: flow)
        model.advance()
        model.advance()
        model.password = "setup-password"
        model.confirmation = "setup-password"
        keychain.unavailable = errSecInteractionNotAllowed

        await model.savePassword()

        XCTAssertEqual(model.step, .password)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(keychain.storage[KeychainAccount.password])
        XCTAssertFalse(flow.gate.armed)
    }

    func testSuccessfulSaveClearsPlaintextAndArmsGate() async {
        let keychain = FakeKeychain()
        let flow = makeFlow(keychain: keychain)
        flow.secrets.writeCleanDisarm()
        let model = makeModel(flow: flow)
        model.advance()
        model.advance()
        model.password = "setup-password"
        model.confirmation = "setup-password"

        await model.savePassword()

        XCTAssertEqual(model.step, .ready)
        XCTAssertTrue(model.prepareToFinish())
        XCTAssertEqual(model.password, "")
        XCTAssertEqual(model.confirmation, "")
        XCTAssertEqual(model.message, "")
        XCTAssertFalse(model.isSaving)
        XCTAssertTrue(flow.gate.hasPassword)
        XCTAssertTrue(flow.gate.armed)
        XCTAssertEqual(flow.gate.state, .unlocked)
        XCTAssertNil(keychain.storage[KeychainAccount.cleanDisarm])
        let verification = await flow.passwords.verify("setup-password")
        XCTAssertEqual(verification, .accepted)
    }

    func testExistingPasswordOnlyChecksPermissionsAndPreservesSecrets() async throws {
        let keychain = FakeKeychain()
        let flow = makeFlow(keychain: keychain)
        try await flow.passwords.setPassword("existing-password")
        flow.secrets.writeCleanDisarm()
        let originalStorage = keychain.storage
        let model = makeModel(flow: flow)

        XCTAssertFalse(model.needsPassword)
        XCTAssertEqual(model.step, .permissions)
        XCTAssertEqual(model.steps, [.permissions, .ready])
        model.advance()
        XCTAssertEqual(model.step, .ready)
        model.password = "replacement-password"
        model.confirmation = "replacement-password"
        await model.savePassword()

        XCTAssertTrue(model.prepareToFinish())
        XCTAssertEqual(keychain.storage, originalStorage)
        XCTAssertFalse(flow.gate.armed)
    }

    func testFinishingRechecksAccessibilityAndReturnsToPermissions() async throws {
        let flow = makeFlow()
        try await flow.passwords.setPassword("existing-password")
        var accessibility: PermissionStatus = .authorized
        let model = SetupModel(flow: flow, loginItems: LoginItemService(), statusProvider: {
            $0 == .accessibility ? accessibility : .denied
        })
        model.advance()
        XCTAssertEqual(model.step, .ready)
        accessibility = .denied

        XCTAssertFalse(model.prepareToFinish())
        XCTAssertEqual(model.step, .permissions)
        XCTAssertEqual(model.selectedPermission, .accessibility)
        XCTAssertFalse(model.message.isEmpty)
    }

    func testRestoringAccessibilityAfterSaveDoesNotRequireAnotherPassword() async {
        let keychain = FakeKeychain()
        let flow = makeFlow(keychain: keychain)
        var accessibility: PermissionStatus = .authorized
        let model = SetupModel(flow: flow, loginItems: LoginItemService(), statusProvider: {
            $0 == .accessibility ? accessibility : .notDetermined
        })
        model.advance()
        model.advance()
        model.password = "setup-password"
        model.confirmation = "setup-password"
        await model.savePassword()
        XCTAssertEqual(model.step, .ready)
        let savedStorage = keychain.storage
        accessibility = .denied

        XCTAssertFalse(model.prepareToFinish())
        XCTAssertEqual(model.step, .permissions)
        accessibility = .authorized
        model.advance()

        XCTAssertEqual(model.step, .ready)
        XCTAssertTrue(model.prepareToFinish())
        model.password = "replacement-password"
        model.confirmation = "replacement-password"
        await model.savePassword()
        XCTAssertEqual(keychain.storage, savedStorage)
    }

    func testAccessibilitySettingsOpenNotifiesGuideAfterRequest() async {
        var requested: [AppPermission] = []
        var opened: [AppPermission] = []
        var guides: [AppPermission] = []
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { requested.append($0) },
            settingsOpener: { opened.append($0); return true },
            statusProvider: { _ in .denied }
        )
        model.onSettingsOpened = { guides.append($0) }

        await model.requestSelectedPermission()

        XCTAssertEqual(requested, [.accessibility])
        XCTAssertEqual(opened, [.accessibility])
        XCTAssertEqual(guides, [.accessibility])
        XCTAssertTrue(model.message.isEmpty)
        XCTAssertNil(model.requesting)
    }

    func testFailedSettingsOpenDoesNotShowDetachedGuide() async {
        var guides = 0
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { _ in }, settingsOpener: { _ in false },
            statusProvider: { _ in .denied }
        )
        model.onSettingsOpened = { _ in guides += 1 }

        await model.requestSelectedPermission()

        XCTAssertEqual(guides, 0)
        XCTAssertFalse(model.message.isEmpty)
    }

    func testGrantDuringRequestDoesNotOpenSettingsOrGuide() async {
        var accessibility: PermissionStatus = .denied
        var opened = 0
        var guides = 0
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { _ in accessibility = .authorized },
            settingsOpener: { _ in opened += 1; return true },
            statusProvider: { $0 == .accessibility ? accessibility : .notDetermined }
        )
        model.onSettingsOpened = { _ in guides += 1 }

        await model.requestSelectedPermission()

        XCTAssertEqual(opened, 0)
        XCTAssertEqual(guides, 0)
        XCTAssertTrue(model.accessibilityGranted)
    }

    func testFirstCameraDenialStaysInSetupWithoutOpeningSettings() async {
        var camera: PermissionStatus = .notDetermined
        var opened = 0
        var guides = 0
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { _ in camera = .denied },
            settingsOpener: { _ in opened += 1; return true },
            statusProvider: { $0 == .camera ? camera : .authorized }
        )
        model.selectedPermission = .camera
        model.onSettingsOpened = { _ in guides += 1 }

        await model.requestSelectedPermission()

        XCTAssertEqual(opened, 0)
        XCTAssertEqual(guides, 0)
        XCTAssertEqual(model.statuses[.camera], .denied)
    }

    func testClickingUnauthorizedCardStartsAuthorizationDirectly() async {
        var requested: [AppPermission] = []
        var opened: [AppPermission] = []
        var guides: [AppPermission] = []
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { requested.append($0) },
            settingsOpener: { opened.append($0); return true },
            statusProvider: { _ in .denied }
        )
        model.selectedPermission = .camera
        model.onSettingsOpened = { guides.append($0) }

        await model.activatePermission(.accessibility)

        XCTAssertEqual(model.selectedPermission, .accessibility)
        XCTAssertEqual(requested, [.accessibility])
        XCTAssertEqual(opened, [.accessibility])
        XCTAssertEqual(guides, [.accessibility])
    }

    func testClickingAuthorizedCardsOnlySwitchesDetails() async {
        var requests = 0
        var opened = 0
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { _ in requests += 1 },
            settingsOpener: { _ in opened += 1; return true },
            statusProvider: { _ in .authorized }
        )
        for permission in AppPermission.allCases {
            model.message = "old error"
            await model.activatePermission(permission)
            XCTAssertEqual(model.selectedPermission, permission)
            XCTAssertTrue(model.message.isEmpty)
        }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(opened, 0)
    }

    func testClickingCameraCardRequestsFirstAccessWithoutOpeningSettings() async {
        var camera: PermissionStatus = .notDetermined
        var requested: [AppPermission] = []
        var opened = 0
        let flow = makeFlow()
        let model = SetupModel(
            flow: flow, loginItems: LoginItemService(),
            permissionRequester: { requested.append($0); camera = .authorized },
            settingsOpener: { _ in opened += 1; return true },
            statusProvider: { $0 == .camera ? camera : .authorized }
        )

        await model.activatePermission(.camera)

        XCTAssertEqual(model.selectedPermission, .camera)
        XCTAssertEqual(requested, [.camera])
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(flow.gate.cameraAuthorized)
    }

    func testClickingRestrictedCardOnlyShowsRestrictionDetails() async {
        var requests = 0
        var opened = 0
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { _ in requests += 1 },
            settingsOpener: { _ in opened += 1; return true },
            statusProvider: { $0 == .camera ? .restricted : .authorized }
        )

        await model.activatePermission(.camera)

        XCTAssertEqual(model.selectedPermission, .camera)
        XCTAssertEqual(model.statuses[.camera], .restricted)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(opened, 0)
    }

    func testCardClickRechecksPermissionGrantedSinceLastRefresh() async {
        var status: PermissionStatus = .denied
        var requests = 0
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { _ in requests += 1 }, settingsOpener: { _ in false },
            statusProvider: { _ in status }
        )
        XCTAssertEqual(model.statuses[.accessibility], .denied)
        status = .authorized

        await model.activatePermission(.accessibility)

        XCTAssertEqual(model.statuses[.accessibility], .authorized)
        XCTAssertEqual(requests, 0)
    }

    func testRepeatedCardClicksDoNotDuplicateOrSwitchAnOngoingRequest() async {
        var pending: CheckedContinuation<Void, Never>?
        var requested: [AppPermission] = []
        let model = SetupModel(
            flow: makeFlow(), loginItems: LoginItemService(),
            permissionRequester: { permission in
                requested.append(permission)
                await withCheckedContinuation { pending = $0 }
            },
            settingsOpener: { _ in true }, statusProvider: { _ in .denied }
        )
        let first = Task { await model.activatePermission(.accessibility) }
        while pending == nil { await Task.yield() }

        await model.activatePermission(.camera)
        await model.activatePermission(.accessibility)
        await model.requestSelectedPermission()

        XCTAssertEqual(requested, [.accessibility])
        XCTAssertEqual(model.selectedPermission, .accessibility)
        XCTAssertEqual(model.requesting, .accessibility)
        pending?.resume()
        await first.value
        XCTAssertNil(model.requesting)
    }

    private func makeFlow(keychain: FakeKeychain = FakeKeychain()) -> OnboardingFlow {
        let secrets = GateSecretsStore(keychain: keychain)
        let clock = FakeClock()
        let passwords = PasswordStore(secrets: secrets, hasher: RecordingHasher(), clock: clock)
        let gate = SessionGate(
            secrets: secrets,
            overlay: OverlaySpy(),
            tap: TapSpy(),
            presence: PresenceSpy(),
            clock: clock
        )
        return OnboardingFlow(passwords: passwords, secrets: secrets, gate: gate)
    }

    private func makeModel(
        flow: OnboardingFlow,
        accessibility: PermissionStatus = .authorized,
        camera: PermissionStatus = .notDetermined
    ) -> SetupModel {
        SetupModel(flow: flow, loginItems: LoginItemService(), statusProvider: {
            $0 == .accessibility ? accessibility : camera
        })
    }
}
