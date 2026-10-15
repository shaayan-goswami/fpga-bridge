import SwiftUI

/// Vivado's Getting Started page: Quick Start actions, Tasks, Learning Center, and Recent Projects.
struct QuickStartView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 24) {
                        section("Quick Start") {
                            QuickActionRow(symbol: "plus.square.on.square", tint: .blue, title: "Create Project",
                                           subtitle: "Start the New Project wizard") { model.showNewProject = true }
                            Divider().padding(.leading, 54)
                            QuickActionRow(symbol: "folder", tint: .indigo, title: "Open Project",
                                           subtitle: "Open a project folder") { model.openProjectWithPanel() }
                            Divider().padding(.leading, 54)
                            QuickActionRow(symbol: "lightbulb", tint: .orange, title: "Open Example Project",
                                           subtitle: "A small Basys 3 design to try things with") { model.openExampleProject() }
                        }
                        section("Tasks") {
                            QuickActionRow(symbol: "network", tint: .green, title: "Check Build Machine",
                                           subtitle: model.connection == .demo ? "Demo mode: no build machine configured"
                                                      : model.connection.detail) { Task { await model.start() } }
                            Divider().padding(.leading, 54)
                            QuickActionRow(symbol: "cable.connector.horizontal", tint: .gray, title: "Open Hardware Manager",
                                           subtitle: "Planned: program boards from the Mac", isEnabled: false) {}
                        }
                        section("Learning Center") {
                            QuickActionRow(symbol: "book", tint: .teal, title: "Documentation",
                                           subtitle: "Setup, build machine and troubleshooting") {
                                if let url = URL(string: "https://github.com/shaayan-goswami/fpga-bridge/blob/main/docs/setup.md") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    section("Recent Projects") {
                        if model.recentProjects.isEmpty {
                            Text("Projects you open will appear here.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            ForEach(Array(model.recentProjects.enumerated()), id: \.element) { index, url in
                                if index > 0 { Divider().padding(.leading, 54) }
                                QuickActionRow(symbol: "cpu", tint: .purple, title: url.lastPathComponent,
                                               subtitle: url.deletingLastPathComponent().path) { model.openProject(at: url) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(40)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .navigationTitle("FPGA Bridge")
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIconView(size: 84)
                .shadow(color: .indigo.opacity(0.25), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("FPGA Bridge").font(.largeTitle.weight(.bold))
                Text("Vivado projects on your Mac. Builds run on your Windows machine.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.connection.color).frame(width: 8, height: 8)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 6)
                .glassSurface(cornerRadius: 18)
        }
    }
}

struct QuickActionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && isEnabled ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 4))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}
