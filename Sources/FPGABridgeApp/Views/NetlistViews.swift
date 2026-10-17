import AppKit
import FPGABridgeCore
import SwiftUI

// MARK: Icons

/// The small icons of Vivado's Netlist window, redrawn: an orange square for a primitive, an outlined block with an
/// I-beam for a module instance, a green step for a net (two for a bus), and an orange N for the top.
struct NetlistIcon: View {
    enum Kind {
        case top, module, leaf, net, bus, folder, port, pin
    }

    let kind: Kind

    static let leafColor = Color(red: 0.96, green: 0.58, blue: 0.16)
    static let netColor = Color(red: 0.36, green: 0.72, blue: 0.29)

    var body: some View {
        Group {
            switch kind {
            case .top:
                Text("N").font(.system(size: 12, weight: .heavy)).foregroundStyle(Self.leafColor)
            case .module:
                ZStack {
                    RoundedRectangle(cornerRadius: 1.5).stroke(Self.leafColor, lineWidth: 1.2).frame(width: 11, height: 12)
                    Path { p in
                        p.move(to: CGPoint(x: 3.5, y: 3)); p.addLine(to: CGPoint(x: 7.5, y: 3))
                        p.move(to: CGPoint(x: 5.5, y: 3)); p.addLine(to: CGPoint(x: 5.5, y: 9))
                        p.move(to: CGPoint(x: 3.5, y: 9)); p.addLine(to: CGPoint(x: 7.5, y: 9))
                    }
                    .stroke(Self.leafColor, lineWidth: 1.3)
                    .frame(width: 11, height: 12)
                }
            case .leaf:
                RoundedRectangle(cornerRadius: 1).fill(Self.leafColor).frame(width: 9, height: 9)
            case .net, .bus:
                ZStack {
                    if kind == .bus { NetStep().stroke(Self.netColor.opacity(0.55), lineWidth: 1.2).offset(x: -2.5, y: 2) }
                    NetStep().stroke(Self.netColor, lineWidth: 1.4)
                }
                .frame(width: 12, height: 11)
            case .folder:
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
            case .port:
                PortShape().stroke(Color.secondary, lineWidth: 1.2).frame(width: 12, height: 9)
            case .pin:
                Circle().stroke(Color.secondary, lineWidth: 1.2).frame(width: 7, height: 7)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// A rising step, Vivado's net symbol.
private struct NetStep: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - 1))
        p.addLine(to: CGPoint(x: r.midX - 1, y: r.maxY - 1))
        p.addLine(to: CGPoint(x: r.midX - 1, y: r.minY + 1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 1))
        return p
    }
}

/// The pentagon Vivado draws for an I/O port.
struct PortShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.height / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - r.height / 2, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

extension NetlistOutline.Row {
    var icon: NetlistIcon.Kind {
        switch kind {
        case .module(let path): path.isEmpty ? .top : .module
        case .netsFolder, .leafFolder: .folder
        case .bus: .bus
        case .net: .net
        case .cell: .leaf
        }
    }
}

// MARK: Netlist window

/// Vivado's Netlist window: the open design's hierarchy with each module's nets and leaf cells. Selecting here
/// selects in every design window, and selecting elsewhere opens the tree to show it.
struct NetlistWindow: View {
    @EnvironmentObject private var model: AppModel
    let design: DesignSnapshot
    @State private var expanded: Set<String> = []
    @State private var selection: Set<String> = []

    private var outline: NetlistOutline { NetlistOutline(design: design) }

    var body: some View {
        let outline = outline
        let rows = outline.rows(expanded: expanded)
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(rows) { row in
                        NetlistRowView(row: row, isOpen: expanded.contains(row.id)) { toggle(row) }
                            .tag(row.id)
                            .id(row.id)
                            .contextMenu { menu(for: row) }
                    }
                }
                .listStyle(.inset)
                .surfaceBackground()
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    // Double-click: open a folder or module, or show a cell's HDL.
                    guard let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
                    if row.hasChildren { toggle(row) } else if case .cell(let name) = row.kind, let cell = design.cell(named: name), model.canGoToSource(cell) {
                        model.goToSource(cell)
                    }
                }
                .onChange(of: selection) { _, ids in
                    let refs = rows.filter { ids.contains($0.id) }.compactMap(\.object)
                    if !refs.isEmpty, Set(refs) != Set(model.designSelection) { model.select(refs) }
                }
                .onChange(of: model.designSelection) { _, refs in reveal(refs, outline: outline, proxy: proxy) }
                .onAppear { reveal(model.designSelection, outline: outline, proxy: proxy) }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { expanded = [] } label: { Image(systemName: "chevron.up.chevron.down") }
                .help("Collapse All")
            Spacer()
            if !design.hasConnectivity {
                Label("Nets need a newer build", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This build didn't save how cells connect. Run synthesis again to see nets and the schematic.")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    @ViewBuilder private func menu(for row: NetlistOutline.Row) -> some View {
        if let ref = row.object {
            Button("\(ref.kind.title) Properties") { model.select(ref) }
        }
        if case .cell(let name) = row.kind, let cell = design.cell(named: name) {
            Button("Go To Source") { model.goToSource(cell) }.disabled(!model.canGoToSource(cell))
        }
        if case .module(let path) = row.kind, !path.isEmpty, let cell = design.cell(named: path) {
            Button("Go To Source") { model.goToSource(cell) }.disabled(!model.canGoToSource(cell))
        }
        if let ref = row.object {
            Divider()
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref.name, forType: .string)
            }
        }
    }

    private func toggle(_ row: NetlistOutline.Row) {
        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
    }

    /// Opens the tree down to what is selected elsewhere, selects its rows, and scrolls to the last one.
    private func reveal(_ refs: [DesignObjectRef], outline: NetlistOutline, proxy: ScrollViewProxy) {
        let wanted = Set(refs.filter { design.contains($0) && $0.kind != .port }.map { ref -> String in
            switch ref.kind {
            case .net: NetlistOutline.id(.net(ref.name))
            case .pin: NetlistOutline.id(.cell(design.pins[ref.name]?.cellName ?? ""))
            default:
                design.cell(named: ref.name)?.isPrimitive == false ? NetlistOutline.id(.module(path: ref.name)) : NetlistOutline.id(.cell(ref.name))
            }
        })
        guard wanted != selection else { return }
        for ref in refs where design.contains(ref) { expanded.formUnion(outline.idsToReveal(ref)) }
        selection = wanted
        if let last = refs.last, let id = wanted.first(where: { $0.hasSuffix(last.name) }) ?? wanted.first {
            DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

private struct NetlistRowView: View {
    let row: NetlistOutline.Row
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if row.hasChildren && row.depth > 0 {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            NetlistIcon(kind: row.icon)
            Text(row.title).fontWeight(row.depth == 0 ? .semibold : .regular).lineLimit(1)
            if !row.detail.isEmpty { Text(row.detail).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

extension DesignObjectKind {
    var title: String {
        switch self {
        case .cell: "Cell"
        case .net: "Net"
        case .port: "I/O Port"
        case .pin: "Pin"
        }
    }

    var icon: NetlistIcon.Kind {
        switch self {
        case .cell: .leaf
        case .net: .net
        case .port: .port
        case .pin: .pin
        }
    }
}

// MARK: Properties window

/// Vivado's Properties window for a design object: "Cell Properties", "Net Properties" and so on, with General,
/// Properties and connection views, back and forward through what was selected, and links that select other objects.
struct DesignPropertiesWindow: View {
    @EnvironmentObject private var model: AppModel
    let design: DesignSnapshot
    let ref: DesignObjectRef
    @State private var view = PropertyView.general
    @State private var history: [DesignObjectRef] = []
    @State private var historyIndex = -1
    @State private var search = ""

    enum PropertyView: String, CaseIterable, Identifiable {
        case general = "General"
        case properties = "Properties"
        case nets = "Nets"
        case cellPins = "Cell Pins"
        case connectivity = "Connectivity"
        var id: String { rawValue }
    }

    private var views: [PropertyView] {
        switch ref.kind {
        case .cell: [.general, .properties, .nets, .cellPins]
        case .net: [.general, .properties, .cellPins, .connectivity]
        case .port: [.general, .properties, .nets]
        case .pin: [.general, .properties]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(ref.kind.title) Properties").font(.headline)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "arrow.left") }
                    .disabled(historyIndex <= 0)
                    .help("Previous Object")
                Button { step(1) } label: { Image(systemName: "arrow.right") }
                    .disabled(historyIndex >= history.count - 1)
                    .help("Next Object")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            HStack(spacing: 6) {
                NetlistIcon(kind: ref.kind.icon)
                Text(ref.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider()
            Group {
                if !design.contains(ref) {
                    Text("Not in the \(design.stage.title.lowercased()).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch view {
                    case .general: general
                    case .properties: propertyTable
                    case .nets: netsList
                    case .cellPins: cellPins
                    case .connectivity: connectivity
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 14) {
                ForEach(views) { item in
                    Button { view = item } label: {
                        Text(item.rawValue)
                            .font(.caption.weight(view == item ? .semibold : .regular))
                            .foregroundStyle(view == item ? .primary : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(view == item ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .onAppear { record(ref) }
        .onChange(of: ref) { _, new in
            record(new)
            if !views.contains(view) { view = .general }
        }
    }

    // MARK: History

    private func record(_ new: DesignObjectRef) {
        if historyIndex >= 0, historyIndex < history.count, history[historyIndex] == new { return }
        history = Array(history.prefix(historyIndex + 1)) + [new]
        historyIndex = history.count - 1
    }

    private func step(_ delta: Int) {
        let target = historyIndex + delta
        guard history.indices.contains(target) else { return }
        historyIndex = target
        model.select(history[target])
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                switch ref.kind {
                case .cell: cellGeneral
                case .net: netGeneral
                case .port: portGeneral
                case .pin: pinGeneral
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func value(_ name: String) -> String? {
        design.properties(of: ref.kind, name: ref.name).first { $0.name == name }?.value
    }

    @ViewBuilder private var cellGeneral: some View {
        if let cell = design.cell(named: ref.name) {
            InfoRow(label: "Name", value: cell.localName)
            InfoRow(label: "Cell", value: cell.type, monospaced: true)
            GridRow {
                Text("Parent").foregroundStyle(.secondary)
                if cell.parentPath.isEmpty { Text(design.info.top) } else { ObjectLink(ref: .cell(cell.parentPath)) }
            }
            InfoRow(label: "Kind", value: cell.isPrimitive ? "Primitive" : "Hierarchical")
            if let type = value("PRIMITIVE_TYPE") { InfoRow(label: "Primitive type", value: type, monospaced: true) }
            if let loc = value("LOC") { InfoRow(label: "Site", value: loc, monospaced: true) }
            if let bel = value("BEL") { InfoRow(label: "BEL", value: bel, monospaced: true) }
            if let status = value("STATUS") { InfoRow(label: "Status", value: status.capitalized) }
            if let file = cell.sourceFile {
                GridRow {
                    Text("Source").foregroundStyle(.secondary)
                    if model.canGoToSource(cell) {
                        Button("\(file):\(cell.sourceLine ?? 0)") { model.goToSource(cell) }
                            .buttonStyle(.link)
                            .help("Go To Source")
                    } else {
                        Text("\(file):\(cell.sourceLine ?? 0)").font(.callout.monospaced())
                    }
                }
            }
        }
    }

    @ViewBuilder private var netGeneral: some View {
        if let net = design.net(named: ref.name) {
            let reach = design.flatConnectivity(of: net.name)
            let drivers = reach.filter { end in end.isPort ? design.port(named: end.name)?.direction == "IN" : design.pins[end.name]?.direction == "OUT" }
            InfoRow(label: "Name", value: net.localName)
            InfoRow(label: "Type", value: net.type)
            GridRow {
                Text("Parent").foregroundStyle(.secondary)
                if net.parentPath.isEmpty { Text(design.info.top) } else { ObjectLink(ref: .cell(net.parentPath)) }
            }
            if net.busName != net.localName { InfoRow(label: "Bus", value: net.busName, monospaced: true) }
            GridRow {
                Text("Driver").foregroundStyle(.secondary)
                if drivers.isEmpty { Text("None").foregroundStyle(Accent.warning) } else {
                    VStack(alignment: .leading, spacing: 2) { ForEach(drivers, id: \.self) { ObjectLink(endpoint: $0) } }
                }
            }
            InfoRow(label: "Fanout", value: "\(reach.count - drivers.count)")
        }
    }

    @ViewBuilder private var portGeneral: some View {
        if let port = design.port(named: ref.name) {
            InfoRow(label: "Name", value: port.name)
            InfoRow(label: "Direction", value: port.direction)
            InfoRow(label: "Package pin", value: port.isPlaced ? port.packagePin : "Not assigned", monospaced: port.isPlaced)
            if let bank = value("IOBANK") { InfoRow(label: "Bank", value: bank) }
            InfoRow(label: "I/O standard", value: port.ioStandard)
            if !port.slew.isEmpty { InfoRow(label: "Slew", value: port.slew) }
            if !port.drive.isEmpty { InfoRow(label: "Drive", value: port.drive) }
            if !port.pullType.isEmpty { InfoRow(label: "Pull", value: port.pullType) }
            if let net = design.net(ofPort: port.name) {
                GridRow { Text("Net").foregroundStyle(.secondary); ObjectLink(ref: .net(net)) }
            }
        }
    }

    @ViewBuilder private var pinGeneral: some View {
        if let pin = design.pins[ref.name] {
            InfoRow(label: "Name", value: pin.pinName)
            InfoRow(label: "Direction", value: pin.direction)
            InfoRow(label: "Clock", value: pin.isClock ? "Yes" : "No")
            GridRow { Text("Cell").foregroundStyle(.secondary); ObjectLink(ref: .cell(pin.cellName)) }
            if let net = design.net(ofPin: pin.name) {
                GridRow { Text("Net").foregroundStyle(.secondary); ObjectLink(ref: .net(net)) }
            } else {
                InfoRow(label: "Net", value: "Not connected")
            }
        }
    }

    // MARK: Properties

    private var allProperties: [DesignProperty] {
        if ref.kind == .pin, let pin = design.pins[ref.name] {
            return [DesignProperty(name: "CLASS", value: "pin"), DesignProperty(name: "DIRECTION", value: pin.direction),
                    DesignProperty(name: "IS_CLOCK", value: pin.isClock ? "1" : "0"), DesignProperty(name: "NAME", value: pin.name),
                    DesignProperty(name: "PARENT_CELL", value: pin.cellName), DesignProperty(name: "REF_PIN_NAME", value: pin.pinName)]
        }
        return design.properties(of: ref.kind, name: ref.name)
    }

    private var propertyTable: some View {
        let shown = allProperties.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search properties", text: $search).textFieldStyle(.plain)
                Text("\(shown.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            Divider()
            if allProperties.isEmpty {
                Text(design.info.leftOut.contains("properties") ? "Properties weren't saved: this design is very large." : "No properties saved for this object.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(shown) {
                    TableColumn("Name") { Text($0.name).font(.caption.monospaced()) }.width(min: 90, ideal: 150)
                    TableColumn("Value") { Text($0.value).font(.caption.monospaced()).textSelection(.enabled) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Copy Properties") {
                        let lines = shown.filter { ids.isEmpty || ids.contains($0.id) }.map { "\($0.name)\t\($0.value)" }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    }
                }
            }
        }
    }

    // MARK: Connections

    /// The nets on a cell's pins, or the net a port is on.
    private var netsList: some View {
        let names: [String] = ref.kind == .port
            ? design.net(ofPort: ref.name).map { [$0] } ?? []
            : Array(Set(design.pins(of: ref.name).compactMap { design.net(ofPin: $0.name) })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return list(names.map { .net($0) }, empty: "No nets.")
    }

    private var cellPins: some View {
        if ref.kind == .net {
            let ends = design.net(named: ref.name)?.endpoints.filter { !$0.isPort || design.net(named: ref.name)?.parentPath.isEmpty == true } ?? []
            return AnyView(endpointTable(ends))
        }
        return AnyView(pinTable(design.pins(of: ref.name)))
    }

    private var connectivity: some View { endpointTable(design.flatConnectivity(of: ref.name)) }

    private func list(_ refs: [DesignObjectRef], empty: String) -> some View {
        Group {
            if refs.isEmpty { Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) } else {
                List(refs, id: \.self) { ObjectLink(ref: $0) }.listStyle(.inset).surfaceBackground()
            }
        }
    }

    private struct PinRow: Identifiable {
        let id: String
        let ref: DesignObjectRef
        let direction: String
        let net: String?
    }

    private func pinTable(_ pins: [DesignPin]) -> some View {
        endpointRows(pins.map { PinRow(id: $0.name, ref: .pin($0.name), direction: $0.direction, net: design.net(ofPin: $0.name)) },
                     netTitle: "Net")
    }

    private func endpointTable(_ ends: [NetEndpoint]) -> some View {
        endpointRows(ends.map { end in
            if end.isPort {
                return PinRow(id: "port:" + end.name, ref: .port(end.name), direction: design.port(named: end.name)?.direction ?? "", net: nil)
            }
            let pin = design.pins[end.name]
            return PinRow(id: end.name, ref: .pin(end.name), direction: pin?.direction ?? "", net: pin.map(\.cellName))
        }, netTitle: "Cell")
    }

    private func endpointRows(_ rows: [PinRow], netTitle: String) -> some View {
        Group {
            if rows.isEmpty {
                Text("Nothing connected.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Name") { ObjectLink(ref: $0.ref) }
                    TableColumn("Dir") { Text($0.direction).font(.caption) }.width(min: 34, ideal: 40, max: 60)
                    TableColumn(netTitle) { row in
                        if let other = row.net {
                            ObjectLink(ref: netTitle == "Net" ? .net(other) : .cell(other))
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

/// A design object's name as a link: clicking selects it in every design window.
struct ObjectLink: View {
    @EnvironmentObject private var model: AppModel
    let ref: DesignObjectRef

    init(ref: DesignObjectRef) { self.ref = ref }
    init(endpoint: NetEndpoint) { ref = endpoint.isPort ? .port(endpoint.name) : .pin(endpoint.name) }

    var body: some View {
        Button { model.select(ref) } label: {
            Text(ref.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.link)
        .help("Select \(ref.name)")
    }
}
