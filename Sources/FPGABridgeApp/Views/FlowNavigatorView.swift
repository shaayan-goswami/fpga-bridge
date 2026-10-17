import FPGABridgeCore
import SwiftUI

/// Vivado's Flow Navigator: every item is a command (run something, open a dialog), not a page. An "Open ... Design"
/// item opens up to the commands for that design, and its section turns bold while the design is open.
struct FlowNavigatorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var collapsed: Set<FlowSection> = []
    @State private var expanded: Set<FlowItem> = []

    var body: some View {
        List {
            ForEach(FlowSection.allCases) { section in
                Section {
                    if !collapsed.contains(section) {
                        ForEach(section.items) { item in
                            FlowRow(item: item, isExpanded: expanded.contains(item)) { toggle(item) }
                            if expanded.contains(item) {
                                if let stage = item.designStage {
                                    ForEach(DesignCommand.commands(for: stage)) { command in
                                        FlowSubRow(title: command.title, symbol: command.symbol, unavailable: command.unavailableReason,
                                                   enabled: !(model.isRunning && model.designs[stage] == nil)) {
                                            model.perform(command, stage: stage)
                                        }
                                    }
                                } else if item == .openHardwareManager {
                                    ForEach(HardwareCommand.allCases) { command in
                                        FlowSubRow(title: command.title, symbol: nil,
                                                   unavailable: model.isAvailable(command) ? nil : "Open a target first",
                                                   enabled: true) { model.perform(command) }
                                    }
                                }
                            }
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
                            Text(section.rawValue.uppercased())
                                .fontWeight(isActive(section) ? .heavy : .semibold)
                                .foregroundStyle(isActive(section) ? .primary : .secondary)
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
        .scrollContentBackground(.hidden)
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
        .onChange(of: model.openTabs) { _, tabs in
            // Opening a design (or the Hardware Manager) shows its commands, as Vivado does.
            for stage in DesignStage.allCases where model.isDesignOpen(stage) {
                if let item = FlowItem.allCases.first(where: { $0.designStage == stage }) { expanded.insert(item) }
            }
            if tabs.contains(.hardware) { expanded.insert(.openHardwareManager) }
        }
    }

    private func isActive(_ section: FlowSection) -> Bool {
        guard let stage = section.designStage else { return false }
        return model.activeDesign == stage && model.isDesignOpen(stage)
    }

    private func toggle(_ item: FlowItem) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(item) { expanded.remove(item) } else { expanded.insert(item) }
        }
    }
}

extension FlowItem {
    /// Whether the item opens up to more commands: the designs, and the Hardware Manager.
    var hasCommands: Bool { designStage != nil || self == .openHardwareManager }
}

private struct FlowRow: View {
    @EnvironmentObject private var model: AppModel
    let item: FlowItem
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var isEnabled: Bool {
        item.isAvailable && !(item.runKind != nil && model.isRunning) && !(item == .runLinter && (model.isRunning || model.isLinting))
    }

    /// Vivado renames "Open Synthesized Design" to "Synthesized Design" once it is open.
    private var title: String {
        if let stage = item.designStage, model.isDesignOpen(stage) { return stage.title }
        return item.title
    }

    var body: some View {
        HStack(spacing: 4) {
            if item.hasCommands {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isExpanded ? "Hide its commands" : "Show its commands")
            }
            Button { model.perform(item) } label: {
                HStack(spacing: 8) {
                    if !item.hasCommands {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(iconStyle)
                            .frame(width: 18)
                    }
                    Text(title)
                        .foregroundStyle(item.isAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary.opacity(0.75)))
                    Spacer(minLength: 4)
                    if item == .runLinter, model.isLinting {
                        ProgressView().controlSize(.mini)
                    } else if let state = model.status(of: item), state.status != .notStarted {
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
        }
        .help(item.unavailableReason ?? title)
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
        return item.runKind != nil || item == .runLinter ? AnyShapeStyle(Accent.remote) : AnyShapeStyle(.primary)
    }
}

/// A command under an open design or the Hardware Manager, indented as Vivado shows them.
private struct FlowSubRow: View {
    let title: String
    let symbol: String?
    let unavailable: String?
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    private var isEnabled: Bool { unavailable == nil && enabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.6))
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary.opacity(0.7)))
                Spacer(minLength: 4)
            }
            .padding(.leading, 22)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(unavailable ?? title)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering && isEnabled ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 8)
        )
        .onHover { hovering = $0 }
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
