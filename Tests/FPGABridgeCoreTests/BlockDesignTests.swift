import XCTest
@testable import FPGABridgeCore

/// Block designs saved by Vivado 2025.2 (see Fixtures/blockdesign_vivado2025, made by the probe Tcl in its
/// `reference/` folder): `mb_system`, a MicroBlaze with AXI UART Lite and GPIO wired by Vivado's automation, and
/// `wired`, a small hand-wired one with external ports, plain nets, a hierarchy and an RTL module reference.
final class BlockDesignTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "blockdesign_vivado2025", withExtension: nil, subdirectory: "Fixtures"))
        return folder.appendingPathComponent("\(name)/\(name).bd")
    }

    func load(_ name: String) throws -> BlockDesign { try BlockDesign.load(from: try fixture(name)) }

    // MARK: Ordered JSON

    func testJSONKeepsKeyOrderAndReadsWindowsLineEndings() throws {
        let json = try OrderedJSON.parse("{\r\n  \"z\": 1,\r\n  \"a\": [true, false, null],\r\n  \"m\": {\"k\": \"v\\u00e9\\n\"}\r\n}\r\n")
        XCTAssertEqual(json.members.map(\.key), ["z", "a", "m"])
        XCTAssertEqual(json["z"]?.text, "1")
        XCTAssertEqual(json["a"]?.elements, [.bool(true), .bool(false), .null])
        XCTAssertEqual(json["m"]?["k"]?.text, "vé\n")
        XCTAssertEqual(try OrderedJSON.parse("[1.5, -2, 3e2]").elements.compactMap(\.text), ["1.5", "-2", "300"])
        XCTAssertEqual(try OrderedJSON.parse("\"\\ud83d\\ude00\"").text, "😀")
        XCTAssertThrowsError(try OrderedJSON.parse("{\"a\": }"))
        XCTAssertThrowsError(try OrderedJSON.parse("{} extra"))
    }

    func testTheFixturesAreWhatVivadoWrites() throws {
        // Vivado on Windows writes CR LF; the parser must not care.
        let text = try String(contentsOf: try fixture("mb_system"), encoding: .utf8)
        XCTAssertTrue(text.contains("\r\n"))
    }

    // MARK: The hand-wired design

    func testWiredDesignInfoAndPorts() throws {
        let design = try load("wired")
        XCTAssertEqual(design.name, "wired")
        XCTAssertEqual(design.part, "xc7a35tcpg236-1")
        XCTAssertEqual(design.toolVersion, "2025.2")
        XCTAssertTrue(design.isValidated)
        XCTAssertEqual(design.ports.map(\.name), ["sys_clk", "sys_rst", "led", "sw", "ready"], "in the order Vivado saved them")
        XCTAssertEqual(design.ports.map(\.direction), [.input, .input, .output, .input, .output])
        XCTAssertEqual(design.ports.map(\.type), ["clk", "rst", "undef", "undef", "undef"])
        XCTAssertEqual(design.port(named: "led")?.label, "led[3:0]")
        XCTAssertEqual(design.port(named: "led")?.width, 4)
        XCTAssertEqual(design.port(named: "ready")?.label, "ready", "a [0:0] vector is written as one bit")
        XCTAssertEqual(design.port(named: "sys_clk")?.parameters.first { $0.name == "FREQ_HZ" }?.value, "100000000")
    }

    func testWiredDesignCells() throws {
        let design = try load("wired")
        XCTAssertEqual(design.cells.map(\.name), ["inv_0", "one", "concat_0", "sync", "blink_0"])
        XCTAssertEqual(design.allCells.map(\.path), ["inv_0", "one", "concat_0", "sync", "sync/and_0", "blink_0"])

        let inv = try XCTUnwrap(design.cell(atPath: "inv_0"))
        XCTAssertEqual(inv.kind, .ip)
        XCTAssertEqual(inv.vlnv, "xilinx.com:ip:util_vector_logic:2.0")
        XCTAssertEqual(inv.displayName, "Utility Vector Logic")
        XCTAssertEqual(inv.xciName, "wired_inv_0_0")
        // The .xci lists every pin, including Res, which nothing connects to.
        XCTAssertTrue(inv.hasFullPinList)
        XCTAssertEqual(inv.pins.map(\.name), ["Op1", "Res"])
        XCTAssertEqual(inv.pins.map(\.direction), [.input, .output])
        let operation = try XCTUnwrap(inv.parameters.first { $0.name == "C_OPERATION" })
        XCTAssertEqual(operation.value, "not")
        XCTAssertTrue(operation.isUserSet)
        XCTAssertFalse(inv.parameters.contains { $0.name == "Component_Name" })

        let sync = try XCTUnwrap(design.cell(atPath: "/sync"))
        XCTAssertEqual(sync.kind, .hierarchy)
        XCTAssertEqual(sync.displayName, "")
        XCTAssertEqual(sync.pins.map(\.label), ["clk", "d[1:0]", "q[1:0]"])
        XCTAssertEqual(sync.cells.map(\.path), ["sync/and_0"])
        XCTAssertEqual(sync.nets.map(\.name), ["and_0_Res", "d_1"])
        XCTAssertEqual(design.nets(in: "sync").first { $0.name == "d_1" }?.endpoints, ["d", "and_0/Op1", "and_0/Op2"])

        let blink = try XCTUnwrap(design.cell(atPath: "blink_0"))
        XCTAssertEqual(blink.kind, .moduleReference)
        XCTAssertEqual(blink.referenceName, "blink")
        XCTAssertEqual(blink.displayName, "blink")
        XCTAssertEqual(blink.pins.map(\.label), ["clk", "rst", "led[3:0]"])
        XCTAssertEqual(blink.pins.map(\.type), ["clk", "rst", "undef"])
    }

    func testWiredDesignNetsListTheirDriverFirst() throws {
        let design = try load("wired")
        let reset = try XCTUnwrap(design.nets.first { $0.name == "sys_rst_1" })
        XCTAssertFalse(reset.isInterface)
        XCTAssertEqual(reset.endpoints, ["sys_rst", "inv_0/Op1", "blink_0/rst"])
        XCTAssertEqual(design.pin(endpoint: "sys_rst", in: "")?.pin.direction, .input)
        XCTAssertEqual(design.pin(endpoint: "blink_0/rst", in: "")?.cell, "blink_0")
        XCTAssertEqual(design.pin(endpoint: "and_0/Res", in: "sync")?.cell, "sync/and_0")
        XCTAssertEqual(design.pin(endpoint: "q", in: "sync")?.cell, "sync", "a bare name inside a hierarchy is its own pin")
        XCTAssertNil(design.pin(endpoint: "nope/x", in: ""))
        XCTAssertTrue(design.addressSegments.isEmpty)
    }

    // MARK: MicroBlaze

    func testMicroBlazeExternalInterfaces() throws {
        let design = try load("mb_system")
        XCTAssertEqual(design.ports.map(\.name), ["UART_0", "GPIO_0", "sys_clock", "reset"], "interface ports first, as the .bd lists them")
        let uart = try XCTUnwrap(design.port(named: "UART_0"))
        XCTAssertTrue(uart.isInterface)
        XCTAssertEqual(uart.mode, "Master")
        XCTAssertEqual(uart.direction, .output, "a master interface port leaves the design")
        XCTAssertEqual(uart.vlnv, "xilinx.com:interface:uart:1.0")
        XCTAssertEqual(uart.interfaceKind, "uart")
        XCTAssertEqual(design.port(named: "reset")?.parameters.first { $0.name == "POLARITY" }?.value, "ACTIVE_HIGH")
    }

    func testMicroBlazeCellsAndHierarchy() throws {
        let design = try load("mb_system")
        XCTAssertEqual(design.cells.map(\.name), ["microblaze_0", "microblaze_0_local_memory", "mdm_1", "clk_wiz_1",
                                                  "rst_clk_wiz_1_100M", "axi_uartlite_0", "axi_gpio_0", "microblaze_0_axi_periph"])
        XCTAssertEqual(design.allCells.count, 17, "every block and hierarchy Vivado listed with get_bd_cells -hier")
        XCTAssertEqual(design.ipCounts.first?.vlnv, "xilinx.com:ip:lmb_bram_if_cntlr:4.0")

        let mb = try XCTUnwrap(design.cell(atPath: "microblaze_0"))
        XCTAssertEqual(mb.displayName, "MicroBlaze")
        // Bus interfaces first (clock and reset interfaces are shown as their signal), then the signals.
        XCTAssertEqual(mb.pins.filter(\.isInterface).map(\.name), ["INTERRUPT", "DLMB", "ILMB", "M_AXI_DP", "DEBUG"])
        XCTAssertEqual(mb.pins.filter(\.isInterface).map(\.mode), ["Slave", "Master", "Master", "Master", "Slave"])
        XCTAssertEqual(mb.pin(named: "Clk")?.type, "clk")
        XCTAssertEqual(mb.pin(named: "Reset")?.type, "rst")
        XCTAssertNil(mb.pin(named: "M_AXI_DP_AWADDR"), "a port inside a bus interface isn't a pin of its own")

        let uart = try XCTUnwrap(design.cell(atPath: "axi_uartlite_0"))
        XCTAssertEqual(uart.pins.map(\.name), ["S_AXI", "UART", "s_axi_aclk", "s_axi_aresetn", "interrupt"])
        XCTAssertEqual(uart.pins.map(\.type), ["", "", "clk", "rst", "intr"])
        XCTAssertEqual(uart.pin(named: "S_AXI")?.direction, .input)
        XCTAssertEqual(uart.pin(named: "UART")?.direction, .output)
        let baud = try XCTUnwrap(uart.parameters.first { $0.name == "C_BAUDRATE" })
        XCTAssertEqual(baud.value, "115200")
        XCTAssertTrue(baud.isUserSet)
        XCTAssertEqual(uart.parameters.first { $0.name == "C_DATA_BITS" }?.isUserSet, false)

        // With every bit an output, the GPIO's gpio_io_o is inside its GPIO interface.
        XCTAssertEqual(design.cell(atPath: "axi_gpio_0")?.pins.map(\.name), ["S_AXI", "GPIO", "s_axi_aclk", "s_axi_aresetn"])

        let memory = try XCTUnwrap(design.cell(atPath: "microblaze_0_local_memory"))
        XCTAssertEqual(memory.kind, .hierarchy)
        XCTAssertEqual(memory.pins.map(\.name), ["DLMB", "ILMB", "LMB_Clk", "SYS_Rst"])
        XCTAssertEqual(memory.pin(named: "DLMB")?.mode, "MirroredMaster")
        XCTAssertEqual(memory.pin(named: "DLMB")?.direction, .input, "a mirrored master faces a master, so it's driven")
        XCTAssertEqual(memory.cells.map(\.name), ["dlmb_v10", "ilmb_v10", "dlmb_bram_if_cntlr", "ilmb_bram_if_cntlr", "lmb_bram"])

        let interconnect = try XCTUnwrap(design.cell(atPath: "microblaze_0_axi_periph"))
        XCTAssertEqual(interconnect.kind, .hierarchy, "the AXI Interconnect is an IP made of a hierarchy")
        XCTAssertEqual(interconnect.displayName, "AXI Interconnect")
        XCTAssertEqual(interconnect.pins.filter(\.isInterface).map(\.name), ["S00_AXI", "M00_AXI", "M01_AXI"])
        XCTAssertEqual(interconnect.parameters.first { $0.name == "NUM_MI" }?.value, "2")
    }

    func testMicroBlazeInterfaceNets() throws {
        let design = try load("mb_system")
        let bus = try XCTUnwrap(design.nets.first { $0.name == "microblaze_0_axi_periph_M00_AXI" })
        XCTAssertTrue(bus.isInterface)
        XCTAssertEqual(bus.endpoints, ["microblaze_0_axi_periph/M00_AXI", "axi_uartlite_0/S_AXI"])
        XCTAssertEqual(design.nets.filter(\.isInterface).count, 8)
        XCTAssertEqual(design.nets.filter { !$0.isInterface }.count, 8)
        XCTAssertEqual(design.nets.first { $0.name == "microblaze_0_Clk" }?.endpoints.count, 10)
    }

    func testAddressEditorRows() throws {
        let design = try load("mb_system")
        // As Vivado reported them (get_bd_addr_segs) after assign_bd_address.
        XCTAssertEqual(design.addressSegments.map(\.name), ["SEG_axi_gpio_0_Reg", "SEG_axi_uartlite_0_Reg",
                                                            "SEG_dlmb_bram_if_cntlr_Mem", "SEG_ilmb_bram_if_cntlr_Mem"])
        let gpio = design.addressSegments[0]
        XCTAssertEqual(gpio.master, "/microblaze_0")
        XCTAssertEqual(gpio.addressSpace, "Data")
        XCTAssertEqual(gpio.slave, "/axi_gpio_0")
        XCTAssertEqual(gpio.slaveInterface, "S_AXI")
        XCTAssertEqual(gpio.slaveSegment, "Reg")
        XCTAssertEqual(gpio.offset, 0x4000_0000)
        XCTAssertEqual(gpio.range, 64 * 1024)
        XCTAssertEqual(gpio.rangeText, "64K")
        XCTAssertEqual(BDAddressSegment.format(gpio.offset, width: gpio.width), "0x4000_0000")
        XCTAssertEqual(BDAddressSegment.format(gpio.high, width: gpio.width), "0x4000_FFFF")
        let lmb = design.addressSegments[3]
        XCTAssertEqual(lmb.addressSpace, "Instruction")
        XCTAssertEqual(lmb.slave, "/microblaze_0_local_memory/ilmb_bram_if_cntlr")
        XCTAssertEqual(lmb.slaveInterface, "SLMB")
        XCTAssertEqual(BDAddressSegment.format(lmb.high), "0x0000_1FFF")
    }

    func testAddressFormatting() {
        XCTAssertEqual(BDAddressSegment.format(0, width: 64), "0x0000_0000_0000_0000")
        XCTAssertEqual(BDAddressSegment.format(0xA000_0000, width: 40), "0x00_A000_0000")
        XCTAssertEqual(BDAddressSegment.parseSize("4G"), 4 << 30)
        XCTAssertEqual(BDAddressSegment.parseSize("8K"), 8192)
        XCTAssertEqual(BDAddressSegment.parseSize("0x40600000"), 0x4060_0000)
        XCTAssertEqual(BDAddressSegment.parseSize("4096"), 4096)
        XCTAssertNil(BDAddressSegment.parseSize("lots"))
    }

    // MARK: Without the IP files

    func testWithoutXCIFilesPinsComeFromTheNets() throws {
        let data = try Data(contentsOf: try fixture("wired"))
        let design = try BlockDesign.parse(data)
        let inv = try XCTUnwrap(design.cell(atPath: "inv_0"))
        XCTAssertFalse(inv.hasFullPinList)
        XCTAssertEqual(inv.pins.map(\.name), ["Op1"], "Res connects to nothing, so only the .xci knows it")
        XCTAssertEqual(inv.pins.first?.direction, .input)
        XCTAssertEqual(design.cell(atPath: "one")?.pins.first?.direction, .output, "a net's first endpoint drives it")
        XCTAssertEqual(design.cell(atPath: "blink_0")?.pins.count, 3, "a module reference's pins are in the .bd")
        XCTAssertEqual(design.cell(atPath: "inv_0")?.parameters.first?.value, "not")
    }

    func testRejectsWhatIsNotABlockDesign() {
        XCTAssertThrowsError(try BlockDesign.parse(Data("<bd>xml</bd>".utf8))) { error in
            XCTAssertTrue(error.userMessage.contains("isn't a block design"))
        }
        XCTAssertThrowsError(try BlockDesign.parse(Data("{\"something\": 1}".utf8)))
        XCTAssertThrowsError(try BlockDesign.load(from: URL(fileURLWithPath: "/nonexistent/x.bd")))
    }

    // MARK: Diagram

    func testMicroBlazeDiagram() throws {
        let design = try load("mb_system")
        let diagram = try BlockDesignDiagram.layout(design)
        let layout = diagram.layout
        XCTAssertEqual(Set(diagram.cells.keys), Set(design.cells.map(\.path)), "the top level's blocks, hierarchies closed")
        XCTAssertEqual(Set(diagram.ports.values.map(\.name)), ["UART_0", "GPIO_0", "sys_clock", "reset"])
        // Every connection at the top is drawn, interfaces as buses.
        XCTAssertEqual(layout.wires.count, design.nets.count)
        XCTAssertEqual(layout.wires.filter(diagram.isInterface).count, 8)
        for wire in layout.wires { XCTAssertNotNil(diagram.net(of: wire)) }
        // Every pin drawn maps back to the block design, in the block's own order.
        for node in layout.nodes { for pin in node.pins { XCTAssertNotNil(diagram.pin(pin.id), pin.id) } }
        let uart = try XCTUnwrap(layout.nodes.first { $0.id == "axi_uartlite_0" })
        XCTAssertEqual(uart.pins.filter { $0.side == .left }.compactMap { diagram.pin($0.id)?.pin.name }, ["S_AXI", "s_axi_aclk", "s_axi_aresetn"])
        XCTAssertEqual(uart.pins.filter { $0.side == .right }.compactMap { diagram.pin($0.id)?.pin.name }, ["UART", "interrupt"])
        XCTAssertEqual(uart.subtitle, "AXI Uartlite")
        // Inputs on the left edge, outputs on the right, everything flowing left to right.
        let clock = try XCTUnwrap(layout.nodes.first { $0.id == "port:sys_clock" })
        let gpio = try XCTUnwrap(layout.nodes.first { $0.id == "port:GPIO_0" })
        let cellFrames = layout.nodes.filter { diagram.cells[$0.id] != nil }.map(\.frame)
        XCTAssertLessThan(clock.frame.maxX, cellFrames.map(\.minX).min() ?? 0)
        XCTAssertGreaterThan(gpio.frame.minX, cellFrames.map(\.maxX).max() ?? 0)
        let wizard = try XCTUnwrap(layout.nodes.first { $0.id == "clk_wiz_1" })
        let processor = try XCTUnwrap(layout.nodes.first { $0.id == "microblaze_0" })
        XCTAssertLessThan(wizard.frame.maxX, processor.frame.minX, "the clock feeds the processor, so it sits to its left")
    }

    func testOpeningAHierarchyInPlace() throws {
        let design = try load("mb_system")
        let diagram = try BlockDesignDiagram.layout(design, expanded: ["microblaze_0_local_memory"])
        let ids = Set(diagram.layout.nodes.map(\.id))
        XCTAssertTrue(ids.contains("microblaze_0_local_memory/lmb_bram"))
        XCTAssertEqual(diagram.layout.nodes.first { $0.id == "microblaze_0_local_memory" }?.kind, .module(open: true))
        XCTAssertEqual(diagram.layout.wires.count, design.nets.count + design.nets(in: "microblaze_0_local_memory").count)
        XCTAssertEqual(diagram.cells["microblaze_0_local_memory/lmb_bram"]?.displayName, "Block Memory Generator")
    }

    func testWiredDiagramAndAnEmptyOne() throws {
        let diagram = try BlockDesignDiagram.layout(try load("wired"))
        XCTAssertEqual(diagram.layout.wires.count, 6)
        XCTAssertEqual(diagram.layout.wires.filter(diagram.isInterface).count, 0)
        let inv = try XCTUnwrap(diagram.layout.nodes.first { $0.id == "inv_0" })
        XCTAssertEqual(inv.pins.count, 2, "the unconnected output is drawn too")

        let empty = try BlockDesignDiagram.layout(BlockDesign(name: "empty", cells: [BDCell(name: "c", path: "c", kind: .ip, vlnv: "xilinx.com:ip:xlconstant:1.1")]))
        XCTAssertEqual(empty.layout.nodes.map(\.id), ["c"])
        XCTAssertTrue(empty.layout.wires.isEmpty)
    }

    func testABlockNamedLikeAGateIsStillABox() {
        let cell = BDCell(name: "and2", path: "and2", kind: .moduleReference, referenceName: "AND2")
        XCTAssertEqual(SchematicSymbol.forCell(type: BlockDesignDiagram.Netlist.typeLabel(cell), inputs: 1, outputs: 1, isPrimitive: true), .box)
    }

    // MARK: In a project

    func testProjectFindsItsBlockDesigns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bd-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcs = root.appendingPathComponent("demo.srcs/sources_1")
        try FileManager.default.createDirectory(at: srcs.appendingPathComponent("bd/mb_system/ip/x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcs.appendingPathComponent("proj.gen/bd/old"), withIntermediateDirectories: true)
        try Data(contentsOf: try fixture("mb_system")).write(to: srcs.appendingPathComponent("bd/mb_system/mb_system.bd"))
        try "{}".write(to: srcs.appendingPathComponent("proj.gen/bd/old/old.bd"), atomically: true, encoding: .utf8)
        try "module top; endmodule".write(to: srcs.appendingPathComponent("top.v"), atomically: true, encoding: .utf8)

        var project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1", sources: ["demo.srcs/sources_1"], constraints: [])
        XCTAssertEqual(project.resolveBlockDesigns(in: root), ["demo.srcs/sources_1/bd/mb_system/mb_system.bd"])
        // The build reads HDL only: the block design is left out rather than read as Verilog.
        XCTAssertEqual(try project.resolveSources(in: root), ["demo.srcs/sources_1/top.v"])
        let notes = project.blockDesignBuildNotes(in: root)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].hasPrefix("WARNING:") && notes[0].contains("mb_system.bd"))

        project.top = "mb_system_wrapper"
        project.sources.append("demo.srcs/sources_1/bd/mb_system/mb_system.bd")
        let more = project.blockDesignBuildNotes(in: root)
        XCTAssertEqual(more.count, 3)
        XCTAssertTrue(more[1].hasPrefix("ERROR:") && more[1].contains("read it as Verilog"))
        XCTAssertTrue(more[2].contains("mb_system_wrapper"))
        XCTAssertEqual(project.resolveBlockDesigns(in: root).count, 1, "found once, however it's listed")

        let plain = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1", sources: ["missing", "/abs", "../up"], constraints: [])
        XCTAssertEqual(plain.resolveBlockDesigns(in: root), [])
        XCTAssertEqual(plain.blockDesignBuildNotes(in: root), [])
        XCTAssertTrue(Project.isBlockDesign("a/b/C.BD"))
        XCTAssertFalse(Project.isBlockDesign("a/b.bda"))
    }
}
