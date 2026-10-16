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
public struct DesignCell: Equatable, Sendable {
    /// Full hierarchical name, e.g. `u_tick/count_reg[3]`.
    public let name: String
    /// The module it instantiates, or the primitive's type (`LUT6`, `FDRE`).
    public let type: String
    public let isPrimitive: Bool

    public init(name: String, type: String, isPrimitive: Bool) {
        self.name = name
        self.type = type
        self.isPrimitive = isPrimitive
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

public struct DesignInfo: Equatable, Sendable {
    public var stage = ""
    public var design = ""
    public var part = ""
    public var top = ""
    public var vivado = ""
}

/// What Vivado wrote about one stage of a design: the hierarchy of modules and primitives, and the I/O ports.
public struct DesignSnapshot: Equatable, Sendable {
    public let stage: DesignStage
    public let info: DesignInfo
    public let cells: [DesignCell]
    public let ports: [DesignPort]
    public let root: ModuleNode

    public enum LoadError: DescribedError {
        case notAvailable(DesignStage)
        public var description: String {
            switch self {
            case .notAvailable(let stage):
                return "No \(stage.title) data yet. Run a build first: the build writes it."
            }
        }
    }

    public init(stage: DesignStage, info: DesignInfo, cells: [DesignCell], ports: [DesignPort]) {
        self.stage = stage
        self.info = info
        self.cells = cells
        self.ports = ports
        self.root = DesignSnapshot.buildHierarchy(top: info.top, cells: cells)
    }

    /// Reads `<stage>_cells.tsv`, `_ports.tsv` and `_info.tsv` from a build output folder.
    public static func load(stage: DesignStage, from directory: URL) throws -> DesignSnapshot {
        func read(_ name: String) -> String? { try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) }
        guard let cellsText = read(DesignDump.cellsFile(stage.rawValue)) else { throw LoadError.notAvailable(stage) }
        return DesignSnapshot(stage: stage,
                              info: parseInfo(read(DesignDump.infoFile(stage.rawValue)) ?? ""),
                              cells: parseCells(cellsText),
                              ports: parsePorts(read(DesignDump.portsFile(stage.rawValue)) ?? ""))
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
            return DesignCell(name: f[0], type: f[1], isPrimitive: f[2] == "1")
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
            default: break
            }
        }
        return info
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
