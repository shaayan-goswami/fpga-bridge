import Foundation

/// The three points in the flow where Vivado has a design open, and the three views of them.
public enum DesignStage: String, CaseIterable, Sendable, Identifiable {
    case rtl, synth, impl

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rtl: "Elaborated Design"
        case .synth: "Synthesized Design"
        case .impl: "Implemented Design"
        }
    }
}

/// One cell of a design: a module instance or a primitive (a LUT, a flip-flop, a block RAM, a buffer...).
public struct DesignCell: Equatable, Sendable, Identifiable {
    public var id: String { name }

    /// Full hierarchical name, e.g. `u_tick/count_reg[3]`.
    public let name: String
    /// The module it instantiates, or the primitive's type (`LUT6`, `FDRE`).
    public let type: String
    public let isPrimitive: Bool
    /// Where it comes from in the HDL, relative to the project (`src/top.v`), when Vivado knows.
    public let sourceFile: String?
    public let sourceLine: Int?

    public init(name: String, type: String, isPrimitive: Bool, sourceFile: String? = nil, sourceLine: Int? = nil) {
        self.name = name
        self.type = type
        self.isPrimitive = isPrimitive
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
    }

    /// The name inside its parent: `count_reg[3]`.
    public var localName: String { name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name }

    /// The hierarchical path of its parent module (`u_tick`), or "" at the top.
    public var parentPath: String {
        guard let slash = name.lastIndex(of: "/") else { return "" }
        return String(name[..<slash])
    }
}

public struct DesignPort: Equatable, Sendable, Identifiable {
    public let name: String
    public let direction: String
    public let packagePin: String
    public let ioStandard: String
    public let slew: String
    public let drive: String
    public let pullType: String

    public init(name: String, direction: String, packagePin: String, ioStandard: String, slew: String, drive: String, pullType: String) {
        self.name = name
        self.direction = direction
        self.packagePin = packagePin
        self.ioStandard = ioStandard
        self.slew = slew
        self.drive = drive
        self.pullType = pullType
    }

    public var id: String { name }
    /// Whether the port has been assigned a pin.
    public var isPlaced: Bool { !packagePin.isEmpty }

    /// The bus a bit belongs to (`led` for `led[3]`), or the port's own name.
    public var busName: String {
        guard name.hasSuffix("]"), let open = name.lastIndex(of: "[") else { return name }
        return String(name[..<open])
    }
}

/// Counts of what a part of the design is made of, by kind of primitive.
public struct ResourceCounts: Equatable, Sendable {
    public var lut = 0
    public var flipFlop = 0
    public var blockRAM = 0
    public var dsp = 0
    public var carry = 0
    public var io = 0
    public var other = 0

    public init() {}

    public var total: Int { lut + flipFlop + blockRAM + dsp + carry + io + other }

    /// Files a primitive under a kind by its cell type. RTL elaboration has only `RTL_*` operations, which count as other.
    public mutating func add(type: String) {
        if type.hasPrefix("LUT"), type.dropFirst(3).allSatisfy(\.isNumber) { lut += 1 }
        else if type.hasPrefix("FD") || type.hasPrefix("LD") && type.count <= 5 { flipFlop += 1 }
        else if type.hasPrefix("RAMB") || type.hasPrefix("FIFO") { blockRAM += 1 }
        else if type.hasPrefix("DSP48") { dsp += 1 }
        else if type.hasPrefix("CARRY") { carry += 1 }
        else if type.hasSuffix("BUF") || type.hasSuffix("BUFT") || type.hasSuffix("BUFDS") || type.hasPrefix("IOBUF") || type.hasPrefix("OBUF") || type.hasPrefix("IBUF") { io += 1 }
        else { other += 1 }
    }

    public static func + (a: ResourceCounts, b: ResourceCounts) -> ResourceCounts {
        var r = ResourceCounts()
        r.lut = a.lut + b.lut; r.flipFlop = a.flipFlop + b.flipFlop; r.blockRAM = a.blockRAM + b.blockRAM
        r.dsp = a.dsp + b.dsp; r.carry = a.carry + b.carry; r.io = a.io + b.io; r.other = a.other + b.other
        return r
    }
}

/// A module in the design hierarchy, with what is directly inside it.
public struct ModuleNode: Identifiable, Equatable, Sendable {
    /// The hierarchical path (`u_tick`), or "" for the top.
    public let id: String
    public let name: String
    /// The module's name (`tick_gen`), or the top's.
    public let type: String
    /// Sub-modules. Nil when there are none, which is what an outline view wants for a leaf.
    public var children: [ModuleNode]?
    /// The primitives directly in this module (not in its sub-modules), in file order.
    public var primitives: [DesignCell]
    /// Counts of those primitives.
    public var counts: ResourceCounts
    /// Counts including every sub-module.
    public var totals: ResourceCounts

    public var isTop: Bool { id.isEmpty }
}

/// A pin of a cell: a primitive's (`count_reg[0]/C`) or a module instance's boundary (`u_tick/clk`).
public struct DesignPin: Equatable, Sendable {
    public let name: String
    /// `IN`, `OUT` or `INOUT`.
    public let direction: String
    public let isClock: Bool

    public init(name: String, direction: String, isClock: Bool = false) {
        self.name = name
        self.direction = direction
        self.isClock = isClock
    }

    /// The cell it belongs to (`u_tick/count_reg[0]`).
    public var cellName: String { name.lastIndex(of: "/").map { String(name[..<$0]) } ?? "" }
    /// The pin's own name on the cell (`C`, `O[7]`).
    public var pinName: String { name.lastIndex(of: "/").map { String(name[name.index(after: $0)...]) } ?? name }
    /// The bus a bit belongs to (`O` for `O[7]`), or the pin's own name.
    public var busName: String { DesignNet.busName(of: pinName) }
}

/// Where a net goes: a cell pin, or a top-level port.
public struct NetEndpoint: Hashable, Sendable {
    public let name: String
    public let isPort: Bool

    public init(name: String, isPort: Bool) {
        self.name = name
        self.isPort = isPort
    }
}

/// A net at one level of the hierarchy. Vivado names each level's piece of a signal separately (`clk` at the top,
/// `u_tick/clk` inside `u_tick`), and each piece lists only the pins at its own level, including the boundary pins of
/// the sub-modules it enters.
public struct DesignNet: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    /// `SIGNAL`, `LOCAL_CLOCK`, `GLOBAL_CLOCK`, `POWER`, `GROUND`...
    public let type: String
    public var endpoints: [NetEndpoint]

    public init(name: String, type: String, endpoints: [NetEndpoint] = []) {
        self.name = name
        self.type = type
        self.endpoints = endpoints
    }

    /// The module it is in, as a hierarchical path ("" for the top).
    public var parentPath: String { name.lastIndex(of: "/").map { String(name[..<$0]) } ?? "" }
    public var localName: String { name.lastIndex(of: "/").map { String(name[name.index(after: $0)...]) } ?? name }
    /// The bus a bit belongs to (`count` for `count[3]`), or the net's own name.
    public var busName: String { DesignNet.busName(of: localName) }
    public var isPowerOrGround: Bool { type == "POWER" || type == "GROUND" }

    static func busName(of name: String) -> String {
        guard name.hasSuffix("]"), let open = name.lastIndex(of: "["),
              name[name.index(after: open)..<name.index(before: name.endIndex)].allSatisfy(\.isNumber) else { return name }
        return String(name[..<open])
    }
}

/// The kinds of object the Properties window can show.
public enum DesignObjectKind: String, Sendable, CaseIterable {
    case cell, net, port, pin
}

/// One property and its value, as Vivado's Properties window lists them.
public struct DesignProperty: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct DesignInfo: Equatable, Sendable {
    public var stage = ""
    public var design = ""
    public var part = ""
    public var top = ""
    public var vivado = ""
    /// What the build didn't write because the design is very large (`connectivity`, `properties`).
    public var leftOut: [String] = []

    public init(stage: String = "", design: String = "", part: String = "", top: String = "", vivado: String = "",
                leftOut: [String] = []) {
        self.stage = stage
        self.design = design
        self.part = part
        self.top = top
        self.vivado = vivado
        self.leftOut = leftOut
    }
}

/// What Vivado wrote about one stage of a design: the hierarchy of modules and primitives, and the I/O ports.
public struct DesignSnapshot: Equatable, Sendable {
    public let stage: DesignStage
    public let info: DesignInfo
    public let cells: [DesignCell]
    public let ports: [DesignPort]
    public let root: ModuleNode
    /// Every cell pin by name. Empty when the build didn't write connectivity (an older build, or a huge design).
    public let pins: [String: DesignPin]
    /// Every net, at every level of the hierarchy, in Vivado's order.
    public let nets: [DesignNet]
    /// Properties by object, keyed by `kind:name` (see `properties(of:name:)`).
    public let propertyTable: [String: [DesignProperty]]
    private let cellsByName: [String: DesignCell]
    private let pinsByCell: [String: [DesignPin]]
    private let netsByModule: [String: [DesignNet]]

    public enum LoadError: DescribedError {
        case notAvailable(DesignStage)
        public var description: String {
            switch self {
            case .notAvailable(let stage):
                return "No \(stage.title) data yet. Run a build first: the build writes it."
            }
        }
    }

    public init(stage: DesignStage, info: DesignInfo, cells: [DesignCell], ports: [DesignPort],
                pins: [DesignPin] = [], nets: [DesignNet] = [], properties: [String: [DesignProperty]] = [:]) {
        self.stage = stage
        self.info = info
        self.cells = cells
        self.ports = ports
        self.root = DesignSnapshot.buildHierarchy(top: info.top, cells: cells)
        self.pins = Dictionary(pins.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.nets = nets
        self.propertyTable = properties
        self.cellsByName = Dictionary(cells.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.pinsByCell = Dictionary(grouping: self.pins.values, by: \.cellName)
            .mapValues { $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        self.netsByModule = Dictionary(grouping: nets, by: \.parentPath)
    }

    /// Whether the build wrote how cells are connected, which the schematic needs.
    public var hasConnectivity: Bool { !nets.isEmpty }

    /// Reads `<stage>_cells.tsv`, `_ports.tsv` and `_info.tsv` from a build output folder.
    public static func load(stage: DesignStage, from directory: URL) throws -> DesignSnapshot {
        func read(_ name: String) -> String? { try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) }
        guard let cellsText = read(DesignDump.cellsFile(stage.rawValue)) else { throw LoadError.notAvailable(stage) }
        return DesignSnapshot(stage: stage,
                              info: parseInfo(read(DesignDump.infoFile(stage.rawValue)) ?? ""),
                              cells: parseCells(cellsText),
                              ports: parsePorts(read(DesignDump.portsFile(stage.rawValue)) ?? ""),
                              pins: parsePins(read(DesignDump.pinsFile(stage.rawValue)) ?? ""),
                              nets: parseConnections(read(DesignDump.connectionsFile(stage.rawValue)) ?? ""),
                              properties: parseProperties(read(DesignDump.propertiesFile(stage.rawValue)) ?? ""))
    }

    /// Whether a build left data for this stage.
    public static func isAvailable(_ stage: DesignStage, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(DesignDump.cellsFile(stage.rawValue)).path)
    }

    // MARK: Parsing

    /// Lines of a tab-separated file, tolerating Windows line endings. Fields keep empty values, which matter.
    /// (Swift reads CR LF as one character that is not "\n", so splitting on "\n" alone would find no lines at all.)
    static func rows(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    public static func parseCells(_ text: String) -> [DesignCell] {
        rows(text).compactMap { f in
            guard f.count >= 3 else { return nil }
            let file = f.count > 3 && !f[3].isEmpty ? f[3] : nil
            return DesignCell(name: f[0], type: f[1], isPrimitive: f[2] == "1", sourceFile: file,
                              sourceLine: f.count > 4 ? Int(f[4]) : nil)
        }
    }

    public static func parsePorts(_ text: String) -> [DesignPort] {
        rows(text).compactMap { f in
            guard f.count >= 2 else { return nil }
            func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
            return DesignPort(name: f[0], direction: field(1), packagePin: field(2), ioStandard: field(3),
                              slew: field(4), drive: field(5), pullType: field(6))
        }
    }

    public static func parseInfo(_ text: String) -> DesignInfo {
        var info = DesignInfo()
        for f in rows(text) where f.count >= 2 {
            switch f[0] {
            case "stage": info.stage = f[1]
            case "design": info.design = f[1]
            case "part": info.part = f[1]
            case "top": info.top = f[1]
            case "vivado": info.vivado = f[1]
            case "left_out": info.leftOut = f[1].split(separator: ",").map(String.init)
            default: break
            }
        }
        return info
    }

    public static func parsePins(_ text: String) -> [DesignPin] {
        rows(text).compactMap { f in
            guard f.count >= 2 else { return nil }
            return DesignPin(name: f[0], direction: f[1], isClock: f.count > 2 && f[2] == "1")
        }
    }

    /// One line per connection (net, type, endpoint, `pin` or `port`), grouped into nets in file order.
    public static func parseConnections(_ text: String) -> [DesignNet] {
        var order: [String] = []
        var nets: [String: DesignNet] = [:]
        for f in rows(text) where f.count >= 4 {
            if nets[f[0]] == nil {
                order.append(f[0])
                nets[f[0]] = DesignNet(name: f[0], type: f[1])
            }
            nets[f[0]]?.endpoints.append(NetEndpoint(name: f[2], isPort: f[3] == "port"))
        }
        return order.compactMap { nets[$0] }
    }

    /// One line per property (kind, object, property, value), keyed by `kind:name`, sorted by property name as
    /// Vivado's Properties window lists them.
    public static func parseProperties(_ text: String) -> [String: [DesignProperty]] {
        var table: [String: [DesignProperty]] = [:]
        for f in rows(text) where f.count >= 4 {
            table["\(f[0]):\(f[1])", default: []].append(DesignProperty(name: f[2], value: f[3]))
        }
        return table.mapValues { $0.sorted { $0.name < $1.name } }
    }

    // MARK: Hierarchy

    /// Builds the module tree from cell names. A module is a cell that isn't a primitive; its path is its name, and
    /// everything whose name starts with `<path>/` is inside it. The top has the empty path.
    static func buildHierarchy(top: String, cells: [DesignCell]) -> ModuleNode {
        var types: [String: String] = ["": top]
        var childPaths: [String: [String]] = [:]
        var primitives: [String: [DesignCell]] = [:]
        var counts: [String: ResourceCounts] = [:]

        for cell in cells {
            if cell.isPrimitive {
                primitives[cell.parentPath, default: []].append(cell)
                counts[cell.parentPath, default: ResourceCounts()].add(type: cell.type)
            } else {
                types[cell.name] = cell.type
                childPaths[cell.parentPath, default: []].append(cell.name)
            }
        }

        func node(_ path: String) -> ModuleNode {
            let children = (childPaths[path] ?? []).map(node)
            let own = counts[path] ?? ResourceCounts()
            let name = path.isEmpty ? (top.isEmpty ? "top" : top) : (path.split(separator: "/").last.map(String.init) ?? path)
            return ModuleNode(id: path, name: name, type: types[path] ?? "",
                              children: children.isEmpty ? nil : children,
                              primitives: primitives[path] ?? [], counts: own,
                              totals: children.reduce(own) { $0 + $1.totals })
        }
        return node("")
    }

    // MARK: Queries

    /// The saved properties of an object, empty if there are none (or the build left them out).
    public func properties(of kind: DesignObjectKind, name: String) -> [DesignProperty] {
        propertyTable["\(kind.rawValue):\(name)"] ?? []
    }

    public func cell(named name: String) -> DesignCell? { cellsByName[name] }

    /// The nets inside a module (not its sub-modules), in Vivado's order.
    public func nets(in modulePath: String) -> [DesignNet] { netsByModule[modulePath] ?? [] }

    /// The pins of one cell, in natural order (`O[2]` before `O[10]`).
    public func pins(of cellName: String) -> [DesignPin] { pinsByCell[cellName] ?? [] }

    /// Every module, the top first, depth first.
    public var modules: [ModuleNode] {
        func walk(_ n: ModuleNode) -> [ModuleNode] { [n] + (n.children ?? []).flatMap(walk) }
        return walk(root)
    }

    public func module(withPath path: String) -> ModuleNode? { modules.first { $0.id == path } }

    /// Cell types and how many of each, most common first.
    public var typeCounts: [(type: String, count: Int)] {
        Dictionary(grouping: cells.filter(\.isPrimitive), by: \.type).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.type < $1.type }
    }

    /// Ports grouped into buses: `led[0]`...`led[15]` become one `led` entry.
    public var portBuses: [(name: String, ports: [DesignPort])] {
        var order: [String] = []
        var groups: [String: [DesignPort]] = [:]
        for port in ports {
            let key = port.busName
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(port)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
