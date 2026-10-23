import XCTest
@testable import FPGABridgeCore

final class DesignDataTests: XCTestCase {
    /// What Vivado 2025.2 wrote for the demo_top design on a Basys 3 (see Fixtures/design_vivado2025). The build now
    /// writes plain line endings; older builds wrote CR LF, which the inline tests below still cover.
    var fixtureDirectory: URL {
        get throws {
            try XCTUnwrap(Bundle.module.url(forResource: "design_vivado2025", withExtension: nil, subdirectory: "Fixtures"))
        }
    }

    func snapshot(_ stage: DesignStage) throws -> DesignSnapshot { try DesignSnapshot.load(stage: stage, from: fixtureDirectory) }

    // MARK: Real data

    func testTheSynthesizedDesignFromRealVivado() throws {
        let s = try snapshot(.synth)
        XCTAssertEqual(s.info, DesignInfo(stage: "synth", design: "design_1", part: "xc7a35tcpg236-1", top: "demo_top", vivado: "2025.2", leftOut: []))
        XCTAssertEqual(s.cells.count, 124)
        XCTAssertEqual(s.ports.count, 34)
        XCTAssertEqual(s.root.name, "demo_top")
        XCTAssertTrue(s.root.isTop)
        XCTAssertEqual(s.root.children?.map(\.id), ["u_tick"])
        XCTAssertEqual(s.root.children?.first?.type, "tick_gen")
    }

    func testEveryPrimitiveIsInExactlyOneModule() throws {
        let s = try snapshot(.synth)
        let inModules = s.modules.reduce(0) { $0 + $1.primitives.count }
        XCTAssertEqual(inModules, s.cells.filter(\.isPrimitive).count)
        XCTAssertEqual(s.root.totals.total, inModules, "the top's totals include everything below it")
        let tick = try XCTUnwrap(s.module(withPath: "u_tick"))
        XCTAssertTrue(tick.primitives.allSatisfy { $0.name.hasPrefix("u_tick/") && $0.parentPath == "u_tick" })
        XCTAssertEqual(s.root.counts.total + tick.counts.total, s.root.totals.total)
        XCTAssertFalse(s.root.primitives.contains { $0.name.hasPrefix("u_tick/") }, "the top holds only its own primitives")
    }

    func testTheCountsAreCellCountsNotVivadosSiteCounts() throws {
        // Vivado's utilization report for this build says 26 LUTs and 48 flip-flops. It counts physical sites and notes
        // "LUT value is adjusted to account for LUT combining": two small LUTs can share one site. The netlist has 36
        // LUT cells, so the app's per-module numbers are cell counts and the view labels them that way.
        let t = try snapshot(.impl).root.totals
        XCTAssertEqual(t.lut, 36, "LUT1 to LUT6 cells")
        XCTAssertGreaterThan(t.lut, 26, "more cells than the 26 sites Vivado reports")
        XCTAssertEqual(t.flipFlop, 48, "flip-flops don't combine, so this matches Vivado's report exactly")
        XCTAssertEqual(t.carry, 6)
        XCTAssertEqual(t.io, 28, "12 input and 16 output buffers")
        XCTAssertEqual(t.blockRAM + t.dsp, 0)
    }

    func testTheElaboratedDesignHasRTLOperationsNotPrimitives() throws {
        let s = try snapshot(.rtl)
        XCTAssertEqual(s.info.stage, "rtl")
        XCTAssertEqual(s.cells.count, 84)
        XCTAssertEqual(s.module(withPath: "u_tick")?.type, "tick_gen")
        XCTAssertTrue(s.typeCounts.contains { $0.type.hasPrefix("RTL_") }, "\(s.typeCounts.prefix(4))")
        XCTAssertEqual(s.root.totals.lut, 0, "no LUTs before synthesis")
    }

    func testThePortsHaveTheirPinsAndStandards() throws {
        let s = try snapshot(.impl)
        let led0 = try XCTUnwrap(s.ports.first { $0.name == "led[0]" })
        XCTAssertEqual([led0.direction, led0.packagePin, led0.ioStandard, led0.slew, led0.drive], ["OUT", "U16", "LVCMOS33", "SLOW", "12"])
        let clk = try XCTUnwrap(s.ports.first { $0.name == "clk" })
        XCTAssertEqual([clk.direction, clk.packagePin, clk.ioStandard], ["IN", "W5", "LVCMOS33"])
        XCTAssertEqual(clk.slew, "", "inputs have no slew: an empty field stays a field, not a shifted column")
        XCTAssertEqual(clk.drive, "")
        XCTAssertTrue(s.ports.allSatisfy(\.isPlaced), "every port has a pin")
    }

    func testBusesAreGroupedInTheOrderTheyAppear() throws {
        let buses = try snapshot(.impl).portBuses
        XCTAssertEqual(buses.map(\.name), ["btnC", "clk", "led", "sw"])
        XCTAssertEqual(buses.first { $0.name == "led" }?.ports.count, 16)
        XCTAssertEqual(buses.first { $0.name == "sw" }?.ports.count, 16)
        XCTAssertEqual(DesignPort(name: "led[3]", direction: "", packagePin: "", ioStandard: "", slew: "", drive: "", pullType: "").busName, "led")
        XCTAssertEqual(DesignPort(name: "clk", direction: "", packagePin: "", ioStandard: "", slew: "", drive: "", pullType: "").busName, "clk")
    }

    func testTypeCountsAreMostCommonFirst() throws {
        let counts = try snapshot(.impl).typeCounts
        XCTAssertEqual(counts.first?.type, "FDRE")
        XCTAssertEqual(counts.first?.count, 47)
        XCTAssertEqual(counts.map(\.count), counts.map(\.count).sorted(by: >))
        XCTAssertEqual(counts.reduce(0) { $0 + $1.count }, 124 - 1, "every primitive except the one module instance")
    }

    // MARK: Parsing

    func testWindowsAndUnixLineEndingsReadTheSame() throws {
        let crlf = "a/b\tLUT6\t1\r\nu\tmod\t0\r\n"
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(DesignSnapshot.parseCells(crlf), DesignSnapshot.parseCells(lf))
        XCTAssertEqual(DesignSnapshot.parseCells(lf), [DesignCell(name: "a/b", type: "LUT6", isPrimitive: true),
                                                       DesignCell(name: "u", type: "mod", isPrimitive: false)])
        XCTAssertEqual(DesignSnapshot.parseInfo("top\tx\r\nvivado\t2025.2\r\n").top, "x")
    }

    func testBlankLinesAndShortLinesAreSkipped() {
        XCTAssertEqual(DesignSnapshot.parseCells("\n\nonlyone\nname\ttype\n\nok\tFDRE\t1\n").map(\.name), ["ok"])
        XCTAssertEqual(DesignSnapshot.parsePorts("clk\tIN\n\n").first?.packagePin, "", "a short port line still parses")
    }

    func testNestedModulesFormATree() {
        let cells = [
            DesignCell(name: "a", type: "ma", isPrimitive: false),
            DesignCell(name: "a/b", type: "mb", isPrimitive: false),
            DesignCell(name: "a/b/c", type: "mc", isPrimitive: false),
            DesignCell(name: "a/b/c/ff", type: "FDRE", isPrimitive: true),
            DesignCell(name: "a/b/lut", type: "LUT3", isPrimitive: true),
            DesignCell(name: "a/other", type: "mo", isPrimitive: false),
            DesignCell(name: "topff", type: "FDCE", isPrimitive: true),
            DesignCell(name: "ram", type: "RAMB36E1", isPrimitive: true),
        ]
        let root = DesignSnapshot.buildHierarchy(top: "chip", cells: cells)
        XCTAssertEqual(root.name, "chip")
        XCTAssertEqual(root.children?.map(\.id), ["a"])
        let a = root.children![0]
        XCTAssertEqual(a.children?.map(\.id), ["a/b", "a/other"])
        XCTAssertNil(a.children?[1].children, "a leaf module has nil children")
        let b = a.children![0]
        XCTAssertEqual(b.name, "b")
        XCTAssertEqual(b.counts.lut, 1)
        XCTAssertEqual(b.totals.lut, 1)
        XCTAssertEqual(b.totals.flipFlop, 1, "the flip-flop in c counts toward b")
        XCTAssertEqual(b.children?.first?.primitives.map(\.localName), ["ff"])
        XCTAssertEqual(root.totals.flipFlop, 2)
        XCTAssertEqual(root.totals.blockRAM, 1)
        XCTAssertEqual(root.counts.total, 2, "only topff and ram are directly in the top")
    }

    func testPrimitivesAreFiledByTheirType() {
        func kind(_ t: String) -> ResourceCounts { var c = ResourceCounts(); c.add(type: t); return c }
        XCTAssertEqual(kind("LUT6").lut, 1)
        XCTAssertEqual(kind("LUT1").lut, 1)
        XCTAssertEqual(kind("FDRE").flipFlop, 1)
        XCTAssertEqual(kind("FDCE").flipFlop, 1)
        XCTAssertEqual(kind("LDCE").flipFlop, 1)
        XCTAssertEqual(kind("RAMB36E1").blockRAM, 1)
        XCTAssertEqual(kind("RAMB18E1").blockRAM, 1)
        XCTAssertEqual(kind("DSP48E1").dsp, 1)
        XCTAssertEqual(kind("CARRY4").carry, 1)
        XCTAssertEqual(kind("IBUF").io, 1)
        XCTAssertEqual(kind("OBUF").io, 1)
        XCTAssertEqual(kind("IOBUF").io, 1)
        XCTAssertEqual(kind("BUFG").other, 1)
        XCTAssertEqual(kind("GND").other, 1)
        XCTAssertEqual(kind("RTL_ADD").other, 1)
        XCTAssertEqual(kind("LUTRAM").lut, 0, "LUT-prefixed but not a LUT cell")
    }

    // MARK: Missing data

    func testWithoutDataThereIsAClearError() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("dd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertFalse(DesignSnapshot.isAvailable(.synth, in: empty))
        XCTAssertThrowsError(try DesignSnapshot.load(stage: .synth, from: empty)) { error in
            XCTAssertTrue(error.userMessage.contains("Synthesized Design") && error.userMessage.contains("build"), error.userMessage)
        }
        XCTAssertTrue(DesignSnapshot.isAvailable(.synth, in: try fixtureDirectory))
    }

    func testStageTitlesAreVivadosNames() {
        XCTAssertEqual(DesignStage.allCases.map(\.title), ["Elaborated Design", "Synthesized Design", "Implemented Design"])
    }

    // MARK: The Tcl that writes the data

    func testTheScriptWritesEveryFileTheLoaderReads() {
        let tcl = DesignDump.procedures
        for stage in DesignStage.allCases {
            XCTAssertTrue(tcl.contains("\"out/${stage}_cells.tsv\""), "cells file")
            XCTAssertEqual(DesignDump.cellsFile(stage.rawValue), "\(stage.rawValue)_cells.tsv")
            XCTAssertEqual(DesignDump.portsFile(stage.rawValue), "\(stage.rawValue)_ports.tsv")
            XCTAssertEqual(DesignDump.infoFile(stage.rawValue), "\(stage.rawValue)_info.tsv")
        }
        XCTAssertTrue(tcl.contains("-translation lf"), "plain line endings, even from Windows")
        XCTAssertTrue(tcl.contains("catch"), "a failure here must never fail the build")
    }

    func testTheBuildScriptDumpsAtThreeStagesInOrder() {
        let p = Project(name: "p", top: "top", part: "x", sources: ["a"], constraints: [])
        let lines = p.buildScript(sources: ["a.v"], constraints: []).split(separator: "\n").map(String.init)
        func index(_ prefix: String) -> Int { lines.firstIndex { $0.hasPrefix(prefix) }! }
        let order = ["synth_design -rtl", "fpgabridge_dump rtl", "close_design", "synth_design -top", "fpgabridge_dump synth",
                     "opt_design", "place_design", "route_design", "report_utilization -file out/utilization.rpt",
                     "fpgabridge_dump impl", "write_bitstream"]
        XCTAssertEqual(order.map(index), order.map(index).sorted(), "stages happen in this order")
        XCTAssertTrue(lines.contains("synth_design -top top -part x"), "the real synthesis line is unchanged")
    }

    func testDesignDataCanBeTurnedOffAndTheOldScriptComesBack() {
        var settings = ProjectSettings()
        settings.collectDesignData = false
        let p = Project(name: "p", top: "top", part: "x", sources: ["a"], constraints: [], settings: settings)
        XCTAssertEqual(p.buildScript(sources: ["a.v"], constraints: []).replacingOccurrences(of: p.runProcedures + "\n", with: ""), """
            # Generated by fpga-bridge. Overwritten on every build.
            file mkdir out
            fpgabridge_begin synth_1 impl_1
            read_verilog {a.v}
            synth_design -top top -part x
            fpgabridge_checkpoint synth_1 post_synth
            opt_design
            place_design
            route_design
            fpgabridge_checkpoint impl_1 post_route
            report_timing_summary -file out/timing_summary.rpt
            report_utilization -file out/utilization.rpt
            write_bitstream -force out/top.bit
            fpgabridge_done synth_1 impl_1 write_bitstream

            """)
        XCTAssertFalse(settings.isDefault)
    }

    func testLanguageOptionsReachTheElaborationPassToo() {
        var settings = ProjectSettings()
        settings.language.defines = ["FAST"]
        settings.synthesis.retiming = true
        let lines = Project(name: "p", top: "top", part: "x", sources: ["a"], constraints: [], settings: settings)
            .buildScript(sources: [], constraints: []).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("synth_design -rtl -name rtl_1 -top top -part x -verilog_define FAST"), "macros apply to RTL elaboration, synthesis-only options don't")
        XCTAssertTrue(lines.contains("synth_design -top top -part x -retiming -verilog_define FAST"))
    }
}
