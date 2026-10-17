import XCTest
@testable import FPGABridgeCore

/// The Netlist window's tree and the connectivity behind the Properties window, on Vivado 2025.2's demo_top netlist.
final class NetlistOutlineTests: XCTestCase {
    func snapshot(_ stage: DesignStage) throws -> DesignSnapshot {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "design_vivado2025", withExtension: nil, subdirectory: "Fixtures"))
        return try DesignSnapshot.load(stage: stage, from: dir)
    }

    // MARK: The tree

    func testTheTopOpensToNetsLeafCellsAndSubModules() throws {
        let rtl = try snapshot(.rtl)
        let rows = NetlistOutline(design: rtl).rows(expanded: [])
        XCTAssertEqual(rows.map(\.title), ["demo_top", "Nets", "Leaf Cells", "u_tick"], "Vivado's order: Nets, Leaf Cells, then sub-modules")
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 1])
        XCTAssertEqual(rows[1].detail, "(101)", "nets at the top level only")
        XCTAssertEqual(rows[2].detail, "(53)")
        XCTAssertEqual(rows[3].detail, "(tick_gen)")
        XCTAssertNil(rows[0].object, "the top isn't a cell")
        XCTAssertEqual(rows[3].object, .cell("u_tick"))
    }

    func testBusesGroupTheirBitsInNaturalOrder() throws {
        let rtl = try snapshot(.rtl)
        let outline = NetlistOutline(design: rtl)
        let nets = outline.rows(expanded: [NetlistOutline.id(.netsFolder(module: ""))]).filter { $0.depth == 2 }
        let count = try XCTUnwrap(nets.first { $0.title == "count" })
        XCTAssertEqual(count.detail, "(8)")
        XCTAssertNil(count.object, "a bus row is a group, not a net")
        let clk = try XCTUnwrap(nets.first { $0.title == "clk" })
        XCTAssertEqual(clk.object, .net("clk"))
        XCTAssertFalse(clk.hasChildren)

        let opened = outline.rows(expanded: [NetlistOutline.id(.netsFolder(module: "")), count.id])
        let bits = opened.filter { $0.depth == 3 }.map(\.title)
        XCTAssertEqual(bits, (0..<8).map { "count[\($0)]" })
    }

    func testLeafCellsShowTheirType() throws {
        let rtl = try snapshot(.rtl)
        let rows = NetlistOutline(design: rtl).rows(expanded: [NetlistOutline.id(.leafFolder(module: ""))])
        let and = try XCTUnwrap(rows.first { $0.title == "count0_i" })
        XCTAssertEqual(and.detail, "(RTL_AND)")
        XCTAssertEqual(and.object, .cell("count0_i"))
        XCTAssertEqual(and.depth, 2)
    }

    func testRevealingAnObjectOpensItsModulesAndFolder() throws {
        let rtl = try snapshot(.rtl)
        let outline = NetlistOutline(design: rtl)
        let cell = outline.idsToReveal(.cell("u_tick/count_reg[0]"))
        XCTAssertEqual(cell, [NetlistOutline.id(.module(path: "")), NetlistOutline.id(.module(path: "u_tick")),
                              NetlistOutline.id(.leafFolder(module: "u_tick"))])
        let rows = outline.rows(expanded: cell)
        XCTAssertTrue(rows.contains { $0.object == .cell("u_tick/count_reg[0]") }, "now visible")

        let bit = outline.idsToReveal(.net("count[3]"))
        XCTAssertTrue(bit.contains(NetlistOutline.id(.bus(module: "", name: "count"))))
        XCTAssertTrue(outline.rows(expanded: bit).contains { $0.object == .net("count[3]") })

        let module = outline.idsToReveal(.cell("u_tick"))
        XCTAssertFalse(module.contains(NetlistOutline.id(.module(path: "u_tick"))), "a module is shown, not opened")
        XCTAssertTrue(outline.rows(expanded: outline.idsToReveal(.pin("u_tick/count_reg[0]/C"))).contains { $0.object == .cell("u_tick/count_reg[0]") },
                      "a pin reveals its cell")
    }

    // MARK: Connectivity

    func testAPinsNetIsTheOneAtItsCellsLevel() throws {
        let rtl = try snapshot(.rtl)
        XCTAssertEqual(rtl.net(ofPin: "count_reg[0]/C"), "clk")
        XCTAssertEqual(rtl.net(ofPin: "u_tick/tick"), "tick", "a module's boundary pin: the net outside it")
        XCTAssertEqual(rtl.net(ofPin: "u_tick/tick_reg/Q"), "u_tick/tick")
        XCTAssertEqual(rtl.net(ofPort: "clk"), "clk")
        XCTAssertNil(rtl.net(ofPort: "nope"))
    }

    func testConnectivityFollowsANetThroughTheHierarchy() throws {
        let rtl = try snapshot(.rtl)
        let ends = rtl.flatConnectivity(of: "tick")
        XCTAssertEqual(Set(ends.map(\.name)), ["count0_i/I0", "u_tick/tick_reg/Q"], "the driver inside u_tick, not its boundary pin")

        let clk = rtl.flatConnectivity(of: "u_tick/clk")
        XCTAssertTrue(clk.contains(NetEndpoint(name: "clk", isPort: true)), "out to the top and its port")
        XCTAssertTrue(clk.contains(NetEndpoint(name: "count_reg[0]/C", isPort: false)), "and across to the top's flip-flops")
        XCTAssertTrue(clk.contains(NetEndpoint(name: "u_tick/tick_reg/C", isPort: false)))
        XCTAssertFalse(clk.contains { $0.name == "u_tick/clk" }, "boundary pins are passed through, not listed")
        XCTAssertEqual(clk.count, Set(clk).count, "each once")
        XCTAssertEqual(Set(rtl.flatConnectivity(of: "clk")), Set(clk), "the same signal from either end")
    }

    func testAncestorsAndContains() throws {
        XCTAssertEqual(DesignSnapshot.ancestors(of: "a/b/c"), ["", "a", "a/b"])
        XCTAssertEqual(DesignSnapshot.ancestors(of: "top_cell"), [""])
        let synth = try snapshot(.synth)
        XCTAssertTrue(synth.contains(.cell("count_reg[0]")))
        XCTAssertTrue(synth.contains(.pin("count_reg[0]/C")))
        XCTAssertTrue(synth.contains(.port("led[3]")))
        XCTAssertTrue(synth.contains(.net("clk_IBUF_BUFG")))
        XCTAssertFalse(synth.contains(.cell("count0_i")), "an RTL cell isn't in the synthesized design")
    }
}
