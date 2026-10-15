import SwiftUI

/// Vivado's Getting Started page (Quick Start, Tasks, Learning Center, Recent Projects). The window itself is frosted
/// glass here, with the desktop blurred through it; the project window stays opaque.
struct QuickStartView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    Divider().opacity(0.6)
                    HStack(alignment: .top, spacing: 36) {
                        VStack(alignment: .leading, spacing: 26) {
                            section("Quick Start") {
                                QuickActionRow(symbol: "plus.square.on.square", title: "Create Project",
                                               subtitle: "Start the New Project wizard", tint: Accent.source) { model.showNewProject = true }
                                QuickActionRow(symbol: "folder", title: "Open Project",
                                               subtitle: "Open a project folder", tint: Accent.source) { model.openProjectWithPanel() }
                                QuickActionRow(symbol: "lightbulb", title: "Open Example Project",
                                               subtitle: "A small Basys 3 design to try things with", tint: Accent.source) { model.openExampleProject() }
                            }
                            section("Tasks") {
                                QuickActionRow(symbol: "network", title: "Check Build Machine",
                                               subtitle: model.connection == .demo ? "Demo mode: no build machine configured"
                                                                                   : model.connection.detail,
                                               tint: Accent.remote) {
                                    Task { await model.start() }
                                }
                                QuickActionRow(symbol: "cable.connector.horizontal", title: "Open Hardware Manager",
                                               subtitle: "Planned: program boards from the Mac", isEnabled: false) {}
                            }
                            section("Learning Center") {
                                QuickActionRow(symbol: "book", title: "Documentation",
                                               subtitle: "Setup, build machine and troubleshooting", tint: Accent.simulation) {
                                    if let url = URL(string: "https://github.com/shaayan-goswami/fpga-bridge/blob/main/docs/setup.md") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        section("Recent Projects") {
                            if model.recentProjects.isEmpty {
                                Text("Projects you open will appear here.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            } else {
                                ForEach(model.recentProjects, id: \.self) { url in
                                    QuickActionRow(symbol: "cpu", title: url.lastPathComponent,
                                                   subtitle: url.deletingLastPathComponent().path, tint: Accent.source) { model.openProject(at: url) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 36)
                .padding(.bottom, 48)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("FPGA Bridge")
        .modifier(FrostedWindow())
    }

    private var header: some View {
        HStack(spacing: 18) {
            AppIconView(size: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text("FPGA Bridge").font(.largeTitle.weight(.bold))
                Text("Vivado projects on your Mac. Builds run on your Windows machine.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.connection.color).frame(width: 7, height: 7)
                Text(model.connection.label)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassSurface(Capsule())
            .help(model.connection.detail)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            VStack(spacing: 2) { content() }
        }
    }
}

struct QuickActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    /// A muted accent for what kind of action this is; nil keeps it grey.
    var tint: Color? = nil
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint ?? .primary)
                    .frame(width: 32, height: 32)
                    .background((tint ?? .primary).opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering && isEnabled ? Color.primary.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// Makes the whole window a frosted pane that blurs the desktop behind it (macOS 15+), with no title or toolbar
/// background, so the frost runs edge to edge. "Off" in Settings keeps an opaque window.
private struct FrostedWindow: ViewModifier {
    @AppStorage(AppearanceKey.glass) private var glass = GlassChoice.frosted
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .containerBackground(background, for: .window)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar(removing: .title)
        } else {
            content.background(Backdrop())
        }
    }

    /// Dark mode is solid near-black, not a blur of the desktop.
    private var background: AnyShapeStyle {
        if scheme == .dark { return AnyShapeStyle(Theme.window) }
        switch glass {
        case .frosted: return AnyShapeStyle(.regularMaterial)
        case .clear: return AnyShapeStyle(.ultraThinMaterial)
        case .off: return AnyShapeStyle(Theme.window)
        }
    }
}
