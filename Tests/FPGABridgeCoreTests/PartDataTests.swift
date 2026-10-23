import XCTest
@testable import FPGABridgeCore

final class PartDataTests: XCTestCase {
    /// What Vivado 2025.2 printed for `PartData.dumpScript(part: "xc7a35tcpg236-1")`, with Vivado's own messages around
    /// it and Windows' CR LF line endings. Only the tiles in the bottom 21 rows, and those holding I/O and global clock
    /// buffers, are kept (the full list is 4,535 tiles); everything else is complete.
    static func basys3() throws -> PartData {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "part_xc7a35tcpg236-1_vivado2025", withExtension: "txt", subdirectory: "Fixtures"))
        return PartData.parse(output: try String(contentsOf: url, encoding: .utf8), part: "xc7a35tcpg236-1")
    }

    /// The same for xc7a100tcsg324-1 (Arty A7-100, Nexys A7), the biggest part the boards use, without its tiles.
    static func arty100() throws -> PartData {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "part_xc7a100tcsg324-1_vivado2025", withExtension: "txt", subdirectory: "Fixtures"))
        return PartData.parse(output: try String(contentsOf: url, encoding: .utf8))
    }

    func testThePartAndItsStandardsParse() throws {
        let data = try Self.basys3()
        XCTAssertEqual(data.vivado, "2025.2")
        XCTAssertEqual([data.part, data.device, data.package, data.family, data.speed], ["xc7a35tcpg236-1", "xc7a35t", "cpg236", "Artix-7", "-1"])
        XCTAssertEqual(data.standards.count, 37)
        let lvcmos33 = try XCTUnwrap(data.standard(named: "LVCMOS33"))
        XCTAssertEqual(lvcmos33.vccoIn, 3.3)
        XCTAssertEqual(lvcmos33.vccoOut, 3.3)
        XCTAssertFalse(lvcmos33.isDifferential)
        XCTAssertEqual(lvcmos33.directions, ["INPUT", "OUTPUT", "BIDIR"])
        XCTAssertEqual(lvcmos33.driveStrengths, ["12", "4", "8", "16"])
        let hsul = try XCTUnwrap(data.standard(named: "HSUL_12"))
        XCTAssertNil(hsul.vcco(direction: "IN"), "a VREF input doesn't need a particular VCCO")
        XCTAssertEqual(hsul.vcco(direction: "OUT"), 1.2)
        XCTAssertTrue(hsul.hasVREF)
        XCTAssertEqual(hsul.vref, 0.6)
        XCTAssertTrue(hsul.driveStrengths.isEmpty, "Vivado says NA")
        XCTAssertTrue(try XCTUnwrap(data.standard(named: "LVDS_25")).isDifferential)
    }

    func testBanks() throws {
        let data = try Self.basys3()
        XCTAssertEqual(data.banks.map(\.name), ["0", "14", "16", "34", "35", "216"])
        XCTAssertEqual(data.bank(named: "34")?.type, .highRange)
        XCTAssertEqual(data.bank(named: "216")?.type, .transceiver)
        XCTAssertEqual(data.bank(named: "0")?.type, .noUserIO)
        XCTAssertTrue(data.standards(forBank: "34").contains("LVCMOS33"))
        XCTAssertEqual(data.banks.filter(\.hasUserIO).map(\.name), ["14", "16", "34", "35"])
    }

    func testPackagePins() throws {
        let data = try Self.basys3()
        XCTAssertEqual(data.pins.count, 238)
        XCTAssertEqual(data.rows, ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N", "P", "R", "T", "U", "V", "W"])
        XCTAssertEqual(data.columnCount, 19)
        XCTAssertEqual(data.pins.filter { $0.kind == .userIO }.count, 106, "AVAILABLE_IOBS of the part")

        let clk = try XCTUnwrap(data.pin(named: "W5"))
        XCTAssertEqual(clk.bank, "34")
        XCTAssertEqual(clk.function, "IO_L12P_T1_MRCC_34")
        XCTAssertEqual(clk.diffPair, "W4")
        XCTAssertTrue(clk.isClockCapable)
        XCTAssertTrue(clk.isPositive)
        XCTAssertEqual(clk.site, "IOB_X1Y26")
        XCTAssertEqual([clk.row, String(clk.column)], ["W", "5"])
        XCTAssertEqual(data.pin(named: "w5"), clk, "pin names match without case, as in Vivado")

        XCTAssertEqual(data.pin(named: "V17")?.isVREF, true)
        XCTAssertEqual(data.pin(named: "V17")?.isPositive, false)
        XCTAssertEqual(data.pin(named: "A1")?.kind, .ground)
        XCTAssertEqual(data.pin(named: "C1")?.kind, .power, "MGTAVCC")
        XCTAssertEqual(data.pin(named: "A12")?.kind, .analog, "VP_0, the XADC input")
        XCTAssertEqual(Set(data.pins.map(\.kind)), [.userIO, .ground, .power, .vcco, .config, .transceiver, .analog])
        let vcco = data.pins.filter { $0.kind == .vcco }
        XCTAssertFalse(vcco.isEmpty)
        XCTAssertTrue(vcco.allSatisfy { !$0.bank.isEmpty }, "each VCCO pin belongs to its bank")
    }

    func testTheDie() throws {
        let data = try Self.basys3()
        XCTAssertEqual(data.gridWidth, 115, "COLS of the part")
        XCTAssertEqual(data.gridHeight, 157, "ROWS of the part")
        XCTAssertTrue(data.columns.allSatisfy { $0.height == 157 })
        XCTAssertEqual(data.columns[4].types.first, "B_TERM_INT")
        XCTAssertEqual(data.columns[4].types[1], "INT_L")
        XCTAssertEqual(data.regions.map(\.name), ["X0Y0", "X1Y0", "X0Y1", "X1Y1", "X0Y2", "X1Y2"])
        XCTAssertEqual(data.regions.first, ClockRegion(name: "X0Y0", left: 0, top: 51, right: 58, bottom: 1))

        let sites = data.siteIndex()
        let slice = try XCTUnwrap(sites["SLICE_X0Y0"])
        XCTAssertEqual(slice.site.type, "SLICEL")
        XCTAssertEqual(slice.tile.name, "CLBLL_L_X2Y0")
        XCTAssertNotNil(sites["IOB_X1Y26"], "W5's I/O buffer")
        XCTAssertFalse(data.tiles.contains { $0.sites.contains { $0.type == "TIEOFF" } }, "tie-offs never hold a cell, so they're left out")
    }

    func testTheBiggestSupportedPart() throws {
        let data = try Self.arty100()
        XCTAssertEqual(data.part, "xc7a100tcsg324-1")
        XCTAssertEqual(data.pins.count, 324)
        XCTAssertEqual(data.rows.count, 18)
        XCTAssertEqual(data.columnCount, 18)
        XCTAssertEqual(data.pins.filter { $0.kind == .userIO }.count, 210)
        XCTAssertEqual(data.gridWidth, 148)
        XCTAssertEqual(data.regions.count, 8)
    }

    func testSavingAndLoadingKeepsEverything() throws {
        let data = try Self.basys3()
        XCTAssertEqual(PartData.parse(output: data.serialized), data)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(PartData.cached(part: data.part, in: dir))
        try data.save(in: dir)
        XCTAssertEqual(PartData.cached(part: "xc7a35tcpg236-1", in: dir), data)
        XCTAssertEqual(PartData.cacheURL(part: "XC7A35T/CPG236-1", in: dir).lastPathComponent, "xc7a35t_cpg236-1.txt")
    }

    func testTheScriptAsksForEverythingAndCatchesErrors() {
        let script = PartData.dumpScript(part: "xc7a35tcpg236-1")
        for needed in ["link_design -part {xc7a35tcpg236-1}", "get_io_standards", "get_iobanks", "get_package_pins", "DIFF_PAIR_PIN",
                       "get_tiles", "get_clock_regions", "TOP_LEFT_TILE", "catch"] {
            XCTAssertTrue(script.contains(needed), needed)
        }
        XCTAssertEqual(PartData.error(in: "junk\r\nFPGABRIDGE-PART\tERROR\tERROR: [Vivado 12-1] Part 'xc9' not found\r\n"),
                       "ERROR: [Vivado 12-1] Part 'xc9' not found")
        XCTAssertNil(PartData.error(in: "#     puts \"FPGABRIDGE-PART\\tERROR\\t[fpgabridge_clean $err]\""), "Vivado's echo of the script isn't an error")
    }

    func testAnUnknownPartIsSaidPlainly() {
        // Checked on Vivado 2025.2: without this, an unknown part failed later with "'get_property' expects at least one object".
        let script = PartData.dumpScript(part: "xc7zz99zz")
        XCTAssertTrue(script.contains("if {[llength [get_parts -quiet {xc7zz99zz}]] == 0} { error \(PartData.unknownPartMessage) }"))
        XCTAssertEqual(PartData.error(in: "FPGABRIDGE-PART\tERROR\t\(PartData.unknownPartMessage)\r\n"), PartData.unknownPartMessage)
        XCTAssertTrue(PartDataError.unknownPart("xc7zz99zz").description.contains("no part named xc7zz99zz"))
    }
}
