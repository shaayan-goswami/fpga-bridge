import XCTest
@testable import FPGABridgeCore

/// Connectivity, pins, source locations and properties, read from what Vivado 2025.2 wrote for demo_top on a Basys 3.
final class DesignNetlistTests: XCTestCase {
    func snapshot(_ stage: DesignStage) throws -> DesignSnapshot {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "design_vivado2025", withExtension: nil, subdirectory: "Fixtures"))
        return try DesignSnapshot.load(stage: stage, from: dir)
    }

    // MARK: Source locations

    func testCellsKnowTheirSourceLineRelativeToTheProject() throws {
        let rtl = try snapshot(.rtl)
        let and = try XCTUnwrap(rtl.cell(named: "count0_i"))
        XCTAssertEqual(and.type, "RTL_AND")
        XCTAssertEqual(and.sourceFile, "src/demo_top.v", "the build machine's job folder is taken off")
        XCTAssertEqual(and.sourceLine, 41)
        XCTAssertEqual(rtl.cell(named: "u_tick/count_reg[0]")?.sourceFile, "src/tick_gen.v")

        let synth = try snapshot(.synth)
        XCTAssertEqual(synth.cell(named: "btnC_IBUF_inst")?.sourceLine, 10, "synthesized cells keep their source line too")
        XCTAssertNil(synth.cell(named: "GND")?.sourceFile, "constants come from no line")
    }

    // MARK: Connectivity

    func testATopLevelNetReachesPinsThePortAndTheSubModuleBoundary() throws {
        let rtl = try snapshot(.rtl)
        XCTAssertTrue(rtl.hasConnectivity)
        let clk = try XCTUnwrap(rtl.nets.first { $0.name == "clk" })
        XCTAssertEqual(clk.type, "LOCAL_CLOCK")
        XCTAssertEqual(clk.parentPath, "")
        XCTAssertTrue(clk.endpoints.contains(NetEndpoint(name: "clk", isPort: true)))
        XCTAssertTrue(clk.endpoints.contains(NetEndpoint(name: "u_tick/clk", isPort: false)), "the sub-module's boundary pin")
        XCTAssertTrue(clk.endpoints.contains(NetEndpoint(name: "count_reg[0]/C", isPort: false)))
        XCTAssertFalse(clk.endpoints.contains { $0.name.hasPrefix("u_tick/count_reg") }, "pins inside u_tick are on its own net")
    }

    func testNetsInsideASubModuleAreItsOwn() throws {
        let rtl = try snapshot(.rtl)
        let inner = rtl.nets(in: "u_tick")
        XCTAssertFalse(inner.isEmpty)
        XCTAssertTrue(inner.allSatisfy { $0.name.hasPrefix("u_tick/") })
        let clk = try XCTUnwrap(inner.first { $0.localName == "clk" })
        XCTAssertTrue(clk.endpoints.contains(NetEndpoint(name: "u_tick/count_reg[0]/C", isPort: false)))
        XCTAssertTrue(clk.endpoints.contains(NetEndpoint(name: "u_tick/clk", isPort: false)), "the boundary pin seen from inside")
        XCTAssertFalse(rtl.nets(in: "").contains { $0.name.hasPrefix("u_tick/") })
    }

    func testNetTypesAndBuses() throws {
        let synth = try snapshot(.synth)
        XCTAssertEqual(Set(synth.nets.map(\.type)), ["GLOBAL_CLOCK", "GROUND", "POWER", "SIGNAL"])
        XCTAssertTrue(synth.nets.contains { $0.type == "GLOBAL_CLOCK" && $0.name == "clk_IBUF_BUFG" }, "after synthesis the clock goes through a BUFG")
        XCTAssertEqual(DesignNet(name: "u/count[3]", type: "SIGNAL").busName, "count")
        XCTAssertEqual(DesignNet(name: "count0_i__0_n_0", type: "SIGNAL").busName, "count0_i__0_n_0")
        XCTAssertEqual(DesignNet(name: "x[a]", type: "SIGNAL").busName, "x[a]", "only numeric indexes make a bus")
    }

    // MARK: Pins

    func testPinsHaveDirectionAndClockFlag() throws {
        let synth = try snapshot(.synth)
        let pins = synth.pins(of: "count_reg[0]")
        XCTAssertEqual(pins.map(\.pinName), ["C", "CE", "D", "Q", "R"])
        XCTAssertEqual(pins.first { $0.pinName == "C" }?.isClock, true)
        XCTAssertEqual(pins.first { $0.pinName == "Q" }?.direction, "OUT")
        XCTAssertEqual(pins.first { $0.pinName == "D" }?.isClock, false)
    }

    func testBusPinsSortNaturally() throws {
        let rtl = try snapshot(.rtl)
        let outs = rtl.pins(of: "count0_i__0").filter { $0.busName == "O" }.map(\.pinName)
        XCTAssertEqual(outs.prefix(3), ["O[0]", "O[1]", "O[2]"])
        XCTAssertEqual(outs.count, 8)
        XCTAssertEqual(DesignPin(name: "a/b/O[10]", direction: "OUT").cellName, "a/b")
    }

    // MARK: Properties

    func testEveryCellNetAndPortHasItsProperties() throws {
        let impl = try snapshot(.impl)
        let reg = impl.properties(of: .cell, name: "count_reg[0]")
        func value(_ name: String, _ list: [DesignProperty]) -> String? { list.first { $0.name == name }?.value }
        XCTAssertEqual(value("REF_NAME", reg), "FDRE")
        XCTAssertEqual(value("LOC", reg), "SLICE_X1Y14", "placement is there after implementation")
        XCTAssertEqual(value("BEL", reg), "SLICEL.AFF")
        XCTAssertEqual(value("IS_BEL_FIXED", reg), "0", "a boolean that is 0 is still a value")
        XCTAssertEqual(reg.map(\.name), reg.map(\.name).sorted(), "sorted, as the Properties window lists them")

        let port = impl.properties(of: .port, name: "led[0]")
        XCTAssertEqual(value("DIRECTION", port), "OUT")
        XCTAssertEqual(value("BUS_NAME", port), "led")
        XCTAssertFalse(impl.properties(of: .net, name: "clk_IBUF_BUFG").isEmpty)
        XCTAssertTrue(impl.properties(of: .cell, name: "no such cell").isEmpty)
    }

    func testValuesWithSpacesStayWhole() throws {
        let rtl = try snapshot(.rtl)
        XCTAssertEqual(rtl.properties(of: .cell, name: "count0_i").first { $0.name == "TYPE" }?.value, "RTL Gate")
    }

    func testRoutingAndOtherSkippedPropertiesAreNotSaved() throws {
        for stage in DesignStage.allCases {
            let s = try snapshot(stage)
            let names = Set(s.propertyTable.values.flatMap { $0.map(\.name) })
            for skipped in DesignDump.skippedProperties { XCTAssertFalse(names.contains(skipped), "\(stage) \(skipped)") }
        }
    }

    // MARK: Older builds and huge designs

    func testABuildWithoutTheNewFilesStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a\tFDRE\t1\n".write(to: dir.appendingPathComponent("synth_cells.tsv"), atomically: true, encoding: .utf8)
        let s = try DesignSnapshot.load(stage: .synth, from: dir)
        XCTAssertEqual(s.cells, [DesignCell(name: "a", type: "FDRE", isPrimitive: true)])
        XCTAssertFalse(s.hasConnectivity)
        XCTAssertTrue(s.pins.isEmpty)
        XCTAssertTrue(s.propertyTable.isEmpty)
    }

    func testWhatAHugeDesignLeftOutIsRecorded() {
        XCTAssertEqual(DesignSnapshot.parseInfo("left_out\tconnectivity,properties\n").leftOut, ["connectivity", "properties"])
        XCTAssertEqual(DesignSnapshot.parseInfo("left_out\t\n").leftOut, [])
    }

    // MARK: The Tcl

    func testTheDumpWritesEveryNewFileAndNeverFailsTheBuild() {
        let tcl = DesignDump.procedures
        for kind in ["pins", "conn", "props", "cells", "ports", "info"] {
            XCTAssertTrue(tcl.contains("\"out/${stage}_\(kind).tsv\""), kind)
        }
        XCTAssertEqual(DesignDump.pinsFile("synth"), "synth_pins.tsv")
        XCTAssertEqual(DesignDump.connectionsFile("synth"), "synth_conn.tsv")
        XCTAssertEqual(DesignDump.propertiesFile("synth"), "synth_props.tsv")
        XCTAssertTrue(tcl.contains("<= \(DesignDump.maxConnectivityCells)"))
        XCTAssertTrue(tcl.contains("<= \(DesignDump.maxPropertyObjects)"))
        XCTAssertTrue(tcl.contains("fpgabridge_relative"), "source paths are made relative to the project")
        XCTAssertEqual(tcl.components(separatedBy: "-translation lf").count - 1, 6, "every file has plain line endings")
    }
}
