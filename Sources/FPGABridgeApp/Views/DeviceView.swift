import AppKit
import FPGABridgeCore
import SwiftUI

/// Vivado's Device window: the die drawn from the part data (CLB, block RAM, DSP, I/O and clocking columns, with the
/// clock regions), and, in the implemented design, the sites its cells are placed on (their saved `LOC`). Selecting
/// here selects the cells in the Netlist, Schematic and Properties, and selecting them there shows them here.
struct DeviceView: View {
    @EnvironmentObject private var model: AppModel
    let stage: DesignStage

    var body: some View {
        DeviceWindow(chip: model.chipViews, stage: stage)
    }
}

extension TileCategory {
    var color: Color {
        switch self {
        case .clbL: Color(red: 0.55, green: 0.62, blue: 0.75)
        case .clbM: Color(red: 0.48, green: 0.56, blue: 0.80)
        case .bram: Color(red: 0.75, green: 0.45, blue: 0.75)
        case .dsp: Color(red: 0.35, green: 0.68, blue: 0.55)
        case .io: Color(red: 0.90, green: 0.62, blue: 0.25)
        case .ioLogic: Color(red: 0.85, green: 0.72, blue: 0.45)
        case .clockManagement: Color(red: 0.30, green: 0.65, blue: 0.85)
        case .clock: Color(red: 0.20, green: 0.55, blue: 0.95)
        case .transceiver: Color(red: 0.10, green: 0.62, blue: 0.62)
        case .config: Color(red: 0.60, green: 0.35, blue: 0.80)
        case .pcie: Color(red: 0.85, green: 0.40, blue: 0.40)
        case .interconnect: Color(white: 0.55)
        case .empty: Color(white: 0.5)
        }
    }
}

private struct DeviceWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var chip: ChipViews
    let stage: DesignStage

    @State private var viewport = CanvasViewport()
    @State private var needsFit = true
    @State private var hover: String?
    @State private var showRegions = true

    var body: some View {
        let partName = model.part(of: stage)
        if model.designs[stage] == nil {
            ContentUnavailableView("No \(stage.title)", systemImage: "cpu", description: Text("Run a build to produce it."))
        } else if let data = chip.data(for: partName) {
            content(data)
        } else {
            PartDataMissing(chip: chip, part: partName, window: "Device")
        }
    }

    private func content(_ data: PartData) -> some View {
        let die = chip.die(for: data)
        let placement = model.designs[stage].map { chip.cellsBySite(in: $0) } ?? [:]
        // I/O ports sit on the I/O buffer behind their pin.
        let portSites = Dictionary(model.plannedPorts(stage).compactMap { port -> (String, String)? in
            guard let site = data.pin(named: port.pin)?.site, !site.isEmpty else { return nil }
            return (site, port.name)
        }, uniquingKeysWith: { a, _ in a })
        return VStack(spacing: 0) {
            toolbar(data, die: die, placement: placement)
            Divider()
            canvas(data, die: die, placement: placement, portSites: portSites)
        }
        .background(Theme.surface)
    }

    private func toolbar(_ data: PartData, die: DieLayout, placement: [String: [String]]) -> some View {
        HStack(spacing: 10) {
            Group {
                Button { needsFit = false; viewport.zoom(by: 1.4, about: viewport.center) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
                Button { needsFit = false; viewport.zoom(by: 1 / 1.4, about: viewport.center) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                Button { needsFit = true; fit(die) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom Fit")
                Button { fitSelection(die, placement: placement) } label: { Image(systemName: "scope") }.help("Zoom to Selection")
                Toggle(isOn: $showRegions) { Image(systemName: "square.grid.2x2") }
                    .toggleStyle(.button)
                    .help("Show clock regions")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 14)
            Text("\(data.device) · \(data.regions.count) clock regions").font(.caption).foregroundStyle(.secondary)
            if stage == .impl {
                Button("\(placement.values.reduce(0) { $0 + $1.count }) placed cells") {
                    model.select(placement.values.flatMap { $0 }.sorted().map { .cell($0) })
                }
                .buttonStyle(.link)
                .font(.callout)
            } else {
                Text("Placement appears once the design is implemented").font(.caption).foregroundStyle(.secondary)
            }
            if chip.backend.isDemo { Pill(text: "Demo data", color: Accent.warning, symbol: "exclamationmark.triangle.fill") }
            Spacer()
            Button { model.openPackage(stage) } label: { Label("Package", systemImage: "circle.grid.3x3") }
                .help("Open the Package window")
            Text("\(Int(viewport.scale * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func fit(_ die: DieLayout) {
        viewport.fit(CGRect(origin: .zero, size: die.size).insetBy(dx: -10, dy: -10), maxScale: 6)
    }

    private func selectedSites(_ placement: [String: [String]]) -> Set<String> {
        let cells = Set(model.designSelection.filter { $0.kind == .cell }.map(\.name))
        guard !cells.isEmpty else { return [] }
        return Set(placement.filter { $0.value.contains(where: cells.contains) }.keys)
    }

    private func fitSelection(_ die: DieLayout, placement: [String: [String]]) {
        var rect = CGRect.null
        for site in selectedSites(placement) { if let f = die.frame(ofSite: site) { rect = rect.union(f) } }
        if !rect.isNull { viewport.fit(rect.insetBy(dx: -40, dy: -40), maxScale: 12); needsFit = false }
    }

    private func canvas(_ data: PartData, die: DieLayout, placement: [String: [String]], portSites: [String: String]) -> some View {
        let selected = selectedSites(placement)
        let selectedPorts = Set(model.designSelection.filter { $0.kind == .port }.map(\.name))
        let dark = scheme == .dark
        return GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, _ in
                    ctx.translateBy(x: -viewport.offset.x, y: -viewport.offset.y)
                    ctx.scaleBy(x: viewport.scale, y: viewport.scale)
                    ctx.fill(Path(CGRect(origin: .zero, size: die.size)), with: .color(dark ? Color(white: 0.08) : Color(white: 0.96)))
                    for block in die.blocks where block.category != .empty {
                        let opacity = block.category == .interconnect ? 0.12 : (dark ? 0.45 : 0.35)
                        ctx.fill(Path(block.frame.insetBy(dx: 0.4, dy: 0.4)), with: .color(block.category.color.opacity(opacity)))
                    }
                    for (site, _) in placement {
                        guard let f = die.frame(ofSite: site) else { continue }
                        ctx.fill(Path(f.insetBy(dx: 0.6, dy: 0.6)), with: .color(selected.contains(site) ? ChipColors.selection : ChipColors.placed))
                    }
                    for (site, port) in portSites {
                        guard let f = die.frame(ofSite: site) else { continue }
                        let on = selectedPorts.contains(port)
                        ctx.stroke(Path(f.insetBy(dx: 0.8, dy: 0.8)), with: .color(on ? ChipColors.selection : ChipColors.placed), lineWidth: on ? 1.5 : 1)
                    }
                    for site in selected {
                        guard let f = die.frame(ofSite: site) else { continue }
                        ctx.stroke(Path(f.insetBy(dx: -1.5, dy: -1.5)), with: .color(ChipColors.selection), lineWidth: 1.5 / max(viewport.scale, 0.5))
                    }
                    if showRegions {
                        for region in data.regions {
                            let f = die.frame(of: region)
                            ctx.stroke(Path(f), with: .color(Accent.active.opacity(0.7)), lineWidth: 1.5 / max(viewport.scale, 0.3))
                            ctx.draw(Text(region.name).font(.system(size: 9 / max(viewport.scale, 0.3) * 0.9, weight: .semibold))
                                .foregroundColor(Accent.active), at: CGPoint(x: f.minX + 4, y: f.minY + 4), anchor: .topLeading)
                        }
                    }
                }
                ChipCanvasInteraction(
                    onPan: { viewport.pan($0); needsFit = false },
                    onZoom: { viewport.zoom(by: $0, about: $1, limits: 0.1...40); needsFit = false },
                    onClick: { at, extend, _ in click(at, extend: extend, data: data, die: die, placement: placement, portSites: portSites) },
                    onHover: { at in hover = at.flatMap { describe($0, data: data, die: die, placement: placement, portSites: portSites) } },
                    menu: { _ in [ChipMenuItem(title: "Zoom Fit") { fit(die) }, ChipMenuItem(title: "Schematic") { model.schematicOfSelection() }] })
                if let hover { CanvasCaption(text: hover) }
            }
            .clipped()
            .onAppear { viewport.size = geometry.size; if needsFit { fit(die) } }
            .onChange(of: geometry.size) { _, size in
                viewport.size = size
                if needsFit { fit(die) }
            }
        }
    }

    private func click(_ at: CGPoint, extend: Bool, data: PartData, die: DieLayout, placement: [String: [String]], portSites: [String: String]) {
        let p = viewport.toModel(at)
        let sites = die.sites(at: p, in: data)
        let site = sites.first { die.frame(ofSite: $0)?.contains(p) ?? false }
        if let site, let cells = placement[site], !cells.isEmpty {
            if extend { for cell in cells { model.select(.cell(cell), extend: true) } } else { model.select(cells.sorted().map { .cell($0) }) }
        } else if let site, let port = portSites[site] {
            model.select(.port(port), extend: extend)
        } else if !extend {
            model.select(nil)
        }
    }

    private func describe(_ at: CGPoint, data: PartData, die: DieLayout, placement: [String: [String]], portSites: [String: String]) -> String? {
        let p = viewport.toModel(at)
        guard let block = die.block(at: p) else { return nil }
        var text = "\(block.type) (\(block.category.title))"
        if let site = die.sites(at: p, in: data).first(where: { die.frame(ofSite: $0)?.contains(p) ?? false }) {
            text = site + " · " + text
            if let cells = placement[site] {
                text += " · \(cells.count) cell\(cells.count == 1 ? "" : "s"): \(cells.sorted().prefix(3).joined(separator: ", "))\(cells.count > 3 ? "…" : "")"
            }
            if let port = portSites[site] { text += " · port \(port)" }
        }
        return text
    }
}
