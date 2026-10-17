import CoreGraphics
import Foundation

// MARK: What a schematic shows

/// What a Schematic window shows: one level of the hierarchy (the top, or a module's contents), optionally limited to
/// some cells, with chosen module instances opened up in place.
public struct SchematicSpec: Hashable, Sendable {
    /// The module whose contents are drawn ("" is the top).
    public var module: String
    /// Only these cells (at any depth), with the modules containing them opened. Nil draws everything in `module`.
    public var only: Set<String>?
    /// Module instances drawn open, with their contents inside.
    public var expanded: Set<String>

    public init(module: String = "", only: Set<String>? = nil, expanded: Set<String> = []) {
        self.module = module
        self.only = only
        self.expanded = expanded
    }
}

/// The symbol a cell is drawn with, after Vivado's: gate shapes and a multiplexer for RTL operators, a register with
/// a clock triangle, a triangle for buffers, and a box for everything else.
public enum SchematicSymbol: String, Sendable {
    case box, register, and, or, xor, nand, nor, xnor, inverter, buffer, mux, module

    public static func forCell(type: String, inputs: Int, outputs: Int, isPrimitive: Bool) -> SchematicSymbol {
        guard isPrimitive else { return .module }
        let t = type.uppercased()
        func rtl(_ name: String) -> Bool { t == "RTL_" + name }
        if rtl("AND") || t.hasPrefix("AND") && t.dropFirst(3).allSatisfy(\.isNumber) { return .and }
        if rtl("OR") || t.hasPrefix("OR") && t.count <= 3 && t.dropFirst(2).allSatisfy(\.isNumber) { return .or }
        if rtl("XOR") || t.hasPrefix("XOR") && t.dropFirst(3).allSatisfy(\.isNumber) { return .xor }
        if rtl("NAND") { return .nand }
        if rtl("NOR") { return .nor }
        if rtl("XNOR") { return .xnor }
        if rtl("INV") || t == "INV" { return .inverter }
        if rtl("MUX") || t.hasPrefix("MUXF") { return .mux }
        if t.hasPrefix("RTL_REG") || t.hasPrefix("RTL_LATCH") || t.hasPrefix("FD") || (t.hasPrefix("LD") && t.count <= 5) { return .register }
        if inputs == 1, outputs == 1, ["IBUF", "OBUF", "BUFG", "BUF", "IBUFG", "BUFH", "BUFR", "BUFIO", "OBUFT"].contains(t) || t.hasPrefix("RTL_BUF") {
            return .buffer
        }
        return .box
    }

    /// Gates and buffers draw the type inside their shape; a box and a register write it underneath.
    public var isGate: Bool { [.and, .or, .xor, .nand, .nor, .xnor, .inverter, .buffer].contains(self) }
}

// MARK: The result

public struct SchematicPin: Identifiable, Equatable, Sendable {
    public enum Side: Sendable { case left, right }

    /// The node's id and the pin's bus name.
    public let id: String
    /// `D`, `O[7:0]`, a port's name.
    public let label: String
    public let side: Side
    /// Where wires attach, at the end of the pin's stub.
    public var point: CGPoint
    public let isBus: Bool
    public let isClock: Bool
    /// The design pins (or ports) it stands for, one per bit.
    public let members: [String]
    /// A constant it is tied to (`0`, `1`), drawn as a label instead of a wire to a GND or VCC cell.
    public var tie: String?
    /// Part of its net goes to logic this schematic doesn't show (drawn dotted, as Vivado does).
    public var hasHiddenConnections: Bool
}

public struct SchematicNode: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case port(direction: String)
        case cell(SchematicSymbol)
        /// A module instance; `open` draws its contents inside.
        case module(open: Bool)
    }

    public let id: String
    public let kind: Kind
    /// The object it stands for: the cell, or the first port of a port bus.
    public let ref: DesignObjectRef
    /// Instance name (above), and the cell or module type (below).
    public let title: String
    public let subtitle: String
    public var frame: CGRect
    public var pins: [SchematicPin]
    /// How deeply it is nested in open modules: drawing outer ones first keeps the inner ones on top.
    public var depth: Int
    /// Every object it stands for: the ports of a port bus, or the cells of a bundle (`count_reg[7:0]` is eight
    /// registers drawn stacked, as Vivado bundles them). Empty for a single cell.
    public let members: [String]

    /// Whether it draws a given object: itself, or one of its members.
    public func stands(for ref: DesignObjectRef) -> Bool {
        self.ref == ref || members.contains(ref.name) && (ref.kind == .cell || ref.kind == .port)
    }

    /// Several cells drawn as one stacked symbol.
    public var isBundle: Bool {
        if case .port = kind { return false }
        return members.count > 1
    }

    public var isOpenModule: Bool { kind == .module(open: true) }
}

public struct SchematicWire: Identifiable, Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let from: CGPoint
        public let to: CGPoint
    }

    public let id: String
    public var segments: [Segment]
    public let isBus: Bool
    /// The design nets it carries (every bit, at every level it passes).
    public let nets: [String]
    /// The name to show: the net, or the bus (`count[7:0]`).
    public let label: String
}

public struct SchematicLayout: Equatable, Sendable {
    public var size: CGSize
    public var nodes: [SchematicNode]
    public var wires: [SchematicWire]

    public var cellCount: Int { nodes.filter { if case .cell = $0.kind { return true }; if case .module = $0.kind { return true }; return false }.count }
    public var portCount: Int { nodes.filter { if case .port = $0.kind { return true } else { return false } }.reduce(0) { $0 + $1.members.count } }
    public var netCount: Int { Set(wires.flatMap(\.nets)).count }
}

public enum SchematicError: DescribedError, Equatable {
    case tooLarge(cells: Int, limit: Int)
    case noConnectivity

    public var description: String {
        switch self {
        case .tooLarge(let cells, let limit):
            "This level has \(cells) cells, more than a schematic can draw readably (\(limit)). Open one of its modules, or select some cells and choose Schematic."
        case .noConnectivity:
            "This build didn't save how cells connect. Run synthesis again to see the schematic."
        }
    }
}

// MARK: Layout

/// Lays out a schematic the way Vivado draws one: signals flow left to right in layers, ports on the outside edges,
/// feedback (a register's output coming back round to the logic in front of it) looped back under the cells, and every
/// wire made of horizontal and vertical segments with its own track between layers.
public struct SchematicBuilder {
    public static let maxCellsPerLevel = 1500

    /// Sizes, in points at 100%.
    enum Metrics {
        static let pinPitch: CGFloat = 16
        static let stub: CGFloat = 10
        static let charWidth: CGFloat = 6.4
        static let labelSpace: CGFloat = 16           // above (instance name) and below (type)
        static let nodeGap: CGFloat = 22
        static let trackPitch: CGFloat = 8
        static let gapMargin: CGFloat = 26
        static let lanePitch: CGFloat = 10
        static let padding: CGFloat = 30
        static let openInset: CGFloat = 18
        static let openHeader: CGFloat = 26
    }

    let design: DesignSnapshot

    public init(design: DesignSnapshot) { self.design = design }

    public func layout(_ spec: SchematicSpec) throws -> SchematicLayout {
        guard design.hasConnectivity else { throw SchematicError.noConnectivity }
        var block = try level(spec.module, spec: spec, depth: 0)
        // Leave room for labels all round.
        let shift = CGPoint(x: Metrics.padding - block.bounds.minX, y: Metrics.padding - block.bounds.minY)
        block.translate(by: shift)
        return SchematicLayout(size: CGSize(width: block.bounds.width + Metrics.padding * 2, height: block.bounds.height + Metrics.padding * 2),
                               nodes: block.nodes.sorted { $0.depth < $1.depth }, wires: block.wires)
    }

    // MARK: One level

    /// A laid-out level, in its own coordinates. `terminals` are the module's boundary pins as seen from inside.
    struct Block {
        var nodes: [SchematicNode] = []
        var wires: [SchematicWire] = []
        var bounds: CGRect = .zero
        /// Boundary pin groups (by bus name) and where they meet the block's left or right edge.
        var terminals: [(group: String, side: SchematicPin.Side, y: CGFloat, members: [String])] = []

        mutating func translate(by d: CGPoint) {
            for i in nodes.indices {
                nodes[i].frame = nodes[i].frame.offsetBy(dx: d.x, dy: d.y)
                for j in nodes[i].pins.indices { nodes[i].pins[j].point.x += d.x; nodes[i].pins[j].point.y += d.y }
            }
            for i in wires.indices {
                wires[i].segments = wires[i].segments.map {
                    .init(from: CGPoint(x: $0.from.x + d.x, y: $0.from.y + d.y), to: CGPoint(x: $0.to.x + d.x, y: $0.to.y + d.y))
                }
            }
            bounds = bounds.offsetBy(dx: d.x, dy: d.y)
            terminals = terminals.map { ($0.group, $0.side, $0.y + d.y, $0.members) }
        }
    }

    /// A node during layout: what it is, its pin groups, and (for an open module) its contents.
    struct Item {
        var node: SchematicNode
        var inner: Block?
        var isTerminal = false
        var layer = 0
        var order = 0
        var pinOffsets: [String: CGFloat] = [:]       // pin group → y offset from the top of the frame
        var size: CGSize { node.frame.size }
    }

    /// One wire between two pin groups at this level.
    struct Link {
        let from: (node: Int, group: String)
        var to: [(node: Int, group: String)]
        var nets: [String]
        var width: Int
    }

    func level(_ module: String, spec: SchematicSpec, depth: Int) throws -> Block {
        // Which cells to draw at this level.
        let children = design.cells.filter { $0.parentPath == module && $0.type != "GND" && $0.type != "VCC" }
        let included = children.filter { cell in
            guard let only = spec.only else { return true }
            return only.contains(cell.name) || (!cell.isPrimitive && only.contains { $0.hasPrefix(cell.name + "/") })
        }
        if included.count > Self.maxCellsPerLevel { throw SchematicError.tooLarge(cells: included.count, limit: Self.maxCellsPerLevel) }

        var items: [Item] = []
        var index: [String: Int] = [:]
        func add(_ item: Item) { index[item.node.id] = items.count; items.append(item) }
        /// Which node draws each cell (a bundle draws several).
        var nodeOfCell: [String: Int] = [:]

        // Primitives named `name[0]`, `name[1]`... of one type are bundled into one stacked symbol, as Vivado does.
        var bundles: [String: [DesignCell]] = [:]
        // Only RTL registers: in a synthesized netlist Vivado draws each flip-flop on its own.
        for cell in included where cell.isPrimitive && cell.type.hasPrefix("RTL_") {
            let base = DesignNet.busName(of: cell.localName)
            if base != cell.localName { bundles["\(base)|\(cell.type)", default: []].append(cell) }
        }
        var bundled: Set<String> = []

        // Cells and module instances.
        for cell in included where !bundled.contains(cell.name) {
            let open = !cell.isPrimitive && (spec.expanded.contains(cell.name) || spec.only != nil)
            if open {
                var inner = try level(cell.name, spec: spec, depth: depth + 1)
                add(openModule(cell, inner: &inner, depth: depth))
                nodeOfCell[cell.name] = items.count - 1
                continue
            }
            let key = "\(DesignNet.busName(of: cell.localName))|\(cell.type)"
            if cell.isPrimitive, let group = bundles[key], group.count > 1 {
                add(cellItem(group, depth: depth))
                for member in group { bundled.insert(member.name); nodeOfCell[member.name] = items.count - 1 }
            } else {
                add(cellItem([cell], depth: depth))
                nodeOfCell[cell.name] = items.count - 1
            }
        }

        // Ports at the top; the module's own boundary pins inside a module.
        if module.isEmpty {
            // A schematic of chosen cells shows only the ports wired to them.
            let drawnCells = Set(included.map(\.name))
            func reachesDrawnCell(_ port: DesignPort) -> Bool {
                guard spec.only != nil else { return true }
                guard let net = design.net(ofPort: port.name).flatMap(design.net(named:)) else { return false }
                return net.endpoints.contains { end in
                    !end.isPort && drawnCells.contains(design.pins[end.name]?.cellName ?? "")
                }
            }
            for (bus, ports) in portBuses() where ports.contains(where: reachesDrawnCell) {
                add(portItem(bus: bus, ports: ports, depth: depth))
            }
        } else {
            for group in pinGroups(design.pins(of: module)) {
                add(terminalItem(module: module, group: group, depth: depth))
            }
        }

        // Wires: group each net's ends by pin group, find the driver, and link it to the rest.
        var links: [String: Link] = [:]
        var linkOrder: [String] = []
        var ties: [String: String] = [:]                 // node|group → constant
        var hidden: Set<String> = []                     // node|group with connections not drawn
        func endpoint(_ end: NetEndpoint) -> (node: Int, group: String, drives: Bool)? {
            if end.isPort {
                guard module.isEmpty, let port = design.port(named: end.name) else { return nil }
                let bus = DesignNet.busName(of: port.name)
                guard let i = index["port:" + bus] else { return nil }
                return (i, bus, port.direction == "IN")
            }
            guard let pin = design.pins[end.name] else { return nil }
            if pin.cellName == module {
                guard let i = index["term:" + module + "/" + pin.busName] else { return nil }
                return (i, pin.busName, pin.direction == "IN")
            }
            guard let i = nodeOfCell[pin.cellName] else { return nil }
            if items[i].inner != nil {
                // An open module: its pins sit on its edges and the wire continues inside.
                return (i, pin.busName, pin.direction == "OUT")
            }
            return (i, pin.busName, pin.direction != "IN")
        }
        for net in design.nets(in: module) {
            let ends = net.endpoints.filter { !$0.isPort || module.isEmpty }
            if net.isPowerOrGround {
                for end in ends { if let e = endpoint(end) { ties["\(e.node)|\(e.group)"] = net.type == "POWER" ? "1" : "0" } }
                continue
            }
            var drawn: [(node: Int, group: String, drives: Bool)] = []
            var anyHidden = false
            for end in ends {
                if let e = endpoint(end) {
                    if !drawn.contains(where: { $0.node == e.node && $0.group == e.group }) { drawn.append(e) }
                } else if !end.isPort {
                    anyHidden = true
                }
            }
            if anyHidden { for e in drawn { hidden.insert("\(e.node)|\(e.group)") } }
            guard drawn.count >= 2 else { continue }
            let driver = drawn.first(where: \.drives) ?? drawn[0]
            let key = "\(driver.node)|\(driver.group)"
            let sinks = drawn.filter { !($0.node == driver.node && $0.group == driver.group) }
            if links[key] == nil {
                links[key] = Link(from: (driver.node, driver.group), to: [], nets: [], width: 0)
                linkOrder.append(key)
            }
            links[key]?.nets.append(net.name)
            links[key]?.width += 1
            for sink in sinks where !(links[key]?.to.contains { $0.node == sink.node && $0.group == sink.group } ?? false) {
                links[key]?.to.append((sink.node, sink.group))
            }
        }
        for i in items.indices {
            for j in items[i].node.pins.indices {
                let key = "\(i)|\(groupName(items[i].node.pins[j]))"
                items[i].node.pins[j].tie = ties[key]
                items[i].node.pins[j].hasHiddenConnections = hidden.contains(key)
            }
        }

        return place(items: items, links: linkOrder.compactMap { links[$0] }, module: module)
    }

    private func groupName(_ pin: SchematicPin) -> String {
        pin.id.split(separator: "|").last.map(String.init) ?? pin.id
    }

    // MARK: Items

    struct PinGroup {
        let name: String
        let members: [DesignPin]
        var direction: String { members.first?.direction ?? "IN" }
        var label: String {
            guard members.count > 1 || members.first?.pinName != name else { return name }
            let bits = members.compactMap { pin -> Int? in
                guard let open = pin.pinName.lastIndex(of: "[") else { return nil }
                return Int(pin.pinName[pin.pinName.index(after: open)..<pin.pinName.index(before: pin.pinName.endIndex)])
            }
            guard let lo = bits.min(), let hi = bits.max() else { return name }
            return "\(name)[\(hi):\(lo)]"
        }
    }

    func pinGroups(_ pins: [DesignPin]) -> [PinGroup] {
        var order: [String] = []
        var groups: [String: [DesignPin]] = [:]
        for pin in pins {
            if groups[pin.busName] == nil { order.append(pin.busName) }
            groups[pin.busName, default: []].append(pin)
        }
        return order.map { PinGroup(name: $0, members: groups[$0] ?? []) }
    }

    func width(_ text: String) -> CGFloat { CGFloat(text.count) * Metrics.charWidth }

    /// A cell, or a bundle of same-type cells drawn stacked (their pins grouped by name: every bit's `Q` is one pin).
    func cellItem(_ cells: [DesignCell], depth: Int) -> Item {
        let cell = cells[0]
        let groups = pinGroups(cells.flatMap { design.pins(of: $0.name) })
        let inputs = groups.filter { $0.direction == "IN" }
        let outputs = groups.filter { $0.direction != "IN" }
        let symbol = SchematicSymbol.forCell(type: cell.type, inputs: inputs.count, outputs: outputs.count, isPrimitive: cell.isPrimitive)
        let rows = CGFloat(max(inputs.count, outputs.count, 1))
        let size: CGSize
        switch symbol {
        case .inverter, .buffer: size = CGSize(width: 34, height: max(26, rows * Metrics.pinPitch))
        case .and, .or, .xor, .nand, .nor, .xnor: size = CGSize(width: 40, height: max(30, rows * Metrics.pinPitch + 6))
        case .mux: size = CGSize(width: 40, height: max(44, rows * Metrics.pinPitch + 16))
        default:
            let left = inputs.map { width($0.label) }.max() ?? 0
            let right = outputs.map { width($0.label) }.max() ?? 0
            size = CGSize(width: max(left + right + 28, 56), height: rows * Metrics.pinPitch + 12)
        }
        let title: String
        if cells.count > 1 {
            let bits = cells.compactMap { c -> Int? in
                guard let open = c.localName.lastIndex(of: "[") else { return nil }
                return Int(c.localName[c.localName.index(after: open)..<c.localName.index(before: c.localName.endIndex)])
            }
            title = "\(DesignNet.busName(of: cell.localName))[\(bits.max() ?? 0):\(bits.min() ?? 0)]"
        } else {
            title = cell.localName
        }
        let id = cells.count > 1 ? (cell.parentPath.isEmpty ? title : cell.parentPath + "/" + title) : cell.name
        var item = Item(node: SchematicNode(id: id, kind: cell.isPrimitive ? .cell(symbol) : .module(open: false),
                                            ref: .cell(cell.name), title: title, subtitle: cell.type,
                                            frame: CGRect(origin: .zero, size: size), pins: [], depth: depth,
                                            members: cells.count > 1 ? cells.map(\.name) : []))
        item.node.pins = sidePins(node: id, inputs: inputs, outputs: outputs, height: size.height, offsets: &item.pinOffsets)
        return item
    }

    func sidePins(node: String, inputs: [PinGroup], outputs: [PinGroup], height: CGFloat, offsets: inout [String: CGFloat]) -> [SchematicPin] {
        var pins: [SchematicPin] = []
        for (side, list) in [(SchematicPin.Side.left, inputs), (.right, outputs)] {
            let span = CGFloat(max(list.count - 1, 0)) * Metrics.pinPitch
            let start = (height - span) / 2
            for (k, group) in list.enumerated() {
                let y = start + CGFloat(k) * Metrics.pinPitch
                offsets[group.name] = y
                pins.append(SchematicPin(id: "\(node)|\(group.name)", label: group.label, side: side, point: CGPoint(x: 0, y: y),
                                         isBus: group.members.count > 1, isClock: group.members.contains(where: \.isClock),
                                         members: group.members.map(\.name), tie: nil, hasHiddenConnections: false))
            }
        }
        return pins
    }

    func portBuses() -> [(String, [DesignPort])] {
        design.portBuses.map { ($0.name, $0.ports.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    func portItem(bus: String, ports: [DesignPort], depth: Int) -> Item {
        let input = ports.first?.direction == "IN"
        let label = ports.count > 1 ? "\(bus)[\(ports.count - 1):0]" : bus
        let size = CGSize(width: 30, height: 18)
        var item = Item(node: SchematicNode(id: "port:" + bus, kind: .port(direction: ports.first?.direction ?? "IN"),
                                            ref: .port(ports.first?.name ?? bus), title: label, subtitle: "",
                                            frame: CGRect(origin: .zero, size: size), pins: [], depth: depth, members: ports.map(\.name)))
        item.pinOffsets[bus] = size.height / 2
        item.node.pins = [SchematicPin(id: "port:\(bus)|\(bus)", label: label, side: input ? .right : .left,
                                       point: CGPoint(x: 0, y: size.height / 2), isBus: ports.count > 1, isClock: false,
                                       members: ports.map(\.name), tie: nil, hasHiddenConnections: false)]
        return item
    }

    func terminalItem(module: String, group: PinGroup, depth: Int) -> Item {
        let id = "term:" + module + "/" + group.name
        let input = group.direction == "IN"
        var item = Item(node: SchematicNode(id: id, kind: .port(direction: group.direction), ref: .pin(group.members.first?.name ?? id),
                                            title: group.label, subtitle: "", frame: .zero, pins: [], depth: depth,
                                            members: group.members.map(\.name)))
        item.isTerminal = true
        item.pinOffsets[group.name] = 0
        item.node.pins = [SchematicPin(id: "\(id)|\(group.name)", label: group.label, side: input ? .right : .left, point: .zero,
                                       isBus: group.members.count > 1, isClock: false, members: group.members.map(\.name),
                                       tie: nil, hasHiddenConnections: false)]
        return item
    }

    func openModule(_ cell: DesignCell, inner: inout Block, depth: Int) -> Item {
        // The box is the inner block plus a margin, with the boundary pins on its edges where the inner wires meet them.
        let origin = CGPoint(x: Metrics.openInset - inner.bounds.minX, y: Metrics.openHeader - inner.bounds.minY)
        inner.translate(by: origin)
        let size = CGSize(width: inner.bounds.maxX + Metrics.openInset, height: inner.bounds.maxY + Metrics.openInset)
        var item = Item(node: SchematicNode(id: cell.name, kind: .module(open: true), ref: .cell(cell.name), title: cell.localName,
                                            subtitle: cell.type, frame: CGRect(origin: .zero, size: size), pins: [], depth: depth,
                                            members: []))
        for t in inner.terminals {
            item.pinOffsets[t.group] = t.y
            item.node.pins.append(SchematicPin(id: "\(cell.name)|\(t.group)", label: t.group, side: t.side, point: CGPoint(x: 0, y: t.y),
                                               isBus: t.members.count > 1, isClock: false, members: t.members, tie: nil,
                                               hasHiddenConnections: false))
        }
        item.inner = inner
        return item
    }

    // MARK: Placement and routing

    func place(items input: [Item], links: [Link], module: String) -> Block {
        var items = input
        let n = items.count
        func isSource(_ i: Int) -> Bool {
            if case .port(let dir) = items[i].node.kind { return dir == "IN" }
            return false
        }
        func isSink(_ i: Int) -> Bool {
            if case .port(let dir) = items[i].node.kind { return dir != "IN" }
            return false
        }
        func isRegister(_ i: Int) -> Bool { items[i].node.kind == .cell(.register) }

        // Node-level edges, and the ones that close a loop treated as feedback. As in Vivado, a loop is broken where a
        // register's output comes back round, so the logic in front of a register sits to its left.
        var succ = Array(repeating: [Int](), count: n)
        for link in links {
            for t in link.to where t.node != link.from.node && !succ[link.from.node].contains(t.node) { succ[link.from.node].append(t.node) }
        }
        let component = Self.components(succ)
        var back: Set<[Int]> = []
        for u in 0..<n where isRegister(u) { for v in succ[u] where component[u] == component[v] { back.insert([u, v]) } }
        // Whatever loops are left (through logic alone, or through a module) are broken where a depth-first search closes them.
        var state = Array(repeating: 0, count: n)      // 0 new, 1 on stack, 2 done
        func dfs(_ u: Int) {
            state[u] = 1
            for v in succ[u] where !back.contains([u, v]) {
                if state[v] == 1 { back.insert([u, v]) } else if state[v] == 0 { dfs(v) }
            }
            state[u] = 2
        }
        for i in 0..<n where isSource(i) && state[i] == 0 { dfs(i) }
        for i in 0..<n where state[i] == 0 && !isSink(i) { dfs(i) }
        for i in 0..<n where state[i] == 0 { dfs(i) }

        // Longest-path layers: inputs in 0, cells from 1, outputs after the last cell.
        var pred = Array(repeating: [Int](), count: n)
        var forward = Array(repeating: [Int](), count: n)
        for u in 0..<n { for v in succ[u] where !back.contains([u, v]) { pred[v].append(u); forward[u].append(v) } }
        var layer = Array(repeating: -1, count: n)
        func layerOf(_ i: Int) -> Int {
            if layer[i] >= 0 { return layer[i] }
            if isSource(i) { layer[i] = 0; return 0 }
            layer[i] = 1                                   // guards against any loop the search missed
            let l = pred[i].filter { !isSink($0) }.map { layerOf($0) + 1 }.max() ?? 1
            layer[i] = max(l, 1)
            return layer[i]
        }
        for i in 0..<n where !isSink(i) { _ = layerOf(i) }
        let lastCell = (0..<n).filter { !isSink($0) }.map { layer[$0] }.max() ?? 0
        // Logic fed only by feedback (a register's next-state logic) sits just in front of what it drives, and output
        // buffers sit by the output ports, rather than everything bunching up on the left.
        // "Free" logic is reached from no input, only from feedback (or other free logic); it moves right, latest first.
        var free = Array(repeating: false, count: n)
        let byLayer = (0..<n).filter { !isSource($0) && !isSink($0) }.sorted { layer[$0] < layer[$1] }
        for i in byLayer { free[i] = pred[i].allSatisfy { free[$0] } }
        for i in byLayer.reversed() where free[i] && !forward[i].isEmpty {
            layer[i] = max(layer[i], (forward[i].map { isSink($0) ? lastCell + 1 : layer[$0] }.min() ?? 1) - 1)
        }
        for i in 0..<n where !isSource(i) && !isSink(i) && !forward[i].isEmpty && forward[i].allSatisfy(isSink) { layer[i] = max(layer[i], lastCell) }
        for i in 0..<n where isSink(i) { layer[i] = lastCell + 1 }
        let layerCount = (layer.max() ?? 0) + 1
        for i in 0..<n { items[i].layer = layer[i] }

        // Every link becomes a chain of hops through the layers it crosses, with one shared bend point per wire per layer.
        // A forward wire bends in the gap after each layer; a feedback wire leaves its driver to the right, comes back
        // left through the layers just under the cells, and goes into its load from the left, as Vivado draws loops.
        struct Hop { let from: Int; let to: Int; let fromGroup: String?; let toGroup: String?; let wire: Int; let gap: Int }
        var dummies: [(layer: Int, wire: Int, backward: Bool)] = []
        var dummyIndex: [String: Int] = [:]
        func dummy(_ w: Int, _ l: Int, backward: Bool) -> Int {
            let key = "\(w)@\(l)\(backward ? "<" : ">")"
            if let d = dummyIndex[key] { return d }
            dummies.append((l, w, backward))
            dummyIndex[key] = n + dummies.count - 1
            return n + dummies.count - 1
        }
        var hops: [Hop] = []
        var seen: Set<[Int]> = []
        func hop(_ h: Hop) {
            if seen.insert([h.from, h.to, h.wire]).inserted { hops.append(h) }
        }
        for (w, link) in links.enumerated() {
            for t in link.to {
                let a = link.from.node, b = t.node
                var prev = a
                var prevGroup: String? = link.from.group
                if layer[b] > layer[a] {
                    for l in (layer[a] + 1)..<layer[b] {
                        let d = dummy(w, l, backward: false)
                        hop(Hop(from: prev, to: d, fromGroup: prevGroup, toGroup: nil, wire: w, gap: l - 1))
                        prev = d
                        prevGroup = nil
                    }
                } else {
                    var gap = layer[a]
                    for l in stride(from: layer[a], through: layer[b], by: -1) {
                        let d = dummy(w, l, backward: true)
                        hop(Hop(from: prev, to: d, fromGroup: prevGroup, toGroup: nil, wire: w, gap: gap))
                        prev = d
                        prevGroup = nil
                        gap = l - 1
                    }
                }
                hop(Hop(from: prev, to: b, fromGroup: prevGroup, toGroup: t.group, wire: w, gap: max(layer[b] - 1, 0)))
            }
        }
        let total = n + dummies.count
        func layerOfAny(_ i: Int) -> Int { i < n ? layer[i] : dummies[i - n].layer }

        // Order within layers: start in the order things were found, then a few barycenter sweeps. A feedback wire's
        // bend point beside its driver or load stays just under it.
        var layers = Array(repeating: [Int](), count: layerCount)
        for i in 0..<total { layers[layerOfAny(i)].append(i) }
        var position = Array(repeating: 0.0, count: total)
        func renumber() { for l in layers { for (k, i) in l.enumerated() { position[i] = Double(k) } } }
        renumber()
        var leftOf = Array(repeating: [Int](), count: total)
        var rightOf = Array(repeating: [Int](), count: total)
        var beside = Array(repeating: [Int](), count: total)
        for h in hops {
            let lf = layerOfAny(h.from), lt = layerOfAny(h.to)
            if lf < lt { rightOf[h.from].append(h.to); leftOf[h.to].append(h.from) }
            else if lf > lt { leftOf[h.from].append(h.to); rightOf[h.to].append(h.from) }
            else { beside[h.from].append(h.to); beside[h.to].append(h.from) }
        }
        func key(_ i: Int, _ side: [[Int]]) -> Double {
            if i >= n, let owner = beside[i].first(where: { $0 < n }) { return position[owner] + 0.5 }
            let list = side[i]
            guard !list.isEmpty else { return position[i] }
            return list.map { position[$0] }.reduce(0, +) / Double(list.count)
        }
        func sortLayer(_ l: Int, _ side: [[Int]]) {
            let keys = Dictionary(uniqueKeysWithValues: layers[l].map { ($0, key($0, side)) })
            layers[l].sort { keys[$0]! != keys[$1]! ? keys[$0]! < keys[$1]! : position[$0] < position[$1] }
            renumber()
        }
        for _ in 0..<6 {
            for l in 1..<max(layerCount, 1) { sortLayer(l, leftOf) }
            if layerCount > 1 { for l in stride(from: layerCount - 2, through: 0, by: -1) { sortLayer(l, rightOf) } }
        }

        // Vertical placement: each node as close as possible to the pins that drive it, without overlapping.
        var top = Array(repeating: CGFloat(0), count: total)
        func height(_ i: Int) -> CGFloat { i < n ? items[i].size.height : 0 }
        func offsetOf(_ i: Int, _ group: String?) -> CGFloat { i < n ? (group.flatMap { items[i].pinOffsets[$0] } ?? height(i) / 2) : 0 }
        func pinY(_ i: Int, _ group: String?) -> CGFloat { top[i] + offsetOf(i, group) }
        func clearance(_ i: Int) -> CGFloat {
            guard i < n else { return Metrics.lanePitch }
            if items[i].isTerminal { return Metrics.pinPitch }
            if case .port = items[i].node.kind { return Metrics.nodeGap }
            return Metrics.nodeGap + Metrics.labelSpace * 2
        }
        // First pass, left to right: a cell level with the cells already placed that drive it (the nearest count most),
        // a bend point level with the one before it on its wire.
        var drivers = Array(repeating: [(other: Int, otherGroup: String, ownGroup: String, weight: CGFloat)](), count: n)
        for link in links {
            for t in link.to where layer[link.from.node] < layer[t.node] {
                drivers[t.node].append((link.from.node, link.from.group, t.group, 1 / CGFloat(layer[t.node] - layer[link.from.node])))
            }
        }
        var arriving: [Int: Hop] = [:]           // a forward bend point → the hop into it from the left
        for h in hops where h.to >= n && layerOfAny(h.from) < layerOfAny(h.to) && arriving[h.to] == nil { arriving[h.to] = h }
        for l in 0..<layerCount {
            var floor: CGFloat = 0
            for i in layers[l] {
                var pulls: [(y: CGFloat, w: CGFloat)] = []
                if i < n {
                    pulls = drivers[i].map { (pinY($0.other, $0.otherGroup) - offsetOf(i, $0.ownGroup), $0.weight) }
                } else if let h = arriving[i] {
                    pulls = [(pinY(h.from, h.fromGroup), 1)]
                }
                var want = floor
                if !pulls.isEmpty {
                    let sorted = pulls.sorted { $0.y < $1.y }
                    let half = sorted.reduce(0) { $0 + $1.w } / 2
                    var running: CGFloat = 0
                    want = sorted.last!.y
                    for p in sorted { running += p.w; if running >= half { want = p.y; break } }
                    want = max(floor, want)
                }
                top[i] = want
                floor = want + height(i) + clearance(i)
            }
        }
        // Then settle every layer, sweeping right and left: each node as near as it can be to the pins it connects to on
        // both sides, keeping the layer's order and spacing (an isotonic regression, solved exactly by pooling). A cell
        // isn't pulled by the feedback bend point tucked under it.
        // Cells are pulled by the cells they connect to (a distant one less), never by where a wire bends: otherwise a
        // cell follows the wires under the one before it, they follow it, and a chain slides downhill. Bend points follow
        // their wire.
        var neighbours = Array(repeating: [(other: Int, otherGroup: String?, ownGroup: String?, weight: CGFloat)](), count: total)
        for h in hops where h.from >= n || h.to >= n {
            let w: CGFloat = h.from >= n && h.to >= n ? 8 : 2
            if h.to >= n { neighbours[h.to].append((h.from, h.fromGroup, h.toGroup, w)) }
            if h.from >= n { neighbours[h.from].append((h.to, h.toGroup, h.fromGroup, w)) }
        }
        for link in links {
            for t in link.to where t.node != link.from.node {
                let a = link.from.node, b = t.node
                let w = 1 / CGFloat(max(abs(layer[b] - layer[a]), 1))
                neighbours[a].append((b, t.group, link.from.group, w))
                neighbours[b].append((a, link.from.group, t.group, w))
            }
        }
        func settle(_ l: Int) {
            let nodes = layers[l]
            guard !nodes.isEmpty else { return }
            var offsets: [CGFloat] = []
            var running: CGFloat = 0
            for i in nodes { offsets.append(running); running += height(i) + clearance(i) }
            // Targets in "slack" coordinates: position minus the room everything above it needs.
            // A long wire's bend points pull hardest on each other, so it runs straight (the weights ELK uses).
            var targets: [CGFloat] = []
            var weights: [CGFloat] = []
            for (k, i) in nodes.enumerated() {
                // The weighted median, not the mean: anywhere between two pulls is as good, so a wire pulled by both
                // its ends stays straight from one of them and bends once, instead of sloping across from one to the other.
                let pulls = neighbours[i].map { (y: pinY($0.other, $0.otherGroup) - offsetOf(i, $0.ownGroup), w: $0.weight) }
                    .sorted { $0.y < $1.y }
                let weight = pulls.reduce(0) { $0 + $1.w }
                var want = top[i]
                if weight > 0 {
                    var running: CGFloat = 0
                    var low = pulls[0].y, high = pulls[pulls.count - 1].y
                    for p in pulls { running += p.w; if running >= weight / 2 { low = p.y; break } }
                    running = 0
                    for p in pulls { running += p.w; if running > weight / 2 { high = p.y; break } }
                    want = min(max(top[i], low), high)
                }
                targets.append(want - offsets[k])
                weights.append(max(weight, 0.5))
            }
            // Pool adjacent violators: merge runs whose targets go down, so the result never does.
            var blocks: [(sum: CGFloat, count: CGFloat, size: Int)] = []
            for (t, w) in zip(targets, weights) {
                blocks.append((t * w, w, 1))
                while blocks.count > 1, blocks[blocks.count - 2].sum / blocks[blocks.count - 2].count > blocks[blocks.count - 1].sum / blocks[blocks.count - 1].count {
                    let last = blocks.removeLast()
                    blocks[blocks.count - 1] = (blocks[blocks.count - 1].sum + last.sum, blocks[blocks.count - 1].count + last.count, blocks[blocks.count - 1].size + last.size)
                }
            }
            var k = 0
            for block in blocks {
                let value = block.sum / block.count
                for _ in 0..<block.size { top[nodes[k]] = value + offsets[k]; k += 1 }
            }
        }
        for _ in 0..<6 {
            for l in 0..<layerCount { settle(l) }
            for l in stride(from: layerCount - 1, through: 0, by: -1) { settle(l) }
        }

        // Tracks: each wire's vertical run in a gap gets a column, shared by its branches, apart from overlapping runs.
        var runs: [Int: [Int: (lo: CGFloat, hi: CGFloat)]] = [:]       // gap → wire → span
        for h in hops {
            let a = pinY(h.from, h.fromGroup), b = pinY(h.to, h.toGroup)
            let span = runs[h.gap]?[h.wire]
            runs[h.gap, default: [:]][h.wire] = (min(a, b, span?.lo ?? .greatestFiniteMagnitude), max(a, b, span?.hi ?? -.greatestFiniteMagnitude))
        }
        var track: [Int: [Int: Int]] = [:]       // gap → wire → column
        var columns: [Int: Int] = [:]
        for (gap, spans) in runs {
            var ends: [CGFloat] = []              // the bottom of the last run in each column
            for (wire, span) in spans.sorted(by: { $0.value.lo != $1.value.lo ? $0.value.lo < $1.value.lo : $0.key < $1.key }) {
                if let c = ends.firstIndex(where: { $0 + Metrics.trackPitch < span.lo }) {
                    ends[c] = span.hi
                    track[gap, default: [:]][wire] = c
                } else {
                    track[gap, default: [:]][wire] = ends.count
                    ends.append(span.hi)
                }
            }
            columns[gap] = ends.count
        }

        // Horizontal placement: layers left to right, each gap as wide as its tracks need.
        var layerX = Array(repeating: CGFloat(0), count: layerCount)
        var layerWidth = Array(repeating: CGFloat(0), count: layerCount)
        for l in 0..<layerCount {
            layerWidth[l] = layers[l].filter { $0 < n }.map { items[$0].size.width + (items[$0].isTerminal ? 0 : Metrics.stub * 2) }.max() ?? 0
        }
        var x: CGFloat = 0
        for l in 0..<layerCount {
            layerX[l] = x
            x += layerWidth[l] + Metrics.gapMargin * 2 + CGFloat(columns[l] ?? 0) * Metrics.trackPitch
        }
        func trackX(_ gap: Int, _ wire: Int) -> CGFloat {
            layerX[gap] + layerWidth[gap] + Metrics.gapMargin + CGFloat(track[gap]?[wire] ?? 0) * Metrics.trackPitch
        }

        // Final frames and pin points.
        var block = Block()
        for i in 0..<n {
            var item = items[i]
            let l = layer[i]
            let w = item.size.width
            let left: CGFloat
            if item.isTerminal {
                left = isSource(i) || item.node.pins.first?.side == .right ? layerX[l] : layerX[l] + layerWidth[l]
            } else if case .port = item.node.kind {
                left = isSource(i) ? layerX[l] + layerWidth[l] - w - Metrics.stub : layerX[l] + Metrics.stub
            } else {
                left = layerX[l] + (layerWidth[l] - w) / 2
            }
            item.node.frame = CGRect(x: left, y: top[i], width: w, height: item.size.height)
            for j in item.node.pins.indices {
                let pin = item.node.pins[j]
                let offset = item.pinOffsets[groupName(pin)] ?? item.size.height / 2
                let stub = item.isTerminal || item.inner != nil ? 0 : Metrics.stub
                item.node.pins[j].point = CGPoint(x: pin.side == .left ? left - stub : left + w + stub, y: top[i] + offset)
            }
            if var inner = item.inner {
                inner.translate(by: CGPoint(x: left, y: top[i]))
                block.nodes.append(contentsOf: inner.nodes)
                block.wires.append(contentsOf: inner.wires)
            }
            if item.isTerminal, let pin = item.node.pins.first {
                block.terminals.append((groupName(pin), pin.side == .right ? .left : .right, pin.point.y, pin.members))
            } else {
                block.nodes.append(item.node)
            }
            items[i] = item
        }
        /// Where a hop meets a node: its pin, or the edge of a bend point's layer (a feedback one is crossed right to left).
        func point(_ i: Int, _ group: String?, leaving: Bool) -> CGPoint {
            if i < n, let group, let pin = items[i].node.pins.first(where: { groupName($0) == group }) { return pin.point }
            let l = layerOfAny(i)
            let rightEdge = i < n ? leaving : leaving != dummies[i - n].backward
            return CGPoint(x: rightEdge ? layerX[l] + layerWidth[l] : layerX[l], y: pinY(i, group))
        }

        // Wires: from each end to its track, along the track, into the other end; bend points carry it across their layer.
        let hopsOfWire = Dictionary(grouping: hops, by: \.wire)
        let dummiesOfWire = Dictionary(grouping: dummies.indices, by: { dummies[$0].wire })
        for (w, link) in links.enumerated() {
            var segments: [SchematicWire.Segment] = []
            func line(_ a: CGPoint, _ b: CGPoint) { if a != b { segments.append(.init(from: a, to: b)) } }
            for h in hopsOfWire[w] ?? [] {
                let a = point(h.from, h.fromGroup, leaving: true)
                let b = point(h.to, h.toGroup, leaving: false)
                let tx = trackX(h.gap, w)
                line(a, CGPoint(x: tx, y: a.y))
                line(CGPoint(x: tx, y: a.y), CGPoint(x: tx, y: b.y))
                line(CGPoint(x: tx, y: b.y), b)
            }
            for k in dummiesOfWire[w] ?? [] {
                let d = dummies[k], y = top[n + k]
                line(CGPoint(x: layerX[d.layer], y: y), CGPoint(x: layerX[d.layer] + layerWidth[d.layer], y: y))
            }
            guard !segments.isEmpty else { continue }
            let label = link.width > 1 ? "\(DesignNet.busName(of: link.nets.first.map { String($0.split(separator: "/").last ?? "") } ?? ""))[\(link.width - 1):0]"
                : String(link.nets.first?.split(separator: "/").last ?? "")
            block.wires.append(SchematicWire(id: "\(module)#\(w)", segments: dedupe(segments), isBus: link.width > 1,
                                             nets: link.nets, label: label))
        }

        // Bounds: every node with its labels, every wire.
        var bounds = CGRect.null
        for node in block.nodes {
            let labelWidth = max(width(node.title), width(node.subtitle))
            let extra = max(0, labelWidth - node.frame.width) / 2
            bounds = bounds.union(node.frame.insetBy(dx: -Metrics.stub - extra, dy: -Metrics.labelSpace))
            if case .port = node.kind { bounds = bounds.union(node.frame.insetBy(dx: -width(node.title) - 8, dy: 0)) }
        }
        for wire in block.wires { for s in wire.segments { bounds = bounds.union(CGRect(x: min(s.from.x, s.to.x), y: min(s.from.y, s.to.y), width: abs(s.to.x - s.from.x), height: abs(s.to.y - s.from.y))) } }
        for t in block.terminals {
            bounds = bounds.union(CGRect(x: t.side == .left ? layerX[0] : layerX[layerCount - 1] + layerWidth[layerCount - 1], y: t.y, width: 0, height: 0))
        }
        block.bounds = bounds.isNull ? CGRect(x: 0, y: 0, width: 120, height: 60) : bounds
        if !module.isEmpty {
            // Inside an open module, the boundary pins sit exactly on the left and right edges.
            let left = min(block.bounds.minX, layerX.first ?? 0), right = max(block.bounds.maxX, (layerX.last ?? 0) + (layerWidth.last ?? 0))
            block.bounds = CGRect(x: left, y: block.bounds.minY, width: right - left, height: block.bounds.height)
            let leftEdge = block.bounds.minX, rightEdge = block.bounds.maxX
            for i in block.wires.indices {
                block.wires[i].segments = block.wires[i].segments.map { s in
                    func snap(_ p: CGPoint) -> CGPoint {
                        if abs(p.x - layerX[0]) < 0.5 { return CGPoint(x: leftEdge, y: p.y) }
                        if let last = layerX.last, abs(p.x - last - (layerWidth.last ?? 0)) < 0.5 { return CGPoint(x: rightEdge, y: p.y) }
                        return p
                    }
                    return .init(from: snap(s.from), to: snap(s.to))
                }
            }
        }
        return block
    }

    /// Strongly connected components (Tarjan): the component each node is in.
    static func components(_ succ: [[Int]]) -> [Int] {
        let n = succ.count
        var index = Array(repeating: -1, count: n), low = Array(repeating: 0, count: n), component = Array(repeating: -1, count: n)
        var onStack = Array(repeating: false, count: n), stack: [Int] = [], next = 0, count = 0
        func visit(_ u: Int) {
            index[u] = next; low[u] = next; next += 1
            stack.append(u); onStack[u] = true
            for v in succ[u] {
                if index[v] < 0 { visit(v); low[u] = min(low[u], low[v]) } else if onStack[v] { low[u] = min(low[u], index[v]) }
            }
            guard low[u] == index[u] else { return }
            while let w = stack.popLast() {
                onStack[w] = false
                component[w] = count
                if w == u { break }
            }
            count += 1
        }
        for u in 0..<n where index[u] < 0 { visit(u) }
        return component
    }

    private func dedupe(_ segments: [SchematicWire.Segment]) -> [SchematicWire.Segment] {
        var seen: Set<[CGFloat]> = []
        return segments.filter { seen.insert([$0.from.x, $0.from.y, $0.to.x, $0.to.y]).inserted }
    }
}
