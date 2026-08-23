import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                row(
                    symbol: "lock.display",
                    title: NSLocalizedString("maclock.settings.overlay.label", comment: ""),
                    value: NSLocalizedString("maclock.settings.overlay.value", comment: "")
                )
                row(
                    symbol: "iphone.gen3",
                    title: NSLocalizedString("maclock.settings.presence.label", comment: ""),
                    value: NSLocalizedString("maclock.settings.presence.value", comment: "")
                )
            } header: {
                Text(NSLocalizedString("maclock.settings.section.status", comment: ""))
            } footer: {
                Text(NSLocalizedString("maclock.settings.presence.off", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                row(
                    symbol: "info.circle",
                    title: NSLocalizedString("maclock.settings.version", comment: ""),
                    value: Self.versionString
                )
            } header: {
                Text(NSLocalizedString("maclock.settings.section.about", comment: ""))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
    }

    private func row(symbol: String, title: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
            }
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        guard let build, build != short else { return short }
        return "\(short) (\(build))"
    }
}
