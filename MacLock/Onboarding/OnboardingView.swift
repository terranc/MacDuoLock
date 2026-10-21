import AppKit
import SwiftUI

private func setupText(_ key: String) -> String {
    NSLocalizedString("maclock.setup." + key, comment: "")
}

private func accessibilityText(_ key: String) -> String {
    String(format: setupText(key), AppPermission.accessibility.settingsTitle)
}

extension AppPermission {
    fileprivate var key: String {
        switch self {
        case .accessibility: return "accessibility"
        case .camera: return "camera"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .accessibility: return "hand.raised.fill"
        case .camera: return "iphone"
        }
    }
}

struct SetupRootView: View {
    @ObservedObject var model: SetupModel
    var onFinish: () -> Void
    private let appURL = Bundle.main.bundleURL

    var body: some View {
        AppWindowLayout {
            sidebar
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                switch model.step {
                case .welcome: welcome
                case .permissions: PermissionSetupView(model: model)
                case .password: password
                case .ready: ready
                }
                if !model.message.isEmpty, model.step != .permissions {
                    Label(model.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                        .accessibilityIdentifier("setup.message")
                }
            }
        } footer: {
            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            AppSidebarBrand(subtitle: setupText(model.needsPassword ? "guide" : "check"))
            VStack(alignment: .leading, spacing: 22) {
                ForEach(model.steps, id: \.rawValue) { step in
                    HStack(spacing: 10) {
                        Image(systemName: step.rawValue < model.step.rawValue
                              ? "checkmark.circle.fill" : "\(model.steps.firstIndex(of: step)! + 1).circle\(step == model.step ? ".fill" : "")")
                            .font(.title3)
                            .foregroundStyle(step.rawValue <= model.step.rawValue ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        Text(setupText("step.\(step.rawValue)"))
                            .fontWeight(step == model.step ? .semibold : .regular)
                            .foregroundStyle(step == model.step ? .primary : .secondary)
                    }
                    .accessibilityAddTraits(step == model.step ? .isSelected : [])
                }
            }
            Spacer()
            Text(setupText("consent"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("welcome.title", subtitle: "welcome.subtitle")
            feature("hand.raised.fill", title: "welcome.permissions", detail: "welcome.permissions.detail")
            feature("key.fill", title: "welcome.password", detail: "welcome.password.detail")
            feature("checkmark.shield.fill", title: "welcome.ready", detail: "welcome.ready.detail")
            GroupBox {
                Label(setupText("welcome.privacy"), systemImage: "eye.slash")
                    .font(.callout).foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !appURL.path.hasPrefix("/Applications/"),
               !appURL.path.hasPrefix(NSHomeDirectory() + "/Applications/") {
                Label(setupText("install"), systemImage: "folder.badge.gearshape")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var password: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("password.title", subtitle: "password.subtitle")
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("maclock.onboard.field.password", comment: ""))
                MacSecureField(text: $model.password, onSubmit: savePassword)
                    .frame(height: 24)
                    .accessibilityLabel(NSLocalizedString("maclock.onboard.field.password", comment: ""))
                Text(NSLocalizedString("maclock.password.confirm", comment: "")).padding(.top, 10)
                MacSecureField(text: $model.confirmation, onSubmit: savePassword)
                    .frame(height: 24)
                    .accessibilityLabel(NSLocalizedString("maclock.password.confirm", comment: ""))
            }
            .font(.callout)
            Label(String(format: NSLocalizedString("maclock.onboard.short", comment: ""), PasswordStore.minimumLength),
                  systemImage: model.password.count >= PasswordStore.minimumLength ? "checkmark.circle.fill" : "circle")
                .font(.callout).foregroundStyle(.secondary)
            Text(setupText("password.note")).font(.callout).foregroundStyle(.secondary)
        }
        .onChange(of: model.password) { model.message = "" }
        .onChange(of: model.confirmation) { model.message = "" }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48)).foregroundStyle(.green).accessibilityHidden(true)
            heading("ready.title", subtitle: "ready.subtitle")
            ForEach(AppPermission.allCases) { permission in
                HStack {
                    Label(permission.settingsTitle, systemImage: permission.symbol)
                    Spacer()
                    Text(setupText(model.statuses[permission] == .authorized ? "authorized" : "skipped"))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if model.statuses[.camera] != .authorized {
                Text(setupText("ready.passwordonly")).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Toggle(NSLocalizedString("maclock.settings.loginitem", comment: ""), isOn: Binding(
                get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            if !model.loginMessage.isEmpty {
                Text(model.loginMessage).font(.caption).foregroundStyle(.secondary)
            }
            if model.loginStatus == .requiresApproval {
                Button(setupText("settings.open")) { try? LoginItemService().openSettings() }
            }
            Text(String(format: setupText("ready.shortcut"), LockShortcutStore.current.displayString))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step == .password || (model.step == .permissions && model.needsPassword) {
                Button(setupText("back")) { model.back() }.disabled(model.isSaving)
            }
            if model.step == .permissions {
                Text(model.accessibilityGranted ? setupText("optional.hint") : accessibilityText("required.hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.isSaving { ProgressView().controlSize(.small) }
            Button(setupText(model.step == .welcome ? "start" : model.step == .ready ? "finish" : "continue")) {
                switch model.step {
                case .password: savePassword()
                case .ready:
                    if model.prepareToFinish() { onFinish() }
                default: model.advance()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSaving || model.requesting != nil
                      || (model.step == .permissions && !model.accessibilityGranted)
                      || (model.step == .password && !model.canSavePassword))
        }
    }

    private func savePassword() { Task { await model.savePassword() } }

    private func heading(_ title: String, subtitle: String) -> some View {
        AppPageHeading(title: setupText(title), subtitle: setupText(subtitle))
    }

    private func feature(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(setupText(title)).fontWeight(.medium)
                Text(setupText(detail)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


}

struct PermissionSetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeading(title: setupText("permissions.title"), subtitle: setupText("permissions.subtitle"))
            HStack(spacing: 8) {
                ForEach(AppPermission.allCases) { permission in permissionTab(permission) }
            }
            permissionDetail
            if !model.message.isEmpty {
                Label(model.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("setup.message")
            }
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private func permissionTab(_ permission: AppPermission) -> some View {
        let status = model.statuses[permission] ?? .denied
        let authorized = status == .authorized
        let highlighted = authorized && model.selectedPermission == permission
        return Button {
            Task { await model.activatePermission(permission) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: permission.symbol)
                        .foregroundStyle(authorized ? Color.accentColor : .secondary)
                    Spacer()
                    if model.requesting == permission {
                        ProgressView().controlSize(.small)
                    } else if authorized {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if status != .restricted {
                        Image(systemName: "arrow.up.forward").foregroundStyle(.secondary)
                    }
                }
                Text(permission.settingsTitle).fontWeight(.medium)
                Text(setupText(permission == .accessibility ? "required" : "optional"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(setupText(model.requesting == permission ? "card.requesting"
                               : authorized ? "authorized" : status == .restricted ? "restricted" : "card.authorize"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(authorized ? Color.green : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(highlighted ? Color.accentColor.opacity(0.08)
                        : authorized ? Color(nsColor: .controlBackgroundColor) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(highlighted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.requesting != nil)
        .accessibilityAddTraits(model.selectedPermission == permission ? .isSelected : [])
    }

    private var permissionDetail: some View {
        let permission = model.selectedPermission
        let status = model.statuses[permission] ?? .denied
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(permission.settingsTitle).font(.title3.weight(.semibold))
                Spacer()
                Label(setupText(status == .authorized ? "authorized" : status == .restricted ? "restricted" : "pending"),
                      systemImage: status == .authorized ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(status == .authorized ? Color.green : .secondary)
            }
            Text(setupText(permission.key + ".purpose"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status == .restricted {
                Text(setupText("camera.restricted")).font(.callout)
            } else if status != .authorized {
                VStack(alignment: .leading, spacing: 10) {
                    instruction(1, permission == .accessibility
                                ? accessibilityText("accessibility.instruction.1") : setupText("camera.instruction.1"))
                    instruction(2, setupText(permission.key + ".instruction.2"))
                    instruction(3, setupText(permission.key + ".instruction.3"))
                }
                if permission == .camera {
                    Text(setupText("camera.requirements")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(setupText("permission.done"), systemImage: "checkmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.weight(.medium)).frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.12), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: SetupModel
    private var dragGuide: PermissionDragGuide?
    var onClose: (() -> Void)?

    init(flow: OnboardingFlow, loginItems: LoginItemService) {
        model = SetupModel(flow: flow, loginItems: loginItems)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AppWindowMetrics.width, height: AppWindowMetrics.height),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = setupText(model.needsPassword ? "guide" : "check") + " — MacDuoLock"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        model.onSettingsOpened = { [weak self] permission in
            if permission == .accessibility { self?.showDragGuide() }
        }
        window.contentViewController = NSHostingController(rootView: SetupRootView(model: model) { [weak self] in
            self?.close()
        })
        window.setContentSize(NSSize(width: AppWindowMetrics.width, height: AppWindowMetrics.height))
        window.centerOnActiveScreen()
    }

    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.isSaving }
    func windowWillClose(_ notification: Notification) {
        dragGuide?.dismiss()
        onClose?()
    }

    private func showDragGuide() {
        if dragGuide == nil {
            dragGuide = PermissionDragGuide(isAuthorized: { [weak self] in
                self?.model.refresh()
                return self?.model.accessibilityGranted ?? true
            }, onReturnToSetup: { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            })
        }
        dragGuide?.present()
    }
}
