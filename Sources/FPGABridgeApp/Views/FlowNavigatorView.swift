import SwiftUI

/// Vivado's Flow Navigator: every item is a command (run something, open a dialog), not a page.
struct FlowNavigatorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            ForEach(FlowSection.allCases) { section in
                Section(section.rawValue) {
                    ForEach(section.items) { item in
                        FlowRow(item: item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("Flow Navigator")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
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
                    .foregroundStyle(item.isAvailable ? .primary : .tertiary)
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
        guard item.isAvailable else { return AnyShapeStyle(.tertiary) }
        return item.runKind != nil ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.accentColor)
    }
}
