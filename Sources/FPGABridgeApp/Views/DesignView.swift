import FPGABridgeCore
import SwiftUI

/// Vivado's Elaborated, Synthesized and Implemented Design: the netlist hierarchy, the I/O ports, utilization by
/// module, and the stage's reports. All of it comes from files the build wrote on the build machine.
struct DesignView: View {
    @EnvironmentObject private var model: AppModel
    let stage: DesignStage
    @State private var section = DebugHooks.designSection.flatMap { name in Section.allCases.first { $0.rawValue == name } } ?? Section.netlist

    enum Section: String, CaseIterable, Identifiable {
        case netlist = "Netlist"
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
                case .netlist: NetlistSection(design: design)
                case .ports: PortsSection(design: design)
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
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: row.node.isTop ? "cpu" : "square.on.square").foregroundStyle(Accent.source)
        }
    }
}

// MARK: Netlist

private struct NetlistSection: View {
    let design: DesignSnapshot
    @State private var selection: String? = ""      // "" is the top module
    @State private var collapsed: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(flatten(design.root, collapsed: collapsed)) { row in
                    HStack(spacing: 6) {
                        TreeLead(row: row, collapsed: $collapsed)
                        Text(row.node.name).fontWeight(row.node.isTop ? .semibold : .regular)
                        Text("(\(row.node.type))").foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(row.node.totals.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(row.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(width: 330)
            Divider()
            if let node = design.module(withPath: selection ?? "") {
                ModuleDetail(design: design, node: node).id(node.id)
            } else {
                Text("Select a module.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ModuleDetail: View {
    let design: DesignSnapshot
    let node: ModuleNode
    @State private var search = ""
    @State private var type = ""

    private var types: [String] { Array(Set(node.primitives.map(\.type))).sorted() }

    private var shown: [DesignCell] {
        node.primitives.filter { cell in
            (type.isEmpty || cell.type == type) && (search.isEmpty || cell.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(node.isTop ? design.info.top : node.id).font(.headline).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    InfoRow(label: "Module", value: node.type)
                    InfoRow(label: "Path", value: node.isTop ? "(top)" : node.id, monospaced: true)
                    InfoRow(label: "In this module", value: summary(node.counts))
                    InfoRow(label: "With sub-modules", value: summary(node.totals))
                }
            }
            .padding(14)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter cells", text: $search).textFieldStyle(.plain)
                Picker("Type", selection: $type) {
                    Text("All types").tag("")
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Text("\(shown.count) of \(node.primitives.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider()
            Table(shown) {
                TableColumn("Cell") { Text($0.localName).font(.callout.monospaced()).textSelection(.enabled) }
                TableColumn("Type") { Text($0.type).font(.callout.monospaced()) }.width(min: 80, ideal: 120, max: 200)
            }
            .overlay { if node.primitives.isEmpty { Text("No primitives directly in this module.").foregroundStyle(.secondary) } }
        }
    }

    private func summary(_ c: ResourceCounts) -> String {
        let parts = [("LUT", c.lut), ("FF", c.flipFlop), ("RAM", c.blockRAM), ("DSP", c.dsp), ("carry", c.carry), ("I/O buf", c.io), ("other", c.other)]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}

// MARK: I/O Ports

private struct PortsSection: View {
    let design: DesignSnapshot
    @State private var search = ""
    @State private var sort = Sort.name

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", pin = "Pin", standard = "I/O Standard"
        var id: String { rawValue }
    }

    private var shown: [DesignPort] {
        let filtered = design.ports.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.packagePin.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .pin: return filtered.sorted { ($0.packagePin, $0.name) < ($1.packagePin, $1.name) }
        case .standard: return filtered.sorted { ($0.ioStandard, $0.name) < ($1.ioStandard, $1.name) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by port or pin", text: $search).textFieldStyle(.plain)
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                let unplaced = design.ports.filter { !$0.isPlaced }.count
                if unplaced > 0 { Pill(text: "\(unplaced) without a pin", color: Accent.warning, symbol: "exclamationmark.triangle.fill") }
                Text("\(shown.count) of \(design.ports.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider()
            Table(shown) {
                TableColumn("Name") { Text($0.name).font(.callout.monospaced()).textSelection(.enabled) }
                TableColumn("Direction") { Text($0.direction) }.width(min: 70, ideal: 80, max: 100)
                TableColumn("Pin") { port in
                    Text(port.isPlaced ? port.packagePin : "—").font(.callout.monospaced()).foregroundStyle(port.isPlaced ? Color.primary : Accent.warning)
                }.width(min: 60, ideal: 70, max: 90)
                TableColumn("I/O Standard") { Text($0.ioStandard) }.width(min: 90, ideal: 110, max: 140)
                TableColumn("Slew") { Text($0.slew) }.width(min: 60, ideal: 70, max: 90)
                TableColumn("Drive") { Text($0.drive) }.width(min: 50, ideal: 60, max: 80)
                TableColumn("Pull") { Text($0.pullType) }.width(min: 60, ideal: 80, max: 100)
            }
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
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
