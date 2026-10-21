import SwiftUI

enum AppWindowMetrics {
    static let width: CGFloat = 800
    static let height: CGFloat = 600
    static let sidebarWidth: CGFloat = 192
}

struct AppWindowLayout<Sidebar: View, Content: View, Footer: View>: View {
    private let sidebar: Sidebar
    private let content: Content
    private let footer: Footer

    init(
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.sidebar = sidebar()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .padding(24)
                .frame(width: AppWindowMetrics.sidebarWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
                Divider()
                footer.padding(20)
            }
        }
        .frame(width: AppWindowMetrics.width, height: AppWindowMetrics.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AppSidebarBrand: View {
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 36)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("MacDuoLock").font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct AppPageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 25, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
