import Foundation

/// The rows of Vivado's Netlist window: the top module, then in each module a Nets folder (buses grouped, so `count`
/// opens to `count[0]`...), a Leaf Cells folder for its primitives, and its sub-modules, each opening the same way.
public struct NetlistOutline: Sendable {
    public enum Kind: Equatable, Sendable {
        case module(path: String)
        case netsFolder(module: String)
        case leafFolder(module: String)
        case bus(module: String, name: String)
        case net(String)
        case cell(String)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public let depth: Int
        /// The name shown (`u_tick`, `count_reg[0]`, `Nets`).
        public let title: String
        /// Shown after the title in grey: the module or primitive type, or a count.
        public let detail: String
        public let hasChildren: Bool

        /// The design object a row stands for, if any. Folders and buses stand for none; the top module neither.
        public var object: DesignObjectRef? {
            switch kind {
            case .module(let path): path.isEmpty ? nil : .cell(path)
            case .net(let name): .net(name)
            case .cell(let name): .cell(name)
            default: nil
            }
        }
    }

    let design: DesignSnapshot
    private let primitivesByModule: [String: [DesignCell]]
    private let childModules: [String: [DesignCell]]

    public init(design: DesignSnapshot) {
        self.design = design
        var prims: [String: [DesignCell]] = [:]
        var mods: [String: [DesignCell]] = [:]
        for cell in design.cells {
            if cell.isPrimitive { prims[cell.parentPath, default: []].append(cell) } else { mods[cell.parentPath, default: []].append(cell) }
        }
        primitivesByModule = prims
        childModules = mods
    }

    public static func id(_ kind: Kind) -> String {
        switch kind {
        case .module(let path): "mod:\(path)"
        case .netsFolder(let module): "nets:\(module)"
        case .leafFolder(let module): "leaf:\(module)"
        case .bus(let module, let name): "bus:\(module)|\(name)"
        case .net(let name): "net:\(name)"
        case .cell(let name): "cell:\(name)"
        }
    }

    /// The visible rows, depth first, with the given rows opened (by id). The top module is always open.
    public func rows(expanded: Set<String>) -> [Row] {
        var out: [Row] = []
        func add(_ row: Row) {
            out.append(row)
            if row.hasChildren, row.depth == 0 || expanded.contains(row.id) {
                for child in children(of: row.kind, depth: row.depth + 1) { add(child) }
            }
        }
        add(Row(id: Self.id(.module(path: "")), kind: .module(path: ""), depth: 0,
                title: design.info.top.isEmpty ? "top" : design.info.top, detail: "", hasChildren: true))
        return out
    }

    func children(of kind: Kind, depth: Int) -> [Row] {
        switch kind {
        case .module(let path):
            var rows: [Row] = []
            let nets = design.nets(in: path)
            if !nets.isEmpty {
                rows.append(Row(id: Self.id(.netsFolder(module: path)), kind: .netsFolder(module: path), depth: depth,
                                title: "Nets", detail: "(\(nets.count))", hasChildren: true))
            }
            let leaves = primitivesByModule[path] ?? []
            if !leaves.isEmpty {
                rows.append(Row(id: Self.id(.leafFolder(module: path)), kind: .leafFolder(module: path), depth: depth,
                                title: "Leaf Cells", detail: "(\(leaves.count))", hasChildren: true))
            }
            for sub in (childModules[path] ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                rows.append(Row(id: Self.id(.module(path: sub.name)), kind: .module(path: sub.name), depth: depth,
                                title: sub.localName, detail: "(\(sub.type))",
                                hasChildren: !(childModules[sub.name] ?? []).isEmpty || !(primitivesByModule[sub.name] ?? []).isEmpty
                                    || !design.nets(in: sub.name).isEmpty))
            }
            return rows
        case .netsFolder(let module):
            // Group bus bits under one row, keeping the first appearance's position; sort like Vivado (natural order).
            var order: [String] = []
            var groups: [String: [DesignNet]] = [:]
            for net in design.nets(in: module) {
                if groups[net.busName] == nil { order.append(net.busName) }
                groups[net.busName, default: []].append(net)
            }
            return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                let members = groups[name] ?? []
                if members.count == 1, members[0].localName == name {
                    return Row(id: Self.id(.net(members[0].name)), kind: .net(members[0].name), depth: depth,
                               title: name, detail: "", hasChildren: false)
                }
                return Row(id: Self.id(.bus(module: module, name: name)), kind: .bus(module: module, name: name), depth: depth,
                           title: name, detail: "(\(members.count))", hasChildren: true)
            }
        case .bus(let module, let name):
            return design.nets(in: module).filter { $0.busName == name }
                .sorted { $0.localName.localizedStandardCompare($1.localName) == .orderedAscending }
                .map { Row(id: Self.id(.net($0.name)), kind: .net($0.name), depth: depth, title: $0.localName, detail: "", hasChildren: false) }
        case .leafFolder(let module):
            return (primitivesByModule[module] ?? [])
                .sorted { $0.localName.localizedStandardCompare($1.localName) == .orderedAscending }
                .map { Row(id: Self.id(.cell($0.name)), kind: .cell($0.name), depth: depth, title: $0.localName,
                           detail: "(\($0.type))", hasChildren: false) }
        case .net, .cell:
            return []
        }
    }

    /// The rows to open so an object can be seen: its modules, and the folder (and bus) it sits in.
    public func idsToReveal(_ ref: DesignObjectRef) -> Set<String> {
        var ids = Set(DesignSnapshot.ancestors(of: ref.name).map { Self.id(.module(path: $0)) })
        switch ref.kind {
        case .cell:
            if design.cell(named: ref.name)?.isPrimitive == true {
                ids.insert(Self.id(.leafFolder(module: design.cell(named: ref.name)?.parentPath ?? "")))
            } else {
                ids.remove(Self.id(.module(path: ref.name)))
            }
        case .net:
            if let net = design.net(named: ref.name) {
                ids.insert(Self.id(.netsFolder(module: net.parentPath)))
                if net.busName != net.localName || design.nets(in: net.parentPath).contains(where: { $0.busName == net.busName && $0.name != net.name }) {
                    ids.insert(Self.id(.bus(module: net.parentPath, name: net.busName)))
                }
            }
        case .pin:
            if let pin = design.pins[ref.name] { return idsToReveal(.cell(pin.cellName)) }
        case .port:
            break
        }
        return ids
    }
}
