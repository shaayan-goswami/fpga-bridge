import FPGABridgeCore
import SwiftUI

/// Vivado's Sources window (Hierarchy / IP Sources / Libraries / Compile Order) with Source File Properties below.
struct SourcesPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.hierarchy
    @State private var propertiesHeight: CGFloat = 220

    enum Tab: String, CaseIterable, Identifiable {
        case hierarchy = "Hierarchy"
        case ipSources = "IP Sources"
        case libraries = "Libraries"
        case compileOrder = "Compile Order"
        var id: String { rawValue }
    }

    var body: some View {
        VerticalPaneSplit(height: $propertiesHeight, range: 160...460, minTop: 240) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    if let design = model.activeSnapshot {
                        // With a design open, Vivado shows its Netlist window next to Sources.
                        windowTab(.sources)
                        windowTab(.netlist, detail: design.stage.title)
                    } else {
                        Text("Sources").font(.headline)
                    }
                    Spacer()
                    if showsNetlist == false {
                        Button { model.showAddSources = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Add Sources")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

                if let design = model.activeSnapshot, showsNetlist {
                    Divider()
                    NetlistWindow(design: design).id(design.stage)
                } else {
                    sourcesWindow
                }
            }
        } bottom: {
            PropertiesPanel()
        }
        .onChange(of: model.selectedSourceID) { _, id in
            model.propertiesShowsDesign = false
            if let path = model.node(withID: id)?.path {
                if Project.isBlockDesign(path) { model.openBlockDesign(path) } else { model.openFile(path) }
            }
        }
    }

    private var showsNetlist: Bool { model.sidePane == .netlist && model.activeSnapshot != nil }

    private func windowTab(_ pane: SidePane, detail: String? = nil) -> some View {
        let selected = model.sidePane == pane
        return Button { model.sidePane = pane } label: {
            VStack(spacing: 4) {
                Text(pane.rawValue)
                    .font(.headline)
                    .foregroundStyle(selected ? .primary : .secondary)
                Capsule().fill(selected ? Color.primary : .clear).frame(height: 2)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(detail.map { "\(pane.rawValue) of the \($0)" } ?? pane.rawValue)
    }

    private var sourcesWindow: some View {
        VStack(spacing: 0) {
            // A compact tab strip: a segmented control can't shrink to fit four labels in a narrow pane.
            HStack(spacing: 14) {
                ForEach(Tab.allCases) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 4) {
                            Text(item.rawValue)
                                .font(.callout.weight(tab == item ? .semibold : .regular))
                                .foregroundStyle(tab == item ? .primary : .secondary)
                                .fixedSize()
                            Capsule()
                                .fill(tab == item ? Color.primary : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .hierarchy:
            List(selection: $model.selectedSourceID) {
                ForEach(model.sourceTree) { SourceOutlineRow(node: $0) }
            }
            .listStyle(.inset)
            .surfaceBackground()
        case .compileOrder:
            List(selection: $model.selectedSourceID) {
                ForEach(compileOrder, id: \.self) { path in
                    Label((path as NSString).lastPathComponent, systemImage: "doc.text").tag("file:\(path)")
                }
            }
            .listStyle(.inset)
            .surfaceBackground()
        case .ipSources:
            IPSourcesList()
        case .libraries:
            List {
                DisclosureGroup("xil_defaultlib") {
                    ForEach(compileOrder, id: \.self) { Text(($0 as NSString).lastPathComponent) }
                }
            }
            .listStyle(.inset)
            .surfaceBackground()
        }
    }

    private var compileOrder: [String] {
        guard let project = model.project, let url = model.projectURL else { return [] }
        return (try? project.resolveSources(in: url)) ?? []
    }
}

private struct SourceOutlineRow: View {
    let node: SourceNode
    @State private var expanded = true

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { SourceOutlineRow(node: $0) }
            } label: {
                SourceLabel(node: node)
            }
            .tag(node.id)
        } else {
            SourceLabel(node: node).tag(node.id)
        }
    }
}

private struct SourceLabel: View {
    let node: SourceNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.symbol)
                .foregroundStyle(symbolColor)
                .frame(width: 16)
            Text(node.title).fontWeight(node.isTop ? .semibold : .regular)
            if let detail = node.detail {
                Text(detail).foregroundStyle(.secondary)
            }
            if node.isTop {
                Pill(text: "Top", color: Accent.source)
            }
        }
        .lineLimit(1)
    }

    private var symbolColor: Color {
        guard node.symbol != "folder", let path = node.path else { return .secondary }
        if path.lowercased().hasSuffix(".xdc") { return Accent.constraint }
        if path.contains("/sim_1/") { return Accent.simulation }
        return Accent.source
    }
}

/// Vivado's "Source File Properties".
private struct PropertiesPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.propertiesShowsDesign, let design = model.activeSnapshot {
            if let ref = model.primarySelection {
                DesignPropertiesWindow(design: design, ref: ref).id(design.stage)
            } else {
                VStack(spacing: 0) {
                    HStack { Text("Properties").font(.headline); Spacer() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Divider()
                    Text("Select an object to see properties")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            sourceProperties
        }
    }

    private var sourceProperties: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Source File Properties").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let node = model.node(withID: model.selectedSourceID), let path = node.path {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                        InfoRow(label: "Name", value: (path as NSString).lastPathComponent)
                        InfoRow(label: "Enabled", value: "Yes")
                        InfoRow(label: "Location", value: (path as NSString).deletingLastPathComponent, monospaced: true)
                        InfoRow(label: "Type", value: fileType(path))
                        InfoRow(label: "Library", value: "xil_defaultlib")
                        InfoRow(label: "Size", value: size(path))
                        InfoRow(label: "Used In", value: usedIn(path))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a source file to see its properties.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func fileType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "v", "vh": "Verilog"
        case "sv", "svh": "SystemVerilog"
        case "vhd", "vhdl": "VHDL"
        case "xdc": "XDC"
        case "bd": "Block Designs"
        default: "Text"
        }
    }

    private func size(_ path: String) -> String {
        guard let url = model.projectURL?.appendingPathComponent(path),
              let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func usedIn(_ path: String) -> String {
        if path.contains("/sim_1/") { return "Simulation" }
        if path.hasSuffix(".xdc") { return "Synthesis, Implementation" }
        return "Synthesis, Simulation"
    }
}
