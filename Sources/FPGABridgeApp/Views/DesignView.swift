import FPGABridgeCore
import SwiftUI

/// Vivado's Elaborated, Synthesized and Implemented Design: the netlist hierarchy, the I/O ports, utilization by
/// module, and the stage's reports. All of it comes from files the build wrote on the build machine.
struct DesignView: View {
    @EnvironmentObject private var model: AppModel
    let stage: DesignStage
    @State private var section = DebugHooks.designSection.flatMap { name in Section.allCases.first { $0.rawValue == name } } ?? Section.ports

    /// The netlist itself is in the Netlist window and the Schematic; this tab holds the design's tables and reports.
    enum Section: String, CaseIterable, Identifiable {
        case ports = "I/O Ports"
        case utilization = "Utilization"
        case reports = "Reports"
        var id: String { rawValue }
    }

    var body: some View {
        if let design = model.designs[stage] {
            VStack(spacing: 0) {
                header(design)
                Divider()
                switch section {
                case .ports: IOPortsTable(chip: model.chipViews, stage: stage)
                case .utilization: UtilizationSection(design: design)
                case .reports: StageReports(stage: stage)
                }
            }
            .background(Theme.surface)
        } else {
            ContentUnavailableView {
                Label(stage.title, systemImage: "square.stack.3d.up")
            } description: {
                Text(model.isRunning ? "Waiting for the build to finish…" : "Run a build to produce this design.")
            } actions: {
                if !model.isRunning { Button("Run \(stage == .impl ? "Implementation" : "Synthesis")") { model.openDesign(stage) } }
            }
            .background(Theme.surface)
        }
    }

    private func header(_ design: DesignSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title).font(.callout.weight(.semibold))
                Text("\(design.info.part) · top \(design.info.top) · Vivado \(design.info.vivado)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Pill(text: "\(design.cells.count) cells", color: .secondary)
            Pill(text: "\(design.ports.count) ports", color: .secondary)
            Button { model.openSchematic(stage) } label: { Label("Schematic", systemImage: "point.3.connected.trianglepath.dotted") }
                .help("Open the design's schematic")
            Button { model.openPackage(stage) } label: { Label("Package", systemImage: "circle.grid.3x3") }
                .help("Open the Package window: pins, banks and I/O planning")
            if AppModel.hasDeviceView(stage) {
                Button { model.openDevice(stage) } label: { Label("Device", systemImage: "cpu") }
                    .help("Open the Device window: the die and where cells are placed")
            }
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

// MARK: Module tree

/// A module with how deep it is, for drawing the tree as flat rows. A flat list lets every module start expanded,
/// which `OutlineGroup` can't do.
private struct FlatModule: Identifiable {
    let node: ModuleNode
    let depth: Int
    var id: String { node.id }
}

private func flatten(_ node: ModuleNode, collapsed: Set<String>, depth: Int = 0) -> [FlatModule] {
    [FlatModule(node: node, depth: depth)]
        + (collapsed.contains(node.id) ? [] : (node.children ?? []).flatMap { flatten($0, collapsed: collapsed, depth: depth + 1) })
}

/// The indent and expand arrow in front of a module's name.
private struct TreeLead: View {
    let row: FlatModule
    @Binding var collapsed: Set<String>

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            if row.node.children != nil {
                Button {
                    if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(row.id) ? 0 : 90))
                        .frame(width: 12)
                }
                .buttonStyle(.pressable)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: row.node.isTop ? "cpu" : "square.on.square").foregroundStyle(Accent.source)
        }
    }
}

// MARK: Utilization

private struct UtilizationSection: View {
    let design: DesignSnapshot
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Instance").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.0) { Text($0.0).frame(width: 64, alignment: .trailing) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            Divider()
            List {
                ForEach(flatten(design.root, collapsed: collapsed)) { row in
                    HStack(spacing: 0) {
                        HStack(spacing: 6) {
                            TreeLead(row: row, collapsed: $collapsed)
                            Text(row.node.name).fontWeight(row.node.isTop ? .semibold : .regular)
                            Text("(\(row.node.type))").foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(columns, id: \.0) { Text("\($0.1(row.node.totals))").monospacedDigit().frame(width: 64, alignment: .trailing) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            Divider()
            Text("Counts of cells in the netlist, including sub-modules. Vivado's own utilization report counts physical sites, so LUT numbers can be lower where small LUTs share one (LUT combining).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var columns: [(String, (ResourceCounts) -> Int)] {
        [("LUT cells", { $0.lut }), ("FF", { $0.flipFlop }), ("RAM", { $0.blockRAM }), ("DSP", { $0.dsp }),
         ("Carry", { $0.carry }), ("I/O buf", { $0.io }), ("Other", { $0.other }), ("Total", { $0.total })]
    }
}

// MARK: Reports

private struct StageReports: View {
    @EnvironmentObject private var model: AppModel
    let stage: DesignStage

    private var entries: [ReportEntry] {
        switch stage {
        case .rtl: []
        case .synth: model.reports.filter { $0.run == .synthesis }
        case .impl: model.reports.filter { $0.run == .implementation }
        }
    }

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(stage == .rtl ? "No reports at elaboration" : "No reports yet", systemImage: "doc.plaintext",
                                   description: Text(stage == .rtl ? "Vivado writes reports from synthesis on." : "Run a build to produce them."))
        } else {
            List(entries) { entry in
                Button { model.openReport(entry.id) } label: {
                    HStack {
                        Image(systemName: "doc.plaintext").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                            Text(entry.fileName).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
