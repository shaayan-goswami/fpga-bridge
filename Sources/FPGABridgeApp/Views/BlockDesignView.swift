import AppKit
import FPGABridgeCore
import SwiftUI

/// IP Integrator's block design window: the Diagram (blocks, ports and connections, hierarchies opened in place) and
/// the Address Editor, with the selected object's properties alongside. It reads the `.bd` on this Mac, so it works
/// with the build machine asleep. Viewing only for now; the editing commands are shown greyed with the reason.
struct BlockDesignView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let path: String

    @State private var design: Result<BlockDesign, Error>?
    @State private var diagram: Result<BlockDesignDiagram, Error>?
    @State private var expanded: Set<String> = BlockDesignDebug.expanded
    @State private var selection: BDSelection? = BlockDesignDebug.selection
    @State private var page = BlockDesignDebug.page ?? Page.diagram
    @State private var reloads = 0
    @State private var scale: CGFloat = 1
    @State private var offset: CGPoint = .zero
    @State private var viewSize: CGSize = .zero
    @State private var hover: String?
    @State private var needsFit = true
    private let inspectorWidth: CGFloat = 290

    enum Page: String, CaseIterable { case diagram = "Diagram", addressEditor = "Address Editor" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch design {
            case .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Can't open this block design", systemImage: BlockDesignSources.symbol)
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") { reloads += 1 }
                }
            case .success(let design):
                HStack(spacing: 0) {
                    Group {
                        switch page {
                        case .diagram: diagramPage(design)
                        case .addressEditor: AddressEditorTable(design: design, selection: $selection)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    BlockPropertiesPanel(design: design, selection: selection)
                        .frame(width: inspectorWidth)
                }
            }
        }
        .background(Theme.surface)
        .task(id: "\(path)#\(reloads)") { await load() }
        .task(id: LayoutKey(expanded: expanded, reloads: reloads, loaded: designLoaded)) { await relayout() }
    }

    private struct LayoutKey: Equatable {
        let expanded: Set<String>
        let reloads: Int
        let loaded: Bool
    }

    private var designLoaded: Bool { if case .success = design { return true } else { return false } }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: BlockDesignSources.symbol).foregroundStyle(.secondary)
            Text(BlockDesignSources.name(of: path)).font(.headline)
            if case .success(let design) = design {
                Text([design.part, design.toolVersion.isEmpty ? "" : "Vivado \(design.toolVersion)"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if !design.isValidated {
                    Text("Not validated").font(.caption).foregroundStyle(Accent.warning)
                        .help("Vivado saved this block design without validating it (Validate Design, F6)")
                }
            }
            Divider().frame(height: 14)
            Switcher(options: Page.allCases.map(\.rawValue),
                     selection: Binding(get: { page.rawValue }, set: { page = Page(rawValue: $0) ?? .diagram }))
            Spacer()
            if page == .diagram { diagramTools }
            Button { reloads += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload the block design from disk")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder private var diagramTools: some View {
        Group {
            // Vivado's diagram toolbar; editing comes later.
            Button {} label: { Image(systemName: "plus") }
                .disabled(true)
                .help("Add IP: coming soon. Editing block designs needs builds to run Vivado's IP Integrator.")
            Button {} label: { Image(systemName: "checkmark.seal") }
                .disabled(true)
                .help("Validate Design: coming soon. It runs in Vivado on the build machine.")
            Divider().frame(height: 14)
            Button { zoom(by: 1.4, about: center) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
            Button { zoom(by: 1 / 1.4, about: center) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
            Button { fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom Fit")
            Divider().frame(height: 14)
            Button { expanded = allHierarchies } label: { Image(systemName: "rectangle.expand.vertical") }
                .disabled(allHierarchies.isEmpty || expanded == allHierarchies)
                .help("Expand All: open every hierarchy in place")
            Button { expanded = [] } label: { Image(systemName: "rectangle.compress.vertical") }
                .disabled(expanded.isEmpty)
                .help("Collapse All")
            Button { needsFit = true; Task { await relayout(force: true) } } label: { Image(systemName: "rectangle.3.group") }
                .help("Regenerate Layout")
        }
        .buttonStyle(.borderless)
        if case .success(let diagram) = diagram {
            Text("\(diagram.cells.count) blocks · \(diagram.ports.count) ports · \(diagram.layout.wires.count) connections")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        Text("\(Int(scale * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
    }

    private var allHierarchies: Set<String> {
        guard case .success(let design) = design else { return [] }
        return Set(design.allCells.filter(\.isHierarchy).map(\.path))
    }

    // MARK: Diagram

    @ViewBuilder private func diagramPage(_ design: BlockDesign) -> some View {
        VStack(spacing: 0) {
            let partial = design.allCells.filter { !$0.hasFullPinList }
            if !partial.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("\(partial.count) block\(partial.count == 1 ? "'s" : "s'") IP files (ip/…/*.xci) aren't next to the .bd, so only their connected pins are shown.")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                Divider()
            }
            switch diagram {
            case .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error):
                ContentUnavailableView("Can't draw this block design", systemImage: BlockDesignSources.symbol,
                                       description: Text(error.userMessage))
            case .success(let diagram):
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        BlockDesignCanvas(diagram: diagram, scale: scale, offset: offset, selection: selection,
                                          colors: BlockDesignColors(dark: scheme == .dark))
                        SchematicInteraction(
                            onPan: { d in offset.x -= d.width; offset.y -= d.height; needsFit = false },
                            onZoom: { factor, at in zoom(by: factor, about: at) },
                            onClick: { at, _, count in click(at: at, count: count, diagram: diagram) },
                            onHover: { at in hover = describe(hit(at, in: diagram), diagram: diagram) },
                            menu: { at in menu(at: at, diagram: diagram) })
                        if let hover {
                            Text(hover)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .onAppear { viewSize = geometry.size; if needsFit { fitAll() } }
                    .onChange(of: geometry.size) { _, size in
                        viewSize = size
                        if needsFit { fitAll() }
                    }
                }
            }
        }
    }

    // MARK: Loading and layout

    private func load() async {
        guard let root = model.projectURL else { return }
        let url = root.appendingPathComponent(path)
        let loaded = await Task.detached { Result { try BlockDesign.load(from: url) } }.value
        design = loaded
        if case .success(let d) = loaded, let selected = selection, !selected.exists(in: d) { selection = nil }
        if case .success(let d) = loaded { expanded = expanded.filter { d.cell(atPath: $0)?.isHierarchy == true } }
    }

    private func relayout(force: Bool = false) async {
        guard case .success(let design) = design else { return }
        let expanded = expanded
        let computed = await Task.detached { Result { try BlockDesignDiagram.layout(design, expanded: expanded) } }.value
        let first = diagram == nil
        diagram = computed
        if first || force { needsFit = true }
        if needsFit { fitAll() }
    }

    private var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    private func zoom(by factor: CGFloat, about point: CGPoint) {
        let new = min(max(scale * factor, 0.05), 6)
        let modelPoint = CGPoint(x: (point.x + offset.x) / scale, y: (point.y + offset.y) / scale)
        scale = new
        offset = CGPoint(x: modelPoint.x * new - point.x, y: modelPoint.y * new - point.y)
        needsFit = false
    }

    private func fitAll() {
        guard case .success(let diagram) = diagram, viewSize.width > 0, viewSize.height > 0 else { return }
        let size = diagram.layout.size
        guard size.width > 0, size.height > 0 else { return }
        scale = min(viewSize.width / size.width, viewSize.height / size.height, 1.6)
        offset = CGPoint(x: size.width / 2 * scale - viewSize.width / 2, y: size.height / 2 * scale - viewSize.height / 2)
        // Stays fitted as the window resizes, until the user zooms or pans.
        if let view = DebugHooks.schematicView {
            scale = view.zoom
            offset = CGPoint(x: size.width * view.x * scale - viewSize.width / 2, y: size.height * view.y * scale - viewSize.height / 2)
        }
    }

    // MARK: Hit testing

    enum Hit {
        case node(SchematicNode)
        case header(SchematicNode)
        case pin(SchematicNode, SchematicPin)
        case wire(SchematicWire)
    }

    private func toModel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x + offset.x) / scale, y: (p.y + offset.y) / scale) }

    private func hit(_ screen: CGPoint, in diagram: BlockDesignDiagram) -> Hit? {
        let p = toModel(screen)
        let tolerance = 5 / scale
        let nodes = diagram.layout.nodes.sorted { $0.depth > $1.depth }
        for node in nodes {
            for pin in node.pins {
                let edge = pin.side == .left ? node.frame.minX : node.frame.maxX
                let stub = CGRect(x: min(edge, pin.point.x) - tolerance, y: pin.point.y - tolerance,
                                  width: abs(pin.point.x - edge) + tolerance * 2, height: tolerance * 2)
                if stub.contains(p), !node.isOpenModule || abs(p.x - edge) <= tolerance * 2 { return .pin(node, pin) }
            }
        }
        for node in nodes where !node.isOpenModule && node.frame.insetBy(dx: -2, dy: -2).contains(p) { return .node(node) }
        for wire in diagram.layout.wires {
            for s in wire.segments where Self.distance(p, s) <= tolerance { return .wire(wire) }
        }
        for node in nodes where node.isOpenModule {
            if CGRect(x: node.frame.minX, y: node.frame.minY, width: node.frame.width, height: 22).contains(p) { return .header(node) }
            if node.frame.contains(p) { return .node(node) }
        }
        return nil
    }

    static func distance(_ p: CGPoint, _ s: SchematicWire.Segment) -> CGFloat {
        let cx = min(max(p.x, min(s.from.x, s.to.x)), max(s.from.x, s.to.x))
        let cy = min(max(p.y, min(s.from.y, s.to.y)), max(s.from.y, s.to.y))
        return hypot(p.x - cx, p.y - cy)
    }

    private func selection(of hit: Hit, in diagram: BlockDesignDiagram) -> BDSelection? {
        switch hit {
        case .node(let node), .header(let node):
            if let port = diagram.ports[node.id] { return .port(port.name) }
            return diagram.cells[node.id].map { .cell($0.path) }
        case .pin(let node, let pin):
            if let port = diagram.ports[node.id] { return .port(port.name) }
            return diagram.pin(pin.id).map { .pin(cell: $0.cell ?? "", name: $0.pin.name) }
        case .wire(let wire):
            return diagram.net(of: wire).map { .net(level: $0.level, name: $0.net.name, isInterface: $0.net.isInterface) }
        }
    }

    private func click(at point: CGPoint, count: Int, diagram: BlockDesignDiagram) {
        guard let hit = hit(point, in: diagram) else { selection = nil; return }
        if count >= 2 {
            switch hit {
            case .node(let node) where node.kind == .module(open: false), .header(let node):
                toggle(node.id)
                return
            default: break
            }
        }
        selection = self.selection(of: hit, in: diagram)
    }

    private func toggle(_ hierarchy: String) {
        if expanded.contains(hierarchy) {
            expanded = expanded.filter { $0 != hierarchy && !$0.hasPrefix(hierarchy + "/") }
        } else {
            expanded.insert(hierarchy)
        }
    }

    private func describe(_ hit: Hit?, diagram: BlockDesignDiagram) -> String? {
        switch hit {
        case .none: return nil
        case .node(let node), .header(let node):
            if let port = diagram.ports[node.id] { return "External \(port.isInterface ? "interface port" : "port"): \(port.label) · \(port.kindTitle)" }
            guard let cell = diagram.cells[node.id] else { return nil }
            if cell.isHierarchy { return "Hierarchy: /\(cell.path)\(node.isOpenModule ? "" : " · double-click to open")" }
            return "Block: /\(cell.path) · \(cell.vlnv)"
        case .pin(_, let pin):
            guard let found = diagram.pin(pin.id) else { return nil }
            return "\(found.pin.isInterface ? "Interface pin" : "Pin"): \(found.cell.map { "/\($0)/" } ?? "/")\(found.pin.label) · \(found.pin.kindTitle)"
        case .wire(let wire):
            guard let found = diagram.net(of: wire) else { return nil }
            return "\(found.net.isInterface ? "Interface net" : "Net"): \(found.level.isEmpty ? "/" : "/\(found.level)/")\(found.net.name)"
        }
    }

    private func menu(at point: CGPoint, diagram: BlockDesignDiagram) -> [SchematicMenuItem] {
        guard let hit = hit(point, in: diagram) else {
            return [SchematicMenuItem(title: "Zoom Fit") { fitAll() },
                    SchematicMenuItem(title: "Regenerate Layout") { needsFit = true; Task { await relayout(force: true) } }]
        }
        let selected = selection(of: hit, in: diagram)
        selection = selected
        var items: [SchematicMenuItem] = []
        switch hit {
        case .node(let node), .header(let node):
            if let cell = diagram.cells[node.id], cell.isHierarchy {
                items.append(SchematicMenuItem(title: node.isOpenModule ? "Collapse Hierarchy" : "Expand Hierarchy") { toggle(cell.path) })
            }
        default: break
        }
        items.append(SchematicMenuItem(title: "Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected?.vivadoName ?? "", forType: .string)
        })
        items.append(SchematicMenuItem(title: "Edit in Vivado (coming soon)", enabled: false) {})
        return items
    }
}

/// Screenshot settings (see DebugHooks): debug builds only.
enum BlockDesignDebug {
    #if DEBUG
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var page: BlockDesignView.Page? { env["FPGA_BRIDGE_BD_PAGE"].flatMap(BlockDesignView.Page.init(rawValue:)) }
    static var expanded: Set<String> { Set((env["FPGA_BRIDGE_EXPAND"] ?? "").split(separator: ",").map(String.init)) }
    static var selection: BDSelection? {
        guard let spec = env["FPGA_BRIDGE_BD_SELECT"], let colon = spec.firstIndex(of: ":") else { return nil }
        let name = String(spec[spec.index(after: colon)...])
        switch spec[..<colon] {
        case "cell": return .cell(name)
        case "port": return .port(name)
        default: return nil
        }
    }
    #else
    static let page: BlockDesignView.Page? = nil
    static let expanded: Set<String> = []
    static let selection: BDSelection? = nil
    #endif
}

// MARK: Selection

/// What is selected in a block design, named as Vivado names it (`/axi_gpio_0`, `/axi_gpio_0/S_AXI`).
enum BDSelection: Hashable {
    case cell(String)
    case port(String)
    /// A block's pin; `cell` is the block's path.
    case pin(cell: String, name: String)
    case net(level: String, name: String, isInterface: Bool)

    var vivadoName: String {
        switch self {
        case .cell(let path): "/" + path
        case .port(let name): "/" + name
        case .pin(let cell, let name): "/\(cell)/\(name)"
        case .net(let level, let name, _): level.isEmpty ? "/" + name : "/\(level)/\(name)"
        }
    }

    func exists(in design: BlockDesign) -> Bool {
        switch self {
        case .cell(let path): design.cell(atPath: path) != nil
        case .port(let name): design.port(named: name) != nil
        case .pin(let cell, let name): design.cell(atPath: cell)?.pin(named: name) != nil
        case .net(let level, let name, let isInterface): design.nets(in: level).contains { $0.name == name && $0.isInterface == isInterface }
        }
    }
}

// MARK: Drawing

/// IP Integrator's colors: pale blue blocks with a slate border, a darker blue for nets, and thick lighter buses for
/// interface connections.
struct BlockDesignColors {
    let background: Color
    let blockFill: Color
    let hierarchyFill: Color
    let openFill: Color
    let border: Color
    let text: Color
    let secondaryText: Color
    let net: Color
    let bus: Color
    let selection: Color
    let portFill: Color

    init(dark: Bool) {
        if dark {
            background = Theme.surface
            blockFill = Color(red: 0.16, green: 0.24, blue: 0.36)
            hierarchyFill = Color(red: 0.20, green: 0.28, blue: 0.24)
            openFill = Color(white: 1, opacity: 0.035)
            border = Color(red: 0.58, green: 0.66, blue: 0.80)
            text = Color(white: 0.92)
            secondaryText = Color(white: 0.62)
            net = Color(red: 0.55, green: 0.70, blue: 0.95)
            bus = Color(red: 0.40, green: 0.62, blue: 0.95)
            selection = Color(red: 1.0, green: 0.62, blue: 0.25)
            portFill = Color(white: 0.18)
        } else {
            background = .white
            blockFill = Color(red: 0.88, green: 0.93, blue: 0.99)
            hierarchyFill = Color(red: 0.91, green: 0.96, blue: 0.90)
            openFill = Color(red: 0.98, green: 0.985, blue: 1)
            border = Color(red: 0.33, green: 0.42, blue: 0.58)
            text = Color(red: 0.11, green: 0.12, blue: 0.16)
            secondaryText = Color(white: 0.38)
            net = Color(red: 0.13, green: 0.27, blue: 0.60)
            bus = Color(red: 0.27, green: 0.50, blue: 0.85)
            selection = Color(red: 0.93, green: 0.45, blue: 0.0)
            portFill = .white
        }
    }
}

private struct BlockDesignCanvas: View {
    let diagram: BlockDesignDiagram
    let scale: CGFloat
    let offset: CGPoint
    let selection: BDSelection?
    let colors: BlockDesignColors

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.background))
            context.translateBy(x: -offset.x, y: -offset.y)
            context.scaleBy(x: scale, y: scale)
            let visible = CGRect(x: offset.x / scale, y: offset.y / scale, width: size.width / scale, height: size.height / scale)
                .insetBy(dx: -100, dy: -60)
            let showText = scale > 0.3

            for node in diagram.layout.nodes where node.isOpenModule && node.frame.intersects(visible) {
                drawOpenHierarchy(node, in: &context, showText: showText)
            }
            for wire in diagram.layout.wires {
                var path = Path()
                for s in wire.segments { path.move(to: s.from); path.addLine(to: s.to) }
                guard path.boundingRect.insetBy(dx: -4, dy: -4).intersects(visible) else { continue }
                let net = diagram.net(of: wire)
                let selected = net.map { selection == .net(level: $0.level, name: $0.net.name, isInterface: $0.net.isInterface) } ?? false
                let isBus = net?.net.isInterface ?? false
                let color = selected ? colors.selection : isBus ? colors.bus : colors.net
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: (isBus ? 3.2 : 1.1) * (selected ? 1.4 : 1), lineCap: .round))
                drawJunctions(wire, color: color, size: isBus ? 6 : 4, in: &context)
            }
            for node in diagram.layout.nodes where !node.isOpenModule && node.frame.insetBy(dx: -120, dy: -30).intersects(visible) {
                if let port = diagram.ports[node.id] {
                    drawPort(node, port: port, in: &context, showText: showText)
                } else {
                    drawBlock(node, in: &context, showText: showText)
                }
            }
        }
    }

    /// Dots where a net branches, as IP Integrator draws them.
    private func drawJunctions(_ wire: SchematicWire, color: Color, size: CGFloat, in context: inout GraphicsContext) {
        var count: [[CGFloat]: Int] = [:]
        for s in wire.segments { count[[s.from.x, s.from.y], default: 0] += 1; count[[s.to.x, s.to.y], default: 0] += 1 }
        for (point, n) in count where n >= 3 {
            context.fill(Path(ellipseIn: CGRect(x: point[0] - size / 2, y: point[1] - size / 2, width: size, height: size)), with: .color(color))
        }
    }

    private func label(_ text: String, at point: CGPoint, anchor: UnitPoint, size: CGFloat, weight: Font.Weight = .regular,
                       color: Color, in context: inout GraphicsContext) {
        context.draw(Text(text).font(.system(size: size, weight: weight)).foregroundStyle(color), at: point, anchor: anchor)
    }

    private func isSelected(cell path: String) -> Bool { selection == .cell(path) }

    private func drawOpenHierarchy(_ node: SchematicNode, in context: inout GraphicsContext, showText: Bool) {
        let selected = isSelected(cell: node.id)
        let shape = RoundedRectangle(cornerRadius: 10).path(in: node.frame)
        context.fill(shape, with: .color(colors.openFill))
        context.stroke(shape, with: .color(selected ? colors.selection : colors.border.opacity(0.75)),
                       style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: [5, 3]))
        drawToggle(open: true, at: CGPoint(x: node.frame.minX + 6, y: node.frame.minY + 6), in: &context)
        drawPins(node, in: &context, showText: false)
        if showText {
            label(node.title, at: CGPoint(x: node.frame.minX + 22, y: node.frame.minY + 11), anchor: .leading, size: 10.5,
                  weight: .semibold, color: colors.text, in: &context)
        }
    }

    /// The small square with + or −: a closed hierarchy opens in place, an open one closes.
    private func drawToggle(open: Bool, at origin: CGPoint, in context: inout GraphicsContext) {
        let box = CGRect(x: origin.x, y: origin.y, width: 11, height: 11)
        context.fill(RoundedRectangle(cornerRadius: 2).path(in: box), with: .color(colors.border))
        var mark = Path()
        mark.move(to: CGPoint(x: box.minX + 3, y: box.midY)); mark.addLine(to: CGPoint(x: box.maxX - 3, y: box.midY))
        if !open { mark.move(to: CGPoint(x: box.midX, y: box.minY + 3)); mark.addLine(to: CGPoint(x: box.midX, y: box.maxY - 3)) }
        context.stroke(mark, with: .color(colors.background), lineWidth: 1.5)
    }

    private func drawBlock(_ node: SchematicNode, in context: inout GraphicsContext, showText: Bool) {
        let cell = diagram.cells[node.id]
        let selected = isSelected(cell: node.id)
        let f = node.frame
        let shape = RoundedRectangle(cornerRadius: 7).path(in: f)
        context.fill(shape, with: .color(cell?.isHierarchy == true ? colors.hierarchyFill : colors.blockFill))
        context.stroke(shape, with: .color(selected ? colors.selection : colors.border), lineWidth: selected ? 2.2 : 1.1)
        // Just above the corner, clear of the first pin's name.
        if cell?.isHierarchy == true { drawToggle(open: false, at: CGPoint(x: f.minX, y: f.minY - 14), in: &context) }
        drawPins(node, in: &context, showText: showText)
        guard showText else { return }
        label(node.title, at: CGPoint(x: f.midX, y: f.minY - 3), anchor: .bottom, size: 10.5, weight: .semibold, color: colors.text, in: &context)
        if let cell, !cell.displayName.isEmpty {
            label(cell.displayName, at: CGPoint(x: f.midX, y: f.maxY + 3), anchor: .top, size: 9.5, color: colors.secondaryText, in: &context)
        }
        if cell?.kind == .moduleReference {
            // IP Integrator marks an RTL module added as a block.
            label("RTL", at: CGPoint(x: f.maxX - 5, y: f.maxY - 3), anchor: .bottomTrailing, size: 8, weight: .bold, color: colors.border, in: &context)
        }
    }

    private func drawPins(_ node: SchematicNode, in context: inout GraphicsContext, showText: Bool) {
        let f = node.frame
        for pin in node.pins {
            guard let found = diagram.pin(pin.id) else { continue }
            let selected = selection == .pin(cell: found.cell ?? "", name: found.pin.name)
            let edgeX = pin.side == .left ? f.minX : f.maxX
            var stub = Path()
            stub.move(to: CGPoint(x: edgeX, y: pin.point.y)); stub.addLine(to: pin.point)
            let color = selected ? colors.selection : found.pin.isInterface ? colors.bus : colors.border
            context.stroke(stub, with: .color(color), lineWidth: found.pin.isInterface ? 3 : 1.1)
            if found.pin.isInterface {
                // The "+" that opens an interface into its signals in Vivado.
                let box = CGRect(x: edgeX - 4.5, y: pin.point.y - 4.5, width: 9, height: 9)
                context.fill(Path(box), with: .color(colors.background))
                context.stroke(Path(box), with: .color(color), lineWidth: 1)
                var plus = Path()
                plus.move(to: CGPoint(x: box.minX + 2, y: box.midY)); plus.addLine(to: CGPoint(x: box.maxX - 2, y: box.midY))
                plus.move(to: CGPoint(x: box.midX, y: box.minY + 2)); plus.addLine(to: CGPoint(x: box.midX, y: box.maxY - 2))
                context.stroke(plus, with: .color(color), lineWidth: 1)
            } else if found.pin.type == "clk", pin.side == .left {
                var tri = Path()
                tri.move(to: CGPoint(x: f.minX, y: pin.point.y - 3.5)); tri.addLine(to: CGPoint(x: f.minX + 5, y: pin.point.y))
                tri.addLine(to: CGPoint(x: f.minX, y: pin.point.y + 3.5))
                context.stroke(tri, with: .color(colors.border), lineWidth: 1)
            }
            guard showText else { continue }
            let inset: CGFloat = found.pin.isInterface ? 8 : found.pin.type == "clk" && pin.side == .left ? 8 : 4
            label(found.pin.label, at: CGPoint(x: pin.side == .left ? f.minX + inset : f.maxX - inset, y: pin.point.y),
                  anchor: pin.side == .left ? .leading : .trailing, size: 8.5, weight: found.pin.isInterface ? .semibold : .regular,
                  color: colors.text, in: &context)
        }
    }

    /// An external port: an arrow pointing the way the signal goes, with its name outside.
    private func drawPort(_ node: SchematicNode, port: BDPin, in context: inout GraphicsContext, showText: Bool) {
        let selected = selection == .port(port.name)
        let f = node.frame
        var shape = Path()
        let tip: CGFloat = 7
        switch port.direction {
        case .inout:
            shape.move(to: CGPoint(x: f.minX, y: f.midY)); shape.addLine(to: CGPoint(x: f.minX + tip, y: f.minY))
            shape.addLine(to: CGPoint(x: f.maxX - tip, y: f.minY)); shape.addLine(to: CGPoint(x: f.maxX, y: f.midY))
            shape.addLine(to: CGPoint(x: f.maxX - tip, y: f.maxY)); shape.addLine(to: CGPoint(x: f.minX + tip, y: f.maxY))
        default:
            shape.move(to: CGPoint(x: f.minX, y: f.minY)); shape.addLine(to: CGPoint(x: f.maxX - tip, y: f.minY))
            shape.addLine(to: CGPoint(x: f.maxX, y: f.midY)); shape.addLine(to: CGPoint(x: f.maxX - tip, y: f.maxY))
            shape.addLine(to: CGPoint(x: f.minX, y: f.maxY))
        }
        shape.closeSubpath()
        let color = selected ? colors.selection : port.isInterface ? colors.bus : colors.border
        context.fill(shape, with: .color(colors.portFill))
        context.stroke(shape, with: .color(color), lineWidth: port.isInterface ? 2.4 : 1.2)
        if port.isInterface {
            var plus = Path()
            plus.move(to: CGPoint(x: f.midX - 7, y: f.midY)); plus.addLine(to: CGPoint(x: f.midX + 1, y: f.midY))
            plus.move(to: CGPoint(x: f.midX - 3, y: f.midY - 4)); plus.addLine(to: CGPoint(x: f.midX - 3, y: f.midY + 4))
            context.stroke(plus, with: .color(color), lineWidth: 1.2)
        }
        guard showText else { return }
        let input = port.direction == .input
        label(port.label, at: CGPoint(x: input ? f.minX - 6 : f.maxX + 6, y: f.midY), anchor: input ? .trailing : .leading,
              size: 10.5, weight: port.isInterface ? .semibold : .regular, color: colors.text, in: &context)
    }
}

// MARK: Properties

/// Vivado's Properties window for what is selected in the block design: Block Properties for a block (with every
/// CONFIG parameter, the ones changed from the IP's default first), and the same for ports, pins and nets.
struct BlockPropertiesPanel: View {
    let design: BlockDesign
    let selection: BDSelection?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let selection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                            ForEach(Array(general(selection).enumerated()), id: \.offset) { _, row in
                                InfoRow(label: row.0, value: row.1, monospaced: row.2)
                            }
                        }
                        let parameters = self.parameters(selection)
                        if !parameters.isEmpty { parameterList(parameters) }
                        let connections = self.connections(selection)
                        if !connections.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Connections").font(.subheadline.weight(.semibold))
                                ForEach(connections, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                summary
            }
        }
        .background(Theme.surface)
    }

    private var title: String {
        switch selection {
        case .none: "Block Design Properties"
        case .cell: "Block Properties"
        case .port(let name): design.port(named: name)?.isInterface == true ? "External Interface Properties" : "External Port Properties"
        case .pin(let cell, let name): design.cell(atPath: cell)?.pin(named: name)?.isInterface == true ? "Interface Pin Properties" : "Pin Properties"
        case .net(_, _, let isInterface): isInterface ? "Interface Net Properties" : "Net Properties"
        }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    InfoRow(label: "Name", value: design.name)
                    InfoRow(label: "Part", value: design.part.isEmpty ? "—" : design.part, monospaced: true)
                    InfoRow(label: "Saved by", value: design.toolVersion.isEmpty ? "—" : "Vivado \(design.toolVersion)")
                    InfoRow(label: "Validated", value: design.isValidated ? "Yes" : "No")
                    InfoRow(label: "Blocks", value: "\(design.allCells.filter { !$0.isHierarchy }.count)")
                    InfoRow(label: "Hierarchies", value: "\(design.allCells.filter(\.isHierarchy).count)")
                    InfoRow(label: "External ports", value: "\(design.ports.count)")
                }
                if !design.ipCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("IP Used").font(.subheadline.weight(.semibold))
                        ForEach(design.ipCounts, id: \.vlnv) { entry in
                            HStack {
                                Text(entry.vlnv).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(entry.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Select a block, port, pin or connection to see its properties.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pinRows(_ pin: BDPin) -> [(String, String, Bool)] {
        var rows: [(String, String, Bool)] = [("Name", pin.label, true), ("Direction", pin.direction.title, false)]
        if pin.isInterface {
            rows += [("Mode", pin.mode, false), ("VLNV", pin.vlnv, true)]
        } else {
            rows += [("Type", pin.type, true), ("Width", "\(pin.width)", false)]
            if let left = pin.left, let right = pin.right { rows += [("Left", "\(left)", false), ("Right", "\(right)", false)] }
        }
        return rows
    }

    private func general(_ selection: BDSelection) -> [(String, String, Bool)] {
        switch selection {
        case .cell(let path):
            guard let cell = design.cell(atPath: path) else { return [] }
            let parent = path.contains("/") ? "/" + (path as NSString).deletingLastPathComponent : "/"
            var rows: [(String, String, Bool)] = [("Name", cell.name, true), ("Parent", parent, true), ("Type", cell.kind.title, false)]
            if !cell.vlnv.isEmpty { rows.append(("VLNV", cell.vlnv, true)) }
            if !cell.displayName.isEmpty, cell.kind == .ip || cell.vlnv.contains(":ip:") { rows.append(("IP", cell.displayName, false)) }
            if !cell.referenceName.isEmpty { rows.append(("Reference", cell.referenceName, true)) }
            if !cell.xciName.isEmpty { rows.append(("Module", cell.xciName, true)) }
            rows.append(("Pins", "\(cell.pins.filter { !$0.isInterface }.count) pins, \(cell.pins.filter(\.isInterface).count) interfaces\(cell.hasFullPinList ? "" : " (connected only)")", false))
            if cell.isHierarchy { rows.append(("Contents", "\(cell.cells.count) block\(cell.cells.count == 1 ? "" : "s")", false)) }
            return rows
        case .port(let name):
            return design.port(named: name).map(pinRows) ?? []
        case .pin(let cell, let name):
            guard let pin = design.cell(atPath: cell)?.pin(named: name) else { return [] }
            return [("Block", "/" + cell, true)] + pinRows(pin)
        case .net(let level, let name, let isInterface):
            return [("Name", name, true), ("Parent", level.isEmpty ? "/" : "/" + level, true),
                    ("Type", isInterface ? "Interface net" : "Net", false)]
        }
    }

    private func parameters(_ selection: BDSelection) -> [BDParameter] {
        switch selection {
        case .cell(let path): design.cell(atPath: path)?.parameters ?? []
        case .port(let name): design.port(named: name)?.parameters ?? []
        case .pin(let cell, let name): design.cell(atPath: cell)?.pin(named: name)?.parameters ?? []
        case .net: []
        }
    }

    /// What a pin, port or net connects to, by Vivado name.
    private func connections(_ selection: BDSelection) -> [String] {
        func absolute(_ end: String, level: String) -> String { level.isEmpty ? "/" + end : "/\(level)/\(end)" }
        switch selection {
        case .net(let level, let name, let isInterface):
            return design.nets(in: level).first { $0.name == name && $0.isInterface == isInterface }?.endpoints.map { absolute($0, level: level) } ?? []
        case .port(let name):
            return design.nets.filter { $0.endpoints.contains(name) }.flatMap(\.endpoints).filter { $0 != name }.map { absolute($0, level: "") }
        case .pin(let cell, let name):
            let level = cell.contains("/") ? (cell as NSString).deletingLastPathComponent : ""
            let local = (cell as NSString).lastPathComponent + "/" + name
            let outside = design.nets(in: level).filter { $0.endpoints.contains(local) }.flatMap(\.endpoints).filter { $0 != local }
                .map { absolute($0, level: level) }
            let inside = design.cell(atPath: cell)?.isHierarchy == true
                ? design.nets(in: cell).filter { $0.endpoints.contains(name) }.flatMap(\.endpoints).filter { $0 != name }.map { absolute($0, level: cell) }
                : []
            return outside + inside
        case .cell:
            return []
        }
    }

    private func parameterList(_ parameters: [BDParameter]) -> some View {
        let sorted = parameters.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.isUserSet != $1.isUserSet ? $0.isUserSet : $0.name < $1.name }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Parameters").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(parameters.filter(\.isUserSet).count) changed").font(.caption).foregroundStyle(.secondary)
            }
            if parameters.count > 12 {
                TextField("Search", text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(sorted) { p in
                    GridRow {
                        Text("CONFIG.\(p.name)")
                            .font(.caption.monospaced().weight(p.isUserSet ? .semibold : .regular))
                            .foregroundStyle(p.isUserSet ? .primary : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(p.isUserSet ? "Changed from the IP's default" : "The IP's default")
                        Text(p.value.isEmpty ? "—" : p.value)
                            .font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: Address Editor

/// Vivado's Address Editor: for each master and its address spaces, the slave segments it can reach, with their base
/// address, range and high address.
struct AddressEditorTable: View {
    let design: BlockDesign
    @Binding var selection: BDSelection?
    @State private var selectedRow: String?

    struct Row: Identifiable {
        let id: String
        let depth: Int
        let name: String
        var interface = ""
        var segment = ""
        var base = ""
        var range = ""
        var high = ""
        var excluded = false
        var cell: String?
    }

    var rows: [Row] {
        var rows: [Row] = []
        var masters: [String] = []
        for s in design.addressSegments where !masters.contains(s.master) { masters.append(s.master) }
        for master in masters {
            rows.append(Row(id: master, depth: 0, name: master, cell: String(master.dropFirst())))
            let mine = design.addressSegments.filter { $0.master == master }
            var spaces: [String] = []
            for s in mine where !spaces.contains(s.addressSpace) { spaces.append(s.addressSpace) }
            for space in spaces {
                rows.append(Row(id: "\(master)/\(space)", depth: 1, name: "\(master)/\(space)"))
                let segments = mine.filter { $0.addressSpace == space }
                for s in segments.filter({ !$0.isExcluded }) + segments.filter(\.isExcluded) {
                    rows.append(Row(id: s.id, depth: 2, name: s.slave, interface: s.slaveInterface, segment: s.slaveSegment,
                                    base: BDAddressSegment.format(s.offset, width: s.width), range: s.rangeText,
                                    high: BDAddressSegment.format(s.high, width: s.width), excluded: s.isExcluded,
                                    cell: String(s.slave.dropFirst())))
                }
            }
        }
        return rows
    }

    var body: some View {
        if design.addressSegments.isEmpty {
            ContentUnavailableView("No Addresses", systemImage: "list.bullet.rectangle",
                                   description: Text("Nothing in this block design has an address map: there's no AXI master, or no slave is assigned to one."))
        } else {
            Table(rows, selection: $selectedRow) {
                TableColumn("Name") { row in
                    Text(row.name)
                        .font(row.depth < 2 ? .callout.weight(.semibold) : .callout.monospaced())
                        .foregroundStyle(row.excluded ? .secondary : .primary)
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .help(row.excluded ? "Excluded: wired to this master, but not reachable from it" : row.name)
                }
                .width(min: 160, ideal: 220)
                TableColumn("Interface") { row in Text(row.interface).font(.callout.monospaced()) }.width(min: 60, ideal: 80)
                TableColumn("Slave Segment") { row in Text(row.segment).font(.callout.monospaced()) }.width(min: 70, ideal: 100)
                TableColumn("Master Base Address") { row in Text(row.base).font(.callout.monospaced()) }.width(min: 110, ideal: 140)
                TableColumn("Range") { row in Text(row.range).font(.callout.monospaced()) }.width(min: 50, ideal: 70)
                TableColumn("Master High Address") { row in Text(row.high).font(.callout.monospaced()) }.width(min: 110, ideal: 140)
            }
            .onChange(of: selectedRow) { _, id in
                // Selecting a row shows its block's properties, as in Vivado.
                if let cell = rows.first(where: { $0.id == id })?.cell { selection = .cell(cell) }
            }
        }
    }
}
