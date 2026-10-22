import CoreGraphics
import Foundation

/// A block design laid out as IP Integrator draws it: blocks with their inputs and slave interfaces on the left and
/// outputs and master interfaces on the right, external ports on the edges, and nets routed left to right.
///
/// The placement and routing are the schematic's (`SchematicBuilder`): the block design is handed to it as a netlist
/// in which each block is a cell, each hierarchy a module that can be opened in place, each pin and interface a pin,
/// and each net and interface net a net. The result is mapped back to the block design's own objects, so the canvas
/// can draw interfaces as buses and the Properties panel can show what a block really is.
public struct BlockDesignDiagram: Sendable {
    public let layout: SchematicLayout
    /// The block each cell node draws, by node id (the cell's path).
    public let cells: [String: BDCell]
    /// The design port each port node draws, by node id.
    public let ports: [String: BDPin]
    /// The pin each `SchematicPin` stands for, by its id, with the block it's on (nil for a design port).
    public let pins: [String: (cell: String?, pin: BDPin)]
    /// The net each wire carries, by the netlist name the layout uses.
    public let nets: [String: (level: String, net: BDNet)]

    /// The hierarchy shown in the background when nothing else is shown.
    public static func layout(_ design: BlockDesign, expanded: Set<String> = []) throws -> BlockDesignDiagram {
        let netlist = Netlist(design)
        let layout = try SchematicBuilder(design: netlist.snapshot).layout(SchematicSpec(module: "", expanded: expanded))
        var pins: [String: (cell: String?, pin: BDPin)] = [:]
        var cells: [String: BDCell] = [:]
        var ports: [String: BDPin] = [:]
        for node in layout.nodes {
            if case .port = node.kind {
                guard let port = netlist.portOfNode[node.id] else { continue }
                ports[node.id] = port
                for pin in node.pins { pins[pin.id] = (nil, port) }
            } else if let cell = design.cell(atPath: node.id) {
                cells[node.id] = cell
                for pin in node.pins {
                    let group = String(pin.id.split(separator: "|").last ?? "")
                    if let real = netlist.pinOfName["\(cell.path)/\(group)"] { pins[pin.id] = (cell.path, real) }
                }
            }
        }
        return BlockDesignDiagram(layout: layout, cells: cells, ports: ports, pins: pins, nets: netlist.netOfName)
    }

    /// The pin a schematic pin stands for.
    public func pin(_ id: String) -> (cell: String?, pin: BDPin)? { pins[id] }

    /// Whether a wire is an interface connection (drawn thick).
    public func isInterface(_ wire: SchematicWire) -> Bool {
        wire.nets.contains { nets[$0]?.net.isInterface == true }
    }

    /// The block design net a wire carries.
    public func net(of wire: SchematicWire) -> (level: String, net: BDNet)? {
        wire.nets.lazy.compactMap { nets[$0] }.first
    }

    /// The block design as the schematic's netlist.
    struct Netlist {
        var snapshot: DesignSnapshot
        var pinOfName: [String: BDPin] = [:]          // `cell path/encoded name` → pin
        var portOfNode: [String: BDPin] = [:]         // `port:name` → design port
        var netOfName: [String: (level: String, net: BDNet)] = [:]

        init(_ design: BlockDesign) {
            var cells: [DesignCell] = []
            var pins: [DesignPin] = []
            var nets: [DesignNet] = []
            var pinOfName: [String: BDPin] = [:]
            var encodedPin: [String: String] = [:]        // `cell path/real name` → full encoded pin name
            var netOfName: [String: (level: String, net: BDNet)] = [:]

            // A pin's netlist name keeps the block's pin order (the schematic sorts pins by name: interfaces first,
            // then signals, as Vivado lists them) and is as long as its label, which sizes the block.
            func add(_ cell: BDCell) {
                cells.append(DesignCell(name: cell.path, type: Netlist.typeLabel(cell), isPrimitive: !cell.isHierarchy))
                for (k, pin) in cell.pins.enumerated() {
                    let encoded = String(format: "%03d_", k) + pin.label + (pin.isInterface ? " +" : "")
                    let full = "\(cell.path)/\(encoded)"
                    pins.append(DesignPin(name: full, direction: Netlist.direction(pin), isClock: pin.type == "clk"))
                    pinOfName[full] = pin
                    encodedPin["\(cell.path)/\(pin.name)"] = full
                }
                cell.cells.forEach(add)
            }
            design.cells.forEach(add)

            let ports = design.ports.map {
                DesignPort(name: $0.name, direction: Netlist.direction($0), packagePin: "", ioStandard: "", slew: "", drive: "", pullType: "")
            }
            var portOfNode: [String: BDPin] = [:]
            for port in design.ports { portOfNode["port:" + port.name] = port }

            func addNets(_ list: [BDNet], level: String) {
                for (k, net) in list.enumerated() {
                    let local = String(format: "%@%04d", net.isInterface ? "i" : "n", k)
                    let name = level.isEmpty ? local : level + "/" + local
                    var ends: [NetEndpoint] = []
                    for end in net.endpoints {
                        if let slash = end.lastIndex(of: "/") {
                            let cellPath = (level.isEmpty ? "" : level + "/") + end[..<slash]
                            let key = "\(cellPath)/\(end[end.index(after: slash)...])"
                            if let full = encodedPin[key] { ends.append(NetEndpoint(name: full, isPort: false)) }
                        } else if level.isEmpty {
                            if design.port(named: end) != nil { ends.append(NetEndpoint(name: end, isPort: true)) }
                        } else if let full = encodedPin["\(level)/\(end)"] {
                            ends.append(NetEndpoint(name: full, isPort: false))       // the hierarchy's own pin
                        }
                    }
                    nets.append(DesignNet(name: name, type: "SIGNAL", endpoints: ends))
                    netOfName[name] = (level, net)
                }
            }
            addNets(design.nets, level: "")
            for cell in design.allCells where cell.isHierarchy { addNets(cell.nets, level: cell.path) }
            // The schematic draws nothing without connectivity; an empty design still shows its blocks and ports.
            if nets.isEmpty { nets.append(DesignNet(name: "\u{1}/none", type: "SIGNAL")) }

            snapshot = DesignSnapshot(stage: .rtl, info: DesignInfo(design: design.name, part: design.part, top: design.name),
                                      cells: cells, ports: ports, pins: pins, nets: nets)
            self.pinOfName = pinOfName
            self.portOfNode = portOfNode
            self.netOfName = netOfName
        }

        /// A design port's direction as the schematic sees it: a master interface port leaves the design.
        static func direction(_ pin: BDPin) -> String {
            switch pin.direction {
            case .input: "IN"
            case .output: "OUT"
            case .inout: "INOUT"
            }
        }

        /// What the block's type is called in the netlist (it sizes the label under the block). The schematic draws
        /// gates and registers for some primitive names; a block is always a plain box.
        static func typeLabel(_ cell: BDCell) -> String {
            let label = cell.displayName.isEmpty ? cell.name : cell.displayName
            if SchematicSymbol.forCell(type: label, inputs: 1, outputs: 1, isPrimitive: true) == .box { return label }
            return "\u{2009}" + label
        }
    }
}
