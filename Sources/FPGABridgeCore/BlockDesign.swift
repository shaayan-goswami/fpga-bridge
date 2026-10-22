import Foundation

// MARK: The model

/// One setting of a cell or pin (`CONFIG.C_BAUDRATE` without the `CONFIG.` prefix).
public struct BDParameter: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let value: String
    /// Set by the user (or by automation on the user's behalf), as opposed to the IP's default.
    public let isUserSet: Bool

    public init(name: String, value: String, isUserSet: Bool) {
        self.name = name
        self.value = value
        self.isUserSet = isUserSet
    }
}

public enum BDDirection: String, Equatable, Sendable {
    case input = "I", output = "O", `inout` = "IO"

    /// From a `.bd` (`I`, `O`, `IO`) or an `.xci` (`in`, `out`, `inout`).
    init(_ text: String) {
        switch text.lowercased() {
        case "o", "out", "output": self = .output
        case "io", "inout": self = .inout
        default: self = .input
        }
    }

    public var title: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        case .inout: "Inout"
        }
    }
}

/// A pin of a block, or a port of the design: either one signal (or a vector of them), or a bus interface such as
/// AXI that Vivado draws as one thick connection with a "+" to open it.
public struct BDPin: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let isInterface: Bool
    /// Which side it is on: an interface's direction follows its mode (a master drives, a slave is driven).
    public let direction: BDDirection
    /// For a signal: Vivado's TYPE, `clk`, `rst`, `intr`, `ce`, `data` or `undef`. Empty for an interface.
    public let type: String
    /// For an interface: `Master`, `Slave`, `MirroredMaster`, `MirroredSlave`, `Monitor`. Empty for a signal.
    public let mode: String
    /// For an interface: the bus definition, `xilinx.com:interface:aximm:1.0`.
    public let vlnv: String
    /// A vector's bounds, as Vivado writes them (`left` 3, `right` 0 for `[3:0]`). Nil for one bit.
    public let left: Int?
    public let right: Int?
    public let parameters: [BDParameter]

    public init(name: String, isInterface: Bool, direction: BDDirection, type: String = "", mode: String = "", vlnv: String = "",
                left: Int? = nil, right: Int? = nil, parameters: [BDParameter] = []) {
        self.name = name
        self.isInterface = isInterface
        self.direction = direction
        self.type = type
        self.mode = mode
        self.vlnv = vlnv
        self.left = left
        self.right = right
        self.parameters = parameters
    }

    public var width: Int {
        guard let left, let right else { return 1 }
        return abs(left - right) + 1
    }

    /// What the diagram writes next to it: `led[3:0]`, or the name.
    public var label: String {
        guard !isInterface, let left, let right, left != right else { return name }
        return "\(name)[\(left):\(right)]"
    }

    /// The interface's kind, from its bus definition: `aximm`, `uart`, `lmb`.
    public var interfaceKind: String {
        let parts = vlnv.split(separator: ":")
        return parts.count >= 3 ? String(parts[2]) : vlnv
    }

    /// What Vivado's tooltips and Properties call it: "Clock", "Reset", "AXI4 memory-mapped master"...
    public var kindTitle: String {
        if isInterface {
            let bus = interfaceKind == "aximm" ? "AXI memory-mapped" : interfaceKind == "axis" ? "AXI4-Stream" : interfaceKind.uppercased()
            return "\(bus) interface (\(mode.isEmpty ? "?" : mode))"
        }
        switch type {
        case "clk": return "Clock"
        case "rst": return "Reset"
        case "intr": return "Interrupt"
        case "ce": return "Clock enable"
        case "data": return "Data"
        default: return "Signal"
        }
    }
}

/// A net (one signal, or a vector) or an interface net (a bus connection) at one level of the design. Endpoints are
/// written as Vivado writes them: `cell/pin` for a block's pin, a bare name for a port of this level (the design's
/// ports at the top, a hierarchy's own pins inside it). The first endpoint drives it.
public struct BDNet: Equatable, Sendable, Identifiable {
    public var id: String { (isInterface ? "intf:" : "net:") + name }
    public let name: String
    public let isInterface: Bool
    public let endpoints: [String]

    public init(name: String, isInterface: Bool, endpoints: [String]) {
        self.name = name
        self.isInterface = isInterface
        self.endpoints = endpoints
    }
}

/// A block in the diagram: an IP, an RTL module added as a block (a module reference), or a hierarchy holding more
/// blocks.
public struct BDCell: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case ip, moduleReference, hierarchy

        public var title: String {
            switch self {
            case .ip: "IP"
            case .moduleReference: "Module Reference"
            case .hierarchy: "Hierarchical Cell"
            }
        }
    }

    public var id: String { path }
    /// Its name in its hierarchy (`dlmb_v10`).
    public let name: String
    /// The full path from the top, without the leading slash (`microblaze_0_local_memory/dlmb_v10`).
    public let path: String
    public let kind: Kind
    /// `xilinx.com:ip:axi_gpio:2.0`. Empty for a plain hierarchy (an IP like the AXI Interconnect is both).
    public let vlnv: String
    /// The name of the IP's generated module (`mb_system_axi_gpio_0_0`), from which its `.xci` is named.
    public let xciName: String
    /// For a module reference, the RTL module it stands for.
    public let referenceName: String
    public let parameters: [BDParameter]
    public let pins: [BDPin]
    /// Whether the pins came from the IP's own description (`.xci`), so unconnected ones are there too. Without it,
    /// only the pins that something connects to are known.
    public let hasFullPinList: Bool
    /// A hierarchy's contents.
    public let cells: [BDCell]
    public let nets: [BDNet]

    public init(name: String, path: String, kind: Kind, vlnv: String = "", xciName: String = "", referenceName: String = "",
                parameters: [BDParameter] = [], pins: [BDPin] = [], hasFullPinList: Bool = true, cells: [BDCell] = [],
                nets: [BDNet] = []) {
        self.name = name
        self.path = path
        self.kind = kind
        self.vlnv = vlnv
        self.xciName = xciName
        self.referenceName = referenceName
        self.parameters = parameters
        self.pins = pins
        self.hasFullPinList = hasFullPinList
        self.cells = cells
        self.nets = nets
    }

    /// The IP's name from its VLNV (`axi_gpio`), or the module's for a module reference.
    public var ipName: String {
        if kind == .moduleReference, !referenceName.isEmpty { return referenceName }
        let parts = vlnv.split(separator: ":")
        return parts.count >= 3 ? String(parts[2]) : ""
    }

    /// What Vivado writes under the block: the IP's display name (`AXI GPIO`), a module reference's module, or
    /// nothing for a plain hierarchy.
    public var displayName: String {
        if kind == .moduleReference { return referenceName.isEmpty ? ipName : referenceName }
        if vlnv.isEmpty { return "" }
        return BlockDesign.displayNames[ipName] ?? ipName
    }

    public var isHierarchy: Bool { kind == .hierarchy }

    public func pin(named name: String) -> BDPin? { pins.first { $0.name == name } }

    /// Every cell inside it, depth first.
    public var allCells: [BDCell] { cells.flatMap { [$0] + $0.allCells } }
}

/// One row of the Address Editor: a slave's address block as one master sees it.
public struct BDAddressSegment: Equatable, Sendable, Identifiable {
    public var id: String { "\(master)/\(addressSpace)/\(name)" }
    /// The master cell's path, with Vivado's leading slash (`/microblaze_0`).
    public let master: String
    /// `Data`, `Instruction`.
    public let addressSpace: String
    /// Vivado's segment name, `SEG_axi_gpio_0_Reg`.
    public let name: String
    /// The slave's address block, `/axi_gpio_0/S_AXI/Reg`.
    public let addressBlock: String
    public let offset: UInt64
    public let range: UInt64
    /// The range as Vivado wrote it (`64K`).
    public let rangeText: String
    /// An excluded segment: the slave is wired to the master, but the master isn't allowed to reach it.
    public let isExcluded: Bool
    /// The address space's width in bits, for writing addresses (32 or 64).
    public let width: Int

    public init(master: String, addressSpace: String, name: String, addressBlock: String, offset: UInt64, range: UInt64,
                rangeText: String, isExcluded: Bool = false, width: Int = 32) {
        self.master = master
        self.addressSpace = addressSpace
        self.name = name
        self.addressBlock = addressBlock
        self.offset = offset
        self.range = range
        self.rangeText = rangeText
        self.isExcluded = isExcluded
        self.width = width
    }

    private var blockParts: [String] { addressBlock.split(separator: "/").map(String.init) }
    /// The slave cell (`/axi_gpio_0`), its interface (`S_AXI`) and the block in it (`Reg`): the Address Editor's
    /// Name, Interface and Slave Segment columns.
    public var slave: String { blockParts.count >= 3 ? "/" + blockParts.dropLast(2).joined(separator: "/") : addressBlock }
    public var slaveInterface: String { blockParts.count >= 3 ? blockParts[blockParts.count - 2] : "" }
    public var slaveSegment: String { blockParts.last ?? "" }

    public var high: UInt64 { range == 0 ? offset : offset &+ range &- 1 }

    /// Vivado's address style: `0x4000_0000`, in groups of four digits, as wide as the address space.
    public static func format(_ value: UInt64, width: Int = 32) -> String {
        let digits = max(8, (width + 3) / 4)
        var hex = String(value, radix: 16, uppercase: true)
        hex = String(repeating: "0", count: max(0, digits - hex.count)) + hex
        var groups: [String] = []
        var rest = Substring(hex)
        while rest.count > 4 {
            groups.insert(String(rest.suffix(4)), at: 0)
            rest = rest.dropLast(4)
        }
        groups.insert(String(rest), at: 0)
        return "0x" + groups.joined(separator: "_")
    }

    /// `64K`, `4G`, `0x1000` or `4096` as a number of bytes.
    public static func parseSize(_ text: String) -> UInt64? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("0X") { return UInt64(t.dropFirst(2), radix: 16) }
        let units: [Character: UInt64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40, "P": 1 << 50, "E": 1 << 60]
        if let last = t.last, let unit = units[last], let n = UInt64(t.dropLast()) { return n * unit }
        return UInt64(t)
    }
}

/// A block design, as Vivado's IP Integrator saves it: the `.bd` file (JSON since Vivado 2016) with, next to it,
/// `ip/<name>/<name>.xci` for each IP, which is where each IP's pins are listed.
public struct BlockDesign: Equatable, Sendable {
    public let name: String
    /// The part it was made for.
    public let part: String
    public let toolVersion: String
    /// Whether Validate Design passed before it was saved.
    public let isValidated: Bool
    /// The design's external ports and interface ports.
    public let ports: [BDPin]
    /// The top level's blocks and nets.
    public let cells: [BDCell]
    public let nets: [BDNet]
    public let addressSegments: [BDAddressSegment]

    public init(name: String, part: String = "", toolVersion: String = "", isValidated: Bool = false, ports: [BDPin] = [],
                cells: [BDCell] = [], nets: [BDNet] = [], addressSegments: [BDAddressSegment] = []) {
        self.name = name
        self.part = part
        self.toolVersion = toolVersion
        self.isValidated = isValidated
        self.ports = ports
        self.cells = cells
        self.nets = nets
        self.addressSegments = addressSegments
    }

    /// Every block at every level, depth first.
    public var allCells: [BDCell] { cells.flatMap { [$0] + $0.allCells } }

    /// The block at a path (`microblaze_0_local_memory/lmb_bram`; a leading slash is allowed).
    public func cell(atPath path: String) -> BDCell? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return allCells.first { $0.path == trimmed }
    }

    /// The nets at one level ("" is the top).
    public func nets(in path: String) -> [BDNet] {
        path.isEmpty ? nets : cell(atPath: path)?.nets ?? []
    }

    public func port(named name: String) -> BDPin? { ports.first { $0.name == name } }

    /// The pin an endpoint names at a level: a block's pin (`cell/pin`), or a port of the level (the design's own at
    /// the top, the hierarchy's pin inside one).
    public func pin(endpoint: String, in level: String) -> (cell: String?, pin: BDPin)? {
        if let slash = endpoint.lastIndex(of: "/") {
            let cellPath = (level.isEmpty ? "" : level + "/") + endpoint[..<slash]
            let pinName = String(endpoint[endpoint.index(after: slash)...])
            guard let pin = cell(atPath: cellPath)?.pin(named: pinName) else { return nil }
            return (cellPath, pin)
        }
        if level.isEmpty { return port(named: endpoint).map { (nil, $0) } }
        return cell(atPath: level)?.pin(named: endpoint).map { (level, $0) }
    }

    /// The IPs it uses and how many of each, most used first (for summaries).
    public var ipCounts: [(vlnv: String, count: Int)] {
        Dictionary(grouping: allCells.filter { $0.kind == .ip }, by: \.vlnv).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.vlnv < $1.vlnv }
    }

    /// The names Vivado shows under common IP blocks. The `.bd` and `.xci` files don't carry them (they come from each
    /// IP's own definition, inside Vivado), so anything not listed shows its IP name instead.
    public static let displayNames: [String: String] = [
        "microblaze": "MicroBlaze", "microblaze_riscv": "MicroBlaze V", "mdm": "MicroBlaze Debug Module (MDM)",
        "mdm_riscv": "MicroBlaze V Debug Module (MDM)",
        "axi_uartlite": "AXI Uartlite", "axi_uart16550": "AXI UART16550", "axi_gpio": "AXI GPIO", "axi_timer": "AXI Timer",
        "axi_intc": "AXI Interrupt Controller", "axi_iic": "AXI IIC", "axi_quad_spi": "AXI Quad SPI",
        "axi_bram_ctrl": "AXI BRAM Controller", "axi_interconnect": "AXI Interconnect", "smartconnect": "AXI SmartConnect",
        "axi_crossbar": "AXI Crossbar", "axi_dma": "AXI Direct Memory Access", "axi_ethernetlite": "AXI EthernetLite",
        "axi_protocol_converter": "AXI Protocol Converter", "axi_dwidth_converter": "AXI Data Width Converter",
        "axi_clock_converter": "AXI Clock Converter", "axi_register_slice": "AXI Register Slice",
        "axis_data_fifo": "AXI4-Stream Data FIFO", "axi_fifo_mm_s": "AXI-Stream FIFO",
        "clk_wiz": "Clocking Wizard", "proc_sys_reset": "Processor System Reset", "util_ds_buf": "Utility Buffer",
        "lmb_v10": "Local Memory Bus (LMB) 1.0", "lmb_bram_if_cntlr": "LMB BRAM Controller",
        "blk_mem_gen": "Block Memory Generator", "emb_mem_gen": "Embedded Memory Generator",
        "util_vector_logic": "Utility Vector Logic", "util_reduced_logic": "Utility Reduced Logic",
        "xlconstant": "Constant", "xlconcat": "Concat", "xlslice": "Slice", "ilconstant": "Constant", "ilconcat": "Concat",
        "ilslice": "Slice", "ilvector_logic": "Vector Logic", "ilreduced_logic": "Reduced Logic",
        "processing_system7": "ZYNQ7 Processing System", "zynq_ultra_ps_e": "Zynq UltraScale+ MPSoC",
        "xadc_wiz": "XADC Wizard", "system_ila": "System ILA", "ila": "ILA (Integrated Logic Analyzer)",
        "vio": "VIO (Virtual Input/Output)", "c_counter_binary": "Binary Counter", "c_addsub": "Adder/Subtracter",
        "mult_gen": "Multiplier", "dds_compiler": "DDS Compiler", "fifo_generator": "FIFO Generator",
        "mig_7series": "Memory Interface Generator (MIG 7 Series)", "axi_vip": "AXI Verification IP",
        "sim_clk_gen": "Simulation Clock Generator",
    ]
}

// MARK: Reading

public enum BlockDesignError: DescribedError, Equatable {
    case unreadable(String)
    case notABlockDesign(String)

    public var description: String {
        switch self {
        case .unreadable(let path): "Couldn't read \(path)."
        case .notABlockDesign(let why): "This isn't a block design Vivado saved: \(why). Vivado 2016.1 and later save block designs as JSON."
        }
    }
}

extension BlockDesign {
    /// Reads a `.bd` file and, from `ip/` next to it, each IP's `.xci` for the pins the `.bd` doesn't list.
    public static func load(from url: URL) throws -> BlockDesign {
        guard let data = try? Data(contentsOf: url) else { throw BlockDesignError.unreadable(url.lastPathComponent) }
        let folder = url.deletingLastPathComponent()
        return try parse(data) { cell in
            // `xci_path` is written with Windows separators (`ip\name\name.xci`).
            let relative = cell.xciPath.isEmpty ? "ip/\(cell.xciName)/\(cell.xciName).xci" : cell.xciPath.replacingOccurrences(of: "\\", with: "/")
            guard !cell.xciName.isEmpty || !cell.xciPath.isEmpty else { return nil }
            return try? Data(contentsOf: folder.appendingPathComponent(relative))
        }
    }

    /// What `load` needs to find a cell's `.xci`.
    public struct XCIReference: Sendable {
        public let xciName: String
        public let xciPath: String
    }

    /// Parses a `.bd`. `xci` returns the contents of an IP's `.xci` file, or nil if it isn't there.
    public static func parse(_ data: Data, xci: (XCIReference) -> Data? = { _ in nil }) throws -> BlockDesign {
        let root: OrderedJSON
        do { root = try OrderedJSON.parse(data) } catch { throw BlockDesignError.notABlockDesign(error.userMessage) }
        guard let design = root["design"], case .object = design else { throw BlockDesignError.notABlockDesign("it has no \"design\" object") }
        let info = design["design_info"]
        let name = info?["name"]?.text ?? ""

        let top = parseLevel(design, path: "", xci: xci)
        return BlockDesign(name: name,
                           part: info?["device"]?.text ?? "",
                           toolVersion: info?["tool_version"]?.text ?? "",
                           isValidated: info?["validated"]?.text == "true",
                           ports: top.pins, cells: top.cells, nets: top.nets,
                           addressSegments: parseAddressing(design, cells: top.cells))
    }

    /// The pins, cells and nets of one level: the design itself, or a hierarchy.
    private static func parseLevel(_ object: OrderedJSON, path: String, xci: (XCIReference) -> Data?)
        -> (pins: [BDPin], cells: [BDCell], nets: [BDNet]) {
        let pins = interfacePins(object["interface_ports"]) + signalPins(object["ports"])
        var nets: [BDNet] = []
        for (netName, net) in object["interface_nets"]?.members ?? [] {
            nets.append(BDNet(name: netName, isInterface: true, endpoints: net["interface_ports"]?.elements.compactMap(\.text) ?? []))
        }
        for (netName, net) in object["nets"]?.members ?? [] {
            nets.append(BDNet(name: netName, isInterface: false, endpoints: net["ports"]?.elements.compactMap(\.text) ?? []))
        }
        var cells: [BDCell] = []
        for (cellName, component) in object["components"]?.members ?? [] {
            let cellPath = path.isEmpty ? cellName : path + "/" + cellName
            cells.append(parseCell(cellName, component, path: cellPath, level: nets, xci: xci))
        }
        return (pins, cells, nets)
    }

    private static func parseCell(_ name: String, _ component: OrderedJSON, path: String, level nets: [BDNet],
                                  xci: (XCIReference) -> Data?) -> BDCell {
        let vlnv = component["vlnv"]?.text ?? ""
        let hasContents = component["components"] != nil
        let reference = component["reference_info"]
        let kind: BDCell.Kind = hasContents || vlnv.isEmpty ? .hierarchy : reference != nil || vlnv.contains(":module_ref:") ? .moduleReference : .ip
        let xciName = component["xci_name"]?.text ?? ""
        let xciPath = component["xci_path"]?.text ?? ""

        // The pins the .bd lists itself: all of them for a hierarchy or a module reference, only some for an IP.
        var pins = interfacePins(component["interface_ports"]) + signalPins(component["ports"])
        var parameters = bdParameters(component["parameters"])
        var full = kind != .ip
        if kind != .hierarchy, let data = xci(XCIReference(xciName: xciName, xciPath: xciPath)),
           let instance = try? OrderedJSON.parse(data)["ip_inst"] {
            let boundary = xciPins(instance["boundary"])
            // A hierarchy-like IP (the AXI Interconnect) has an empty boundary; its .bd pins are the real ones.
            if !boundary.isEmpty, kind == .ip || pins.isEmpty {
                pins = boundary
                full = true
            }
            let userSet = Set(parameters.map(\.name))
            let fromXCI = xciParameters(instance["parameters"]?["component_parameters"], userSet: userSet)
            if !fromXCI.isEmpty {
                // The .bd's values are the user's; anything the .xci has that the .bd doesn't is a default.
                let bdValues = Dictionary(parameters.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
                parameters = fromXCI.map { p in BDParameter(name: p.name, value: bdValues[p.name] ?? p.value, isUserSet: p.isUserSet) }
                parameters += bdParameters(component["parameters"]).filter { p in !fromXCI.contains { $0.name == p.name } }
            }
        }
        if !full { pins = pinsFromNets(cell: name, known: pins, nets: nets) }

        let inner: (pins: [BDPin], cells: [BDCell], nets: [BDNet]) = kind == .hierarchy || hasContents ? parseLevel(component, path: path, xci: xci) : ([], [], [])
        return BDCell(name: name, path: path, kind: kind, vlnv: vlnv, xciName: xciName,
                      referenceName: reference?["ref_name"]?.text ?? "", parameters: parameters, pins: pins,
                      hasFullPinList: full, cells: inner.cells, nets: inner.nets)
    }

    /// Adds the pins that only show up as net endpoints, for an IP whose `.xci` isn't there. The driver is listed first
    /// in each net, which gives its direction.
    private static func pinsFromNets(cell: String, known: [BDPin], nets: [BDNet]) -> [BDPin] {
        var pins = known
        for net in nets {
            for (k, end) in net.endpoints.enumerated() where end.hasPrefix(cell + "/") {
                let pinName = String(end.dropFirst(cell.count + 1))
                guard !pinName.contains("/"), !pins.contains(where: { $0.name == pinName }) else { continue }
                pins.append(BDPin(name: pinName, isInterface: net.isInterface, direction: k == 0 ? .output : .input,
                                  type: net.isInterface ? "" : "undef", mode: net.isInterface ? (k == 0 ? "Master" : "Slave") : ""))
            }
        }
        return pins
    }

    private static func int(_ value: OrderedJSON?) -> Int? { value?.text.flatMap { Int($0) } }

    private static func bdParameters(_ object: OrderedJSON?) -> [BDParameter] {
        (object?.members ?? []).compactMap { key, value in
            guard let text = value["value"]?.text else { return nil }
            let source = value["value_src"]?.text ?? "user"
            return BDParameter(name: key, value: text, isUserSet: !["default", "default_prop", "constant", "ip_prop"].contains(source))
        }
    }

    private static func xciParameters(_ object: OrderedJSON?, userSet: Set<String>) -> [BDParameter] {
        (object?.members ?? []).compactMap { key, value in
            guard key != "Component_Name", let first = value.elements.first, let text = first["value"]?.text else { return nil }
            let source = first["value_src"]?.text ?? "default"
            return BDParameter(name: key, value: text, isUserSet: userSet.contains(key) || source == "user")
        }
    }

    /// Vivado writes a mode as `Master` in a .bd and `master` in an .xci.
    static func capitalizedMode(_ mode: String) -> String {
        guard let first = mode.first else { return mode }
        return first.uppercased() + mode.dropFirst()
    }

    /// Which side an interface is drawn on: what drives into the block (a slave, or a mirrored master, which faces a
    /// master) is an input.
    static func direction(ofMode mode: String) -> BDDirection {
        switch mode.lowercased() {
        case "master", "mirroredslave": .output
        default: .input
        }
    }

    private static func interfacePins(_ object: OrderedJSON?) -> [BDPin] {
        (object?.members ?? []).map { key, value in
            let mode = capitalizedMode(value["mode"]?.text ?? "")
            return BDPin(name: key, isInterface: true, direction: direction(ofMode: mode), mode: mode,
                         vlnv: value["vlnv_bus_definition"]?.text ?? value["vlnv"]?.text?.replacingOccurrences(of: "_rtl:", with: ":") ?? "",
                         parameters: bdParameters(value["parameters"]))
        }
    }

    private static func signalPins(_ object: OrderedJSON?) -> [BDPin] {
        (object?.members ?? []).map { key, value in
            BDPin(name: key, isInterface: false, direction: BDDirection(value["direction"]?.text ?? "I"),
                  type: value["type"]?.text ?? "undef", left: int(value["left"]), right: int(value["right"]),
                  parameters: bdParameters(value["parameters"]))
        }
    }

    /// An IP's pins from its `.xci` boundary, as IP Integrator shows them: each bus interface as one pin (clock, reset,
    /// interrupt and the other one-signal interfaces are shown as their signal instead, typed `clk`, `rst`...), then
    /// every port that isn't part of a bus interface.
    static func xciPins(_ boundary: OrderedJSON?) -> [BDPin] {
        guard let boundary else { return [] }
        let signalTypes = ["clock": "clk", "reset": "rst", "interrupt": "intr", "clockenable": "ce", "data": "data"]
        var interfaces: [BDPin] = []
        var inInterface: Set<String> = []
        var portType: [String: String] = [:]
        for (key, value) in boundary["interfaces"]?.members ?? [] {
            let vlnv = value["vlnv"]?.text ?? ""
            let physical = (value["port_maps"]?.members ?? []).flatMap { $0.value.elements.compactMap { $0["physical_name"]?.text } }
            let parts = vlnv.split(separator: ":")
            if parts.count >= 3, parts[1] == "signal" {
                for port in physical { portType[port] = signalTypes[String(parts[2])] ?? "undef" }
                continue
            }
            inInterface.formUnion(physical)
            let mode = capitalizedMode(value["mode"]?.text ?? "")
            interfaces.append(BDPin(name: key, isInterface: true, direction: direction(ofMode: mode), mode: mode, vlnv: vlnv))
        }
        var signals: [BDPin] = []
        for (key, value) in boundary["ports"]?.members ?? [] where !inInterface.contains(key) {
            let port = value.elements.first ?? value
            let left = int(port["size_left"]), right = int(port["size_right"])
            signals.append(BDPin(name: key, isInterface: false, direction: BDDirection(port["direction"]?.text ?? "in"),
                                 type: portType[key] ?? "undef",
                                 left: left == nil && right == nil ? nil : left, right: left == nil && right == nil ? nil : right))
        }
        return interfaces + signals
    }

    /// Each master's address spaces' widths, by `/master/space`: the master's own entry has them, the design's
    /// `addressing` section doesn't.
    private static func addressSpaceWidths(_ level: OrderedJSON, path: String) -> [String: Int] {
        var widths: [String: Int] = [:]
        for (name, component) in level["components"]?.members ?? [] {
            let cellPath = path + "/" + name
            for (space, entry) in component["addressing"]?["address_spaces"]?.members ?? [] {
                if let width = int(entry["width"]) { widths["\(cellPath)/\(space)"] = width }
            }
            widths.merge(addressSpaceWidths(component, path: cellPath)) { a, _ in a }
        }
        return widths
    }

    /// The Address Editor's rows: for each master and address space, the slave segments it reaches.
    private static func parseAddressing(_ design: OrderedJSON, cells: [BDCell]) -> [BDAddressSegment] {
        var segments: [BDAddressSegment] = []
        let widths = addressSpaceWidths(design, path: "")
        for (master, entry) in design["addressing"]?.members ?? [] {
            for (space, spaceEntry) in entry["address_spaces"]?.members ?? [] {
                let width = int(spaceEntry["width"]) ?? widths["\(master)/\(space)"] ?? 32
                for (group, list) in spaceEntry.members where group.contains("segments") {
                    for (segment, value) in list.members {
                        let rangeText = value["range"]?.text ?? ""
                        segments.append(BDAddressSegment(
                            master: master, addressSpace: space, name: segment,
                            addressBlock: value["address_block"]?.text ?? "",
                            offset: value["offset"]?.text.flatMap(BDAddressSegment.parseSize) ?? 0,
                            range: BDAddressSegment.parseSize(rangeText) ?? 0, rangeText: rangeText,
                            isExcluded: group.contains("excluded") || value["is_excluded"]?.text == "TRUE", width: width))
                    }
                }
            }
        }
        return segments
    }
}
