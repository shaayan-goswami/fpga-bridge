import XCTest
@testable import FPGABridgeCore

final class HDLTemplateTests: XCTestCase {
    let context = HDLTemplate.Context(projectName: "blinky", part: "xc7a35tcpg236-1",
                                      date: Date(timeIntervalSince1970: 1_760_000_000))

    var ports: [PortDefinition] {
        [PortDefinition(name: "clk"),
         PortDefinition(name: "sw", isBus: true, msb: 3, lsb: 0),
         PortDefinition(name: "", direction: .output),               // blank: not written
         PortDefinition(name: "led", direction: .output, isBus: true, msb: 7, lsb: 0),
         PortDefinition(name: "sda", direction: .inout)]
    }

    func testVerilogModuleWithPorts() {
        let text = HDLTemplate.verilog(ModuleDefinition(name: "top", ports: ports), context: context)
        XCTAssertTrue(text.hasPrefix("`timescale 1ns / 1ps\n"))
        XCTAssertTrue(text.contains("// Module Name: top"))
        XCTAssertTrue(text.contains("// Project Name: blinky"))
        XCTAssertTrue(text.contains("// Target Devices: xc7a35tcpg236-1"))
        XCTAssertTrue(text.contains("""
        module top(
            input clk,
            input [3:0] sw,
            output [7:0] led,
            inout sda
            );
        endmodule
        """), text)
    }

    func testVerilogIgnoresMsbLsbUnlessBus() {
        let text = HDLTemplate.verilog(ModuleDefinition(name: "m", ports: [PortDefinition(name: "a", isBus: false, msb: 7, lsb: 0)]),
                                       context: context)
        XCTAssertTrue(text.contains("    input a\n"), text)
        XCTAssertFalse(text.contains("[7:0]"))
    }

    func testVerilogWithoutPortsIsAnEmptyList() {
        let text = HDLTemplate.verilog(ModuleDefinition(name: "blinky_tb"), context: context)
        XCTAssertTrue(text.contains("module blinky_tb(\n\n    );\nendmodule"), text)
    }

    func testVHDLEntityWithPorts() {
        let text = HDLTemplate.vhdl(ModuleDefinition(name: "top", architecture: "rtl", ports: ports), context: context)
        XCTAssertTrue(text.contains("-- Module Name: top - rtl"))
        XCTAssertTrue(text.contains("""
        entity top is
            Port ( clk : in STD_LOGIC;
                   sw : in STD_LOGIC_VECTOR (3 downto 0);
                   led : out STD_LOGIC_VECTOR (7 downto 0);
                   sda : inout STD_LOGIC);
        end top;

        architecture rtl of top is
        """), text)
        XCTAssertTrue(text.hasSuffix("end rtl;\n"))
    }

    func testVHDLAscendingRangeUsesTo() {
        let text = HDLTemplate.vhdl(ModuleDefinition(name: "m", ports: [PortDefinition(name: "a", isBus: true, msb: 0, lsb: 3)]),
                                    context: context)
        XCTAssertTrue(text.contains("STD_LOGIC_VECTOR (0 to 3)"), text)
    }

    func testVHDLWithoutPortsHasNoPortClause() {
        let text = HDLTemplate.vhdl(ModuleDefinition(name: "tb"), context: context)
        XCTAssertFalse(text.contains("Port ("))
        XCTAssertTrue(text.contains("entity tb is\nend tb;"), text)
    }

    func testValidation() {
        XCTAssertNoThrow(try ModuleDefinition(name: "top", ports: ports).validate())
        XCTAssertThrowsError(try ModuleDefinition(name: "2top").validate()) {
            XCTAssertEqual($0 as? ModuleDefinitionError, .invalidModuleName("2top"))
        }
        XCTAssertThrowsError(try ModuleDefinition(name: "top", architecture: "a b").validate())
        XCTAssertThrowsError(try ModuleDefinition(name: "top", ports: [PortDefinition(name: "my port")]).validate()) {
            XCTAssertEqual($0 as? ModuleDefinitionError, .invalidPortName("my port"))
        }
        XCTAssertThrowsError(try ModuleDefinition(name: "top", ports: [PortDefinition(name: "clk"), PortDefinition(name: "CLK")]).validate()) {
            XCTAssertEqual($0 as? ModuleDefinitionError, .duplicatePort("CLK"))
        }
        XCTAssertNoThrow(try ModuleDefinition(name: "top", ports: [PortDefinition(name: ""), PortDefinition(name: " ")]).validate(),
                         "blank ports are skipped, not rejected")
    }

    func testCreateFileWritesTheDefinedModuleAndItBecomesTop() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hdl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var request = NewProjectRequest(name: "p", location: work, part: "xc7a35tcpg236-1")
        request.newFiles = [
            NewFile(set: .design, name: "top_file", module: ModuleDefinition(name: "chip_top", ports: ports)),
            NewFile(set: .simulation, name: "tb", module: ModuleDefinition(name: "tb")),
        ]
        let dir = try ProjectCreator.create(request)
        let text = try String(contentsOf: dir.appendingPathComponent("p.srcs/sources_1/new/top_file.v"), encoding: .utf8)
        XCTAssertTrue(text.contains("module chip_top("), "the module name can differ from the file name")
        XCTAssertTrue(text.contains("// Target Devices: xc7a35tcpg236-1"))
        XCTAssertEqual(try Project.load(from: dir).top, "chip_top")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("p.srcs/sim_1/new/tb.v").path))
    }

    func testInvalidModuleStopsCreateBeforeAnythingIsWritten() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hdl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var request = NewProjectRequest(name: "p", location: work, part: "x")
        request.newFiles = [NewFile(set: .design, name: "top", module: ModuleDefinition(name: "top", ports: [PortDefinition(name: "1bad")]))]
        XCTAssertThrowsError(try ProjectCreator.create(request))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("p").path))
    }

    func testSystemVerilogFileUsesTheVerilogLayout() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hdl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var request = NewProjectRequest(name: "p", location: work, part: "x")
        request.newFiles = [NewFile(set: .design, name: "core.sv", module: ModuleDefinition(name: "core"))]
        let dir = try ProjectCreator.create(request)
        let text = try String(contentsOf: dir.appendingPathComponent("p.srcs/sources_1/new/core.sv"), encoding: .utf8)
        XCTAssertTrue(text.contains("module core("))
    }
}
