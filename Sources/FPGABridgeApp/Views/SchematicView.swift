import AppKit
import FPGABridgeCore
import SwiftUI

/// Vivado's Schematic window: the open design drawn as symbols and wires, one level of the hierarchy at a time, with
/// modules opened in place. Selecting here selects in the Netlist and Properties windows, and the other way round.
struct SchematicView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let stage: DesignStage

    @State private var result: Result<SchematicLayout, Error>?
    @State private var laidOut: SchematicSpec?
    @State private var scale: CGFloat = 1
    @State private var offset: CGPoint = .zero
    @State private var viewSize: CGSize = .zero
    @State private var hover: String?
    @State private var autofit = false
    @State private var needsFit = true

    private var spec: SchematicSpec { model.schematicSpecs[stage] ?? SchematicSpec() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Theme.surface)
        .task(id: TaskKey(spec: spec, design: model.designs[stage]?.info.design ?? "", cells: model.designs[stage]?.cells.count ?? 0)) {
            await relayout()
        }
        .onChange(of: model.designSelection) { _, _ in if autofit { fitSelection() } }
    }

    private struct TaskKey: Equatable {
        let spec: SchematicSpec
        let design: String
        let cells: Int
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Group {
                Button { model.schematicBack(stage) } label: { Image(systemName: "arrow.left") }
                    .disabled(model.schematicHistory[stage]?.isEmpty ?? true)
                    .help("Previous")
                Button { model.schematicForward(stage) } label: { Image(systemName: "arrow.right") }
                    .disabled(model.schematicFuture[stage]?.isEmpty ?? true)
                    .help("Next")
                Divider().frame(height: 14)
                Button { zoom(by: 1.4, about: center) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
                Button { zoom(by: 1 / 1.4, about: center) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                Button { fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom Fit")
                Toggle(isOn: $autofit) { Image(systemName: "scope") }
                    .toggleStyle(.button)
                    .help("Autofit Selection: zoom to what you select")
                Divider().frame(height: 14)
                Button { model.showSchematic(SchematicSpec(module: spec.module), in: stage) } label: { Image(systemName: "rectangle.compress.vertical") }
                    .disabled(spec.expanded.isEmpty && spec.only == nil)
                    .help("Collapse All: close every module and show the whole level")
                Button { Task { await relayout(force: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Regenerate Schematic")
            }
            .buttonStyle(.borderless)
            if case .success(let layout) = result {
                Divider().frame(height: 14)
                countLink("\(layout.cellCount) Cells") { model.select(layout.nodes.filter(\.isCellLike).flatMap(\.refs)) }
                countLink("\(layout.portCount) I/O Ports") { model.select(layout.nodes.filter(\.isPort).flatMap(\.refs)) }
                countLink("\(layout.netCount) Nets") { model.select(Array(Set(layout.wires.flatMap(\.nets))).sorted().map { .net($0) }) }
            }
            Spacer()
            if let only = spec.only {
                Text("\(only.count) selected cell\(only.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            } else if !spec.module.isEmpty {
                Text(spec.module).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text("\(Int(scale * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func countLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.link).font(.callout)
    }

    // MARK: Canvas

    @ViewBuilder private var content: some View {
        switch result {
        case .none:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let error):
            ContentUnavailableView {
                Label("Can't draw this schematic", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text(error.userMessage)
            } actions: {
                if spec != SchematicSpec() { Button("Show the Top Level") { model.showSchematic(SchematicSpec(), in: stage) } }
            }
        case .success(let layout):
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    SchematicCanvas(layout: layout, scale: scale, offset: offset, selection: Set(model.designSelection),
                                    colors: SchematicColors(dark: scheme == .dark))
                    SchematicInteraction(
                        onPan: { d in offset.x -= d.width; offset.y -= d.height },
                        onZoom: { factor, at in zoom(by: factor, about: at) },
                        onClick: { at, extend, count in click(at: at, extend: extend, count: count, layout: layout) },
                        onHover: { at in hover = describe(hit(at, in: layout), layout: layout) },
                        menu: { at in menu(at: at, layout: layout) })
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

    // MARK: Layout

    private func relayout(force: Bool = false) async {
        guard let design = model.designs[stage] else { return }
        let spec = spec
        if !force, laidOut == spec, result != nil { return }
        let previous = laidOut
        let computed = await Task.detached { Result { try SchematicBuilder(design: design).layout(spec) } }.value
        result = computed
        laidOut = spec
        // A new set of cells starts fitted; opening a module in place keeps the view where it was.
        if previous?.module != spec.module || previous?.only != spec.only || force { needsFit = true; fitAll() }
        if autofit { fitSelection() }
    }

    private var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    private func zoom(by factor: CGFloat, about point: CGPoint) {
        let new = min(max(scale * factor, 0.05), 6)
        // Keep the model point under the cursor where it is.
        let model = CGPoint(x: (point.x + offset.x) / scale, y: (point.y + offset.y) / scale)
        scale = new
        offset = CGPoint(x: model.x * new - point.x, y: model.y * new - point.y)
        needsFit = false
    }

    private func fitAll() {
        guard case .success(let layout) = result else { return }
        fit(CGRect(origin: .zero, size: layout.size), maxScale: 1.6)
        needsFit = viewSize == .zero
    }

    private func fitSelection() {
        guard case .success(let layout) = result else { return }
        let selected = Set(model.designSelection)
        var rect = CGRect.null
        for node in layout.nodes where node.refs.contains(where: selected.contains) { rect = rect.union(node.frame) }
        for wire in layout.wires where wire.nets.contains(where: { selected.contains(.net($0)) }) {
            for s in wire.segments { rect = rect.union(CGRect(x: min(s.from.x, s.to.x), y: min(s.from.y, s.to.y), width: abs(s.to.x - s.from.x), height: abs(s.to.y - s.from.y))) }
        }
        if !rect.isNull { fit(rect.insetBy(dx: -60, dy: -60), maxScale: 2) }
    }

    private func fit(_ rect: CGRect, maxScale: CGFloat) {
        guard viewSize.width > 0, viewSize.height > 0, rect.width > 0, rect.height > 0 else { return }
        scale = min(viewSize.width / rect.width, viewSize.height / rect.height, maxScale)
        offset = CGPoint(x: rect.midX * scale - viewSize.width / 2, y: rect.midY * scale - viewSize.height / 2)
    }

    // MARK: Hit testing

    enum Hit {
        case node(SchematicNode)
        case moduleHeader(SchematicNode)
        case pin(SchematicNode, SchematicPin)
        case wire(SchematicWire)
    }

    private func toModel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x + offset.x) / scale, y: (p.y + offset.y) / scale) }

    private func hit(_ screen: CGPoint, in layout: SchematicLayout) -> Hit? {
        let p = toModel(screen)
        let tolerance = 5 / scale
        // Innermost first: nested cells are drawn on top of the module boxes around them.
        let nodes = layout.nodes.sorted { $0.depth > $1.depth }
        for node in nodes {
            for pin in node.pins where hypot(pin.point.x - p.x, pin.point.y - p.y) <= tolerance { return .pin(node, pin) }
        }
        for node in nodes where !node.isOpenModule && node.frame.insetBy(dx: -2, dy: -2).contains(p) { return .node(node) }
        for wire in layout.wires {
            for s in wire.segments where distance(p, s) <= tolerance { return .wire(wire) }
        }
        for node in nodes where node.isOpenModule {
            let header = CGRect(x: node.frame.minX, y: node.frame.minY, width: node.frame.width, height: 22)
            if header.contains(p) { return .moduleHeader(node) }
            if node.frame.contains(p) { return .node(node) }
        }
        return nil
    }

    private func distance(_ p: CGPoint, _ s: SchematicWire.Segment) -> CGFloat {
        let minX = min(s.from.x, s.to.x), maxX = max(s.from.x, s.to.x), minY = min(s.from.y, s.to.y), maxY = max(s.from.y, s.to.y)
        let cx = min(max(p.x, minX), maxX), cy = min(max(p.y, minY), maxY)
        return hypot(p.x - cx, p.y - cy)
    }

    private func refs(of hit: Hit) -> [DesignObjectRef] {
        switch hit {
        case .node(let node), .moduleHeader(let node): node.refs
        case .pin(let node, let pin):
            if case .port = node.kind { node.refs } else { pin.members.map { .pin($0) } }
        case .wire(let wire): wire.nets.map { .net($0) }
        }
    }

    private func click(at point: CGPoint, extend: Bool, count: Int, layout: SchematicLayout) {
        guard let hit = hit(point, in: layout) else {
            if !extend { model.select(nil) }
            return
        }
        if count >= 2 {
            switch hit {
            case .node(let node) where node.kind == .module(open: false), .moduleHeader(let node):
                model.toggleInSchematic(node.ref.name, stage: stage)
                return
            case .node(let node):
                if let cell = model.designs[stage]?.cell(named: node.ref.name), model.canGoToSource(cell) { model.goToSource(cell) }
                return
            default:
                break
            }
        }
        let refs = refs(of: hit)
        if extend {
            for ref in refs { model.select(ref, extend: true) }
        } else {
            model.select(refs)
        }
    }

    private func describe(_ hit: Hit?, layout: SchematicLayout) -> String? {
        switch hit {
        case .none: nil
        case .node(let node), .moduleHeader(let node):
            switch node.kind {
            case .port(let direction): "I/O Port: \(node.title) (\(direction.lowercased()))"
            case .module(let open): "Hierarchical cell: \(node.ref.name) (\(node.subtitle))\(open ? "" : " · double-click to open")"
            case .cell: "Cell: \(node.isBundle ? node.title : node.ref.name) (\(node.subtitle))\(node.isBundle ? " · \(node.members.count) cells" : "")"
            }
        case .pin(let node, let pin): "Pin: \(node.isBundle || node.kind == .port(direction: "IN") || node.kind == .port(direction: "OUT") ? pin.label : (pin.members.first ?? pin.label))\(pin.tie.map { " · tied to \($0)" } ?? "")"
        case .wire(let wire): "Net: \(wire.label)\(wire.nets.count > 1 ? " · \(wire.nets.count) nets" : "")"
        }
    }

    private func menu(at point: CGPoint, layout: SchematicLayout) -> [SchematicMenuItem] {
        guard let hit = hit(point, in: layout) else {
            return [SchematicMenuItem(title: "Zoom Fit") { fitAll() }]
        }
        if !Set(refs(of: hit)).isSubset(of: Set(model.designSelection)) { model.select(refs(of: hit)) }
        var items: [SchematicMenuItem] = []
        switch hit {
        case .node(let node), .moduleHeader(let node):
            if case .module(let open) = node.kind {
                items.append(SchematicMenuItem(title: open ? "Collapse Inside" : "Expand Inside") { model.toggleInSchematic(node.ref.name, stage: stage) })
                items.append(SchematicMenuItem(title: "Show Only Its Contents") {
                    model.showSchematic(SchematicSpec(module: node.ref.name), in: stage)
                })
            }
            if let cell = model.designs[stage]?.cell(named: node.ref.name) {
                items.append(SchematicMenuItem(title: "Go To Source", enabled: model.canGoToSource(cell)) { model.goToSource(cell) })
            }
        default:
            break
        }
        items.append(SchematicMenuItem(title: "Schematic of Selection") { model.schematicOfSelection() })
        if !spec.module.isEmpty || spec.only != nil {
            items.append(SchematicMenuItem(title: "Show the Top Level") { model.showSchematic(SchematicSpec(), in: stage) })
        }
        items.append(SchematicMenuItem(title: "Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(refs(of: hit).map(\.name).joined(separator: "\n"), forType: .string)
        })
        return items
    }
}

extension SchematicNode {
    /// The design objects a click on it selects.
    var refs: [DesignObjectRef] {
        if case .port = kind { return members.map { .port($0) } }
        return members.isEmpty ? [ref] : members.map { .cell($0) }
    }

    var isPort: Bool { if case .port = kind { return true } else { return false } }
    var isCellLike: Bool { !isPort }
}

// MARK: Drawing

struct SchematicColors {
    let background: Color
    let leafFill: Color
    let moduleFill: Color
    let openFill: Color
    let border: Color
    let text: Color
    let secondaryText: Color
    let net: Color
    let bus: Color
    let selection: Color
    let portFill: Color

    /// Vivado's schematic colors (Settings ▸ Colors), with a dark version for dark mode.
    init(dark: Bool) {
        if dark {
            background = Theme.surface
            leafFill = Color(red: 0.32, green: 0.25, blue: 0.45)
            moduleFill = Color(red: 0.17, green: 0.27, blue: 0.40)
            openFill = Color(white: 1, opacity: 0.03)
            border = Color(red: 0.62, green: 0.65, blue: 0.72)
            text = Color(white: 0.92)
            secondaryText = Color(white: 0.62)
            net = Color(red: 0.55, green: 0.80, blue: 0.33)
            bus = Color(red: 0.25, green: 0.75, blue: 0.40)
            selection = Color(red: 0.36, green: 0.56, blue: 1.0)
            portFill = Color(white: 0.16)
        } else {
            background = .white
            leafFill = Color(red: 229 / 255, green: 199 / 255, blue: 255 / 255)
            moduleFill = Color(red: 205 / 255, green: 229 / 255, blue: 255 / 255)
            openFill = Color(white: 0.985)
            border = Color(red: 87 / 255, green: 93 / 255, blue: 108 / 255)
            text = Color(red: 28 / 255, green: 31 / 255, blue: 40 / 255)
            secondaryText = Color(white: 0.4)
            net = Color(red: 139 / 255, green: 195 / 255, blue: 74 / 255)
            bus = Color(red: 0, green: 150 / 255, blue: 51 / 255)
            selection = Color(red: 57 / 255, green: 108 / 255, blue: 239 / 255)
            portFill = .white
        }
    }
}

private struct SchematicCanvas: View {
    let layout: SchematicLayout
    let scale: CGFloat
    let offset: CGPoint
    let selection: Set<DesignObjectRef>
    let colors: SchematicColors

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.background))
            context.translateBy(x: -offset.x, y: -offset.y)
            context.scaleBy(x: scale, y: scale)
            let visible = CGRect(x: offset.x / scale, y: offset.y / scale, width: size.width / scale, height: size.height / scale).insetBy(dx: -80, dy: -80)
            let showText = scale > 0.3

            // Open modules first (outer to inner), then wires, then everything else on top.
            for node in layout.nodes where node.isOpenModule && node.frame.intersects(visible) {
                drawOpenModule(node, in: &context, showText: showText)
            }
            for wire in layout.wires {
                let selected = wire.nets.contains { selection.contains(.net($0)) }
                var path = Path()
                for s in wire.segments { path.move(to: s.from); path.addLine(to: s.to) }
                guard path.boundingRect.intersects(visible) else { continue }
                let color = selected ? colors.selection : (wire.isBus ? colors.bus : colors.net)
                context.stroke(path, with: .color(color), lineWidth: (wire.isBus ? 2.6 : 1.2) * (selected ? 1.5 : 1))
            }
            for node in layout.nodes where !node.isOpenModule && node.frame.insetBy(dx: -60, dy: -30).intersects(visible) {
                let selected = node.refs.contains(where: selection.contains)
                draw(node, selected: selected, in: &context, showText: showText)
            }
        }
    }

    private func font(_ size: CGFloat, mono: Bool = false) -> Font {
        .system(size: size, design: mono ? .monospaced : .default)
    }

    private func label(_ text: String, at point: CGPoint, anchor: UnitPoint, size: CGFloat = 10, color: Color, in context: inout GraphicsContext) {
        context.draw(Text(text).font(font(size)).foregroundStyle(color), at: point, anchor: anchor)
    }

    private func drawOpenModule(_ node: SchematicNode, in context: inout GraphicsContext, showText: Bool) {
        let selected = node.refs.contains(where: selection.contains)
        let shape = RoundedRectangle(cornerRadius: 8).path(in: node.frame)
        context.fill(shape, with: .color(colors.openFill))
        context.stroke(shape, with: .color(selected ? colors.selection : colors.border.opacity(0.7)), lineWidth: selected ? 2 : 1)
        drawToggle(open: true, at: CGPoint(x: node.frame.minX + 6, y: node.frame.minY + 6), in: &context)
        if showText {
            label(node.title, at: CGPoint(x: node.frame.midX, y: node.frame.minY - 3), anchor: .bottom, size: 10.5, color: colors.text, in: &context)
            label(node.subtitle, at: CGPoint(x: node.frame.midX, y: node.frame.maxY + 3), anchor: .top, color: colors.secondaryText, in: &context)
        }
    }

    /// The small square with + or −, which opens or closes a module in place.
    private func drawToggle(open: Bool, at origin: CGPoint, in context: inout GraphicsContext) {
        let box = CGRect(x: origin.x, y: origin.y, width: 11, height: 11)
        context.fill(RoundedRectangle(cornerRadius: 2).path(in: box), with: .color(colors.border))
        var mark = Path()
        mark.move(to: CGPoint(x: box.minX + 3, y: box.midY)); mark.addLine(to: CGPoint(x: box.maxX - 3, y: box.midY))
        if !open { mark.move(to: CGPoint(x: box.midX, y: box.minY + 3)); mark.addLine(to: CGPoint(x: box.midX, y: box.maxY - 3)) }
        context.stroke(mark, with: .color(colors.background), lineWidth: 1.5)
    }

    private func draw(_ node: SchematicNode, selected: Bool, in context: inout GraphicsContext, showText: Bool) {
        let stroke = selected ? colors.selection : colors.border
        let lineWidth: CGFloat = selected ? 2 : 1
        let f = node.frame
        let pinsSelected = Set(node.pins.filter { $0.members.contains { selection.contains(.pin($0)) } }.map(\.id))

        // Pin stubs, ties and dotted continuations.
        for pin in node.pins where node.kind != .port(direction: "IN") && node.kind != .port(direction: "OUT") {
            let edgeX = pin.side == .left ? f.minX : f.maxX
            var stub = Path()
            stub.move(to: CGPoint(x: edgeX, y: pin.point.y)); stub.addLine(to: pin.point)
            context.stroke(stub, with: .color(pinsSelected.contains(pin.id) ? colors.selection : colors.border), lineWidth: pin.isBus ? 2 : 1)
            if pin.hasHiddenConnections {
                var dots = Path()
                let dir: CGFloat = pin.side == .left ? -1 : 1
                dots.move(to: pin.point); dots.addLine(to: CGPoint(x: pin.point.x + dir * 14, y: pin.point.y))
                context.stroke(dots, with: .color(colors.net), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            if let tie = pin.tie, showText {
                label("\(pin.isBus ? "" : "1'b")\(tie)", at: CGPoint(x: pin.point.x + (pin.side == .left ? -2 : 2), y: pin.point.y - 1),
                      anchor: pin.side == .left ? .bottomTrailing : .bottomLeading, size: 8.5, color: colors.secondaryText, in: &context)
            }
        }

        switch node.kind {
        case .port(let direction):
            let shape = PortShape().path(in: f)
            context.fill(shape, with: .color(colors.portFill))
            context.stroke(shape, with: .color(stroke), lineWidth: node.members.count > 1 ? lineWidth + 1 : lineWidth)
            if showText {
                let input = direction == "IN"
                label(node.title, at: CGPoint(x: input ? f.minX - 6 : f.maxX + 6, y: f.midY), anchor: input ? .trailing : .leading,
                      size: 10.5, color: colors.text, in: &context)
            }
            return
        case .module(open: false):
            let shape = Path(f)
            context.fill(shape, with: .color(colors.moduleFill))
            context.stroke(shape, with: .color(stroke), lineWidth: lineWidth)
            drawToggle(open: false, at: CGPoint(x: f.minX + 3, y: f.minY + 3), in: &context)
        case .cell(let symbol):
            if node.isBundle {
                // Stacked copies behind, as Vivado draws a bundle of registers.
                for k in [2, 1] {
                    let back = symbolPath(symbol, in: f.offsetBy(dx: CGFloat(k) * 3, dy: CGFloat(k) * 3))
                    context.fill(back, with: .color(colors.leafFill.opacity(0.7)))
                    context.stroke(back, with: .color(colors.border.opacity(0.6)), lineWidth: 0.8)
                }
            }
            let shape = symbolPath(symbol, in: f)
            context.fill(shape, with: .color(colors.leafFill))
            context.stroke(shape, with: .color(stroke), lineWidth: lineWidth)
            if [.nand, .nor, .xnor, .inverter].contains(symbol) {
                let bubble = Path(ellipseIn: CGRect(x: f.maxX - 8, y: f.midY - 4, width: 8, height: 8))
                context.fill(bubble, with: .color(colors.leafFill))
                context.stroke(bubble, with: .color(stroke), lineWidth: lineWidth)
            }
            if symbol == .xor || symbol == .xnor {
                var extra = Path()
                extra.move(to: CGPoint(x: f.minX - 4, y: f.minY)); extra.addQuadCurve(to: CGPoint(x: f.minX - 4, y: f.maxY), control: CGPoint(x: f.minX + 6, y: f.midY))
                context.stroke(extra, with: .color(stroke), lineWidth: lineWidth)
            }
        default:
            break
        }

        guard showText else { return }
        // Pin names inside boxes; gates keep theirs off, as Vivado does.
        let showPinNames: Bool = {
            if case .cell(let symbol) = node.kind { return !symbol.isGate && symbol != .mux }
            return true
        }()
        for pin in node.pins {
            if pin.isClock, case .cell(.register) = node.kind, pin.side == .left {
                var tri = Path()
                tri.move(to: CGPoint(x: f.minX, y: pin.point.y - 4)); tri.addLine(to: CGPoint(x: f.minX + 6, y: pin.point.y)); tri.addLine(to: CGPoint(x: f.minX, y: pin.point.y + 4))
                context.stroke(tri, with: .color(stroke), lineWidth: 1)
            }
            guard showPinNames else { continue }
            let inset: CGFloat = pin.isClock && pin.side == .left ? 9 : 4
            label(pin.label, at: CGPoint(x: pin.side == .left ? f.minX + inset : f.maxX - 4, y: pin.point.y),
                  anchor: pin.side == .left ? .leading : .trailing, size: 8.5, color: colors.text, in: &context)
        }
        label(node.title, at: CGPoint(x: f.midX, y: f.minY - 3), anchor: .bottom, size: 10, color: colors.text, in: &context)
        label(node.subtitle, at: CGPoint(x: f.midX, y: f.maxY + (node.isBundle ? 9 : 3)), anchor: .top, size: 9, color: colors.secondaryText, in: &context)
    }

    private func symbolPath(_ symbol: SchematicSymbol, in r: CGRect) -> Path {
        var p = Path()
        switch symbol {
        case .and, .nand:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX - 2, y: r.minY))
            p.addArc(center: CGPoint(x: r.midX - 2, y: r.midY), radius: r.height / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .or, .nor, .xor, .xnor:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - (symbol == .or || symbol == .xor ? 0 : 8), y: r.midY), control: CGPoint(x: r.midX + 6, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: r.midX + 6, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + 10, y: r.midY))
        case .inverter, .buffer:
            let tip = symbol == .inverter ? r.maxX - 8 : r.maxX
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: tip, y: r.midY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .mux:
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 10))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 10)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .box, .register, .module:
            p.addRect(r)
        }
        return p
    }
}

// MARK: Mouse and trackpad

struct SchematicMenuItem {
    let title: String
    var enabled = true
    let action: () -> Void
}

/// A transparent layer that turns the mouse and trackpad into schematic actions: two-finger scrolling or dragging pans,
/// pinching or ⌘-scrolling zooms about the pointer, clicks select (⌘ or ⇧ to add), and right-click shows a menu.
private struct SchematicInteraction: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onClick: (CGPoint, Bool, Int) -> Void
    var onHover: (CGPoint) -> Void
    var menu: (CGPoint) -> [SchematicMenuItem]

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onClick = onClick
        view.onHover = onHover
        view.menuItems = menu
    }

    final class InteractionView: NSView {
        var onPan: (CGSize) -> Void = { _ in }
        var onZoom: (CGFloat, CGPoint) -> Void = { _, _ in }
        var onClick: (CGPoint, Bool, Int) -> Void = { _, _, _ in }
        var onHover: (CGPoint) -> Void = { _ in }
        var menuItems: (CGPoint) -> [SchematicMenuItem] = { _ in [] }
        private var dragStart: CGPoint?
        private var dragged = false
        private var actions: [() -> Void] = []

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            dragStart = point(event)
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let now = point(event)
            if !dragged, hypot(now.x - start.x, now.y - start.y) < 3 { return }
            dragged = true
            onPan(CGSize(width: now.x - start.x, height: now.y - start.y))
            dragStart = now
            NSCursor.closedHand.set()
        }

        override func mouseUp(with event: NSEvent) {
            defer { dragStart = nil }
            if dragged { NSCursor.arrow.set(); return }
            let extend = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
            onClick(point(event), extend, event.clickCount)
        }

        override func mouseMoved(with event: NSEvent) { onHover(point(event)) }

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                onZoom(exp(event.scrollingDeltaY * 0.01), point(event))
            } else {
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
                onPan(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            }
        }

        override func magnify(with event: NSEvent) { onZoom(1 + event.magnification, point(event)) }

        override func rightMouseDown(with event: NSEvent) {
            let items = menuItems(point(event))
            guard !items.isEmpty else { return }
            let menu = NSMenu()
            actions = items.map(\.action)
            for (k, item) in items.enumerated() {
                let entry = NSMenuItem(title: item.title, action: item.enabled ? #selector(choose(_:)) : nil, keyEquivalent: "")
                entry.target = self
                entry.tag = k
                entry.isEnabled = item.enabled
                menu.addItem(entry)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func choose(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}
