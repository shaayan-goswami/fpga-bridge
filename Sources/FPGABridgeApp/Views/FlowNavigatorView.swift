import SwiftUI

/// Vivado's Flow Navigator: every item is a command (run something, open a dialog), not a page.
struct FlowNavigatorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var collapsed: Set<FlowSection> = []

    var body: some View {
        List {
            ForEach(FlowSection.allCases) { section in
                Section {
                    if !collapsed.contains(section) {
                        ForEach(section.items) { item in
                            FlowRow(item: item)
                        }
                    }
                } header: {
                    // Vivado shows an arrow on each section; the sidebar's own hide/show only appears on hover.
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(collapsed.contains(section) ? -90 : 0))
                                .frame(width: 10)
                            Text(section.rawValue)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(collapsed.contains(section) ? "Show \(section.rawValue)" : "Hide \(section.rawValue)")
                }
                .collapsible(false)
            }
        }
        .listStyle(.sidebar)
        .paneGlass()
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("Flow Navigator")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .modifier(NoScrollEdgeLine())
    }
}

private struct FlowRow: View {
    @EnvironmentObject private var model: AppModel
    let item: FlowItem
    @State private var hovering = false

    private var isEnabled: Bool {
        item.isAvailable && !(item.runKind != nil && model.isRunning)
    }

    var body: some View {
        Button { model.perform(item) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconStyle)
                    .frame(width: 18)
                Text(item.title)
                    .foregroundStyle(item.isAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary.opacity(0.75)))
                Spacer(minLength: 4)
                if let state = model.status(of: item), state.status != .notStarted {
                    RunStatusIcon(state: state)
                        .font(.caption)
                        .help(state.label)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(item.unavailableReason ?? item.title)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering && isEnabled ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 8)
        )
        .onHover { hovering = $0 }
    }

    private var iconStyle: AnyShapeStyle {
        guard item.isAvailable else { return AnyShapeStyle(Color.secondary.opacity(0.65)) }
        // Runs happen in Vivado on the build machine.
        return item.runKind != nil ? AnyShapeStyle(Accent.remote) : AnyShapeStyle(.primary)
    }
}

/// The list draws a hard line under the pinned "Flow Navigator" header once it scrolls under it (macOS 26+); the
/// header sits on glass, so hide it.
private struct NoScrollEdgeLine: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}
