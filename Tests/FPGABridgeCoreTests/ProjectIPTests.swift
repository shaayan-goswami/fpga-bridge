import XCTest
@testable import FPGABridgeCore

final class ProjectIPTests: XCTestCase {
    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"), name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    let counter = ProjectIP(name: "cnt8", vlnv: "xilinx.com:ip:c_counter_binary:12.0", config: ["CONFIG.Output_Width": "8", "CONFIG.CE": "true"])

    // MARK: The project's IP and the script

    func testTheScriptRecreatesEachIPBeforeTheDesignReadsAnything() {
        let p = Project(name: "p", top: "top", part: "xc7a35tcpg236-1", sources: ["src"], constraints: [], ips: [counter])
        let lines = p.buildScript(sources: ["src/top.v"], constraints: ["pins.xdc"]).split(separator: "\n").map(String.init)
        let ip = ["set_part xc7a35tcpg236-1", "file mkdir ip",
                  "create_ip -name c_counter_binary -vendor xilinx.com -library ip -version 12.0 -module_name cnt8 -dir ip",
                  "set_property -dict [list CONFIG.CE {true} CONFIG.Output_Width {8}] [get_ips cnt8]",
                  "generate_target all [get_ips cnt8]", "synth_ip [get_ips cnt8]"]
        let start = try? XCTUnwrap(lines.firstIndex(of: ip[0]))
        XCTAssertEqual(Array(lines[(start ?? 0)..<((start ?? 0) + ip.count)]), ip, "settings are sorted, so the script is the same every time")
        func at(_ prefix: String) -> Int { lines.firstIndex { $0.hasPrefix(prefix) }! }
        XCTAssertTrue(at("synth_ip") < at("read_verilog") && at("read_verilog") < at("synth_design -rtl"), "IP is built before the design reads it")
    }

    func testAProjectWithoutIPHasNoIPLines() {
        let p = Project(name: "p", top: "top", part: "x", sources: ["a"], constraints: [])
        let script = p.buildScript(sources: ["a.v"], constraints: [])
        for word in ["set_part", "create_ip", "synth_ip", "generate_target"] { XCTAssertFalse(script.contains(word), word) }
    }

    func testSeveralIPAreBuiltInOrderAndAnIPWithNoSettingsHasNoSetPropertyLine() {
        let fifo = ProjectIP(name: "fifo0", vlnv: "xilinx.com:ip:fifo_generator:13.2")
        let p = Project(name: "p", top: "top", part: "x", sources: ["a"], constraints: [], ips: [counter, fifo])
        let lines = p.buildScript(sources: ["a.v"], constraints: []).split(separator: "\n").map(String.init)
        let creates = lines.filter { $0.hasPrefix("create_ip") }
        XCTAssertEqual(creates.count, 2)
        XCTAssertTrue(creates[0].contains("cnt8") && creates[1].contains("fifo0"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("set_property -dict") }.count, 1, "only the counter has settings")
    }

    func testIPRoundTripsThroughTheProjectFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Project(name: "p", top: "t", part: "x", sources: ["a"], constraints: [], ips: [counter]).save(to: dir)
        XCTAssertEqual(try Project.load(from: dir).ips, [counter])
        let old = #"{"name":"p","top":"t","part":"x","sources":["a"],"constraints":[]}"#
        XCTAssertNil(try JSONDecoder().decode(Project.self, from: Data(old.utf8)).ips, "older project files still load")
    }

    // MARK: Validation: everything here reaches a Tcl script

    func testGoodIPAreAccepted() {
        XCTAssertNoThrow(try counter.validate())
        XCTAssertNoThrow(try ProjectIP(name: "u_fifo_2", vlnv: "xilinx.com:ip:fifo_generator:13.2", config: ["CONFIG.Input_Data_Width": "32", "CONFIG.Fifo_Implementation": "Common_Clock_Block_RAM", "CONFIG.X": "a b"]).validate())
    }

    func testBadNamesAreRefused() {
        for bad in ["", "1abc", "has space", "a-b", "a;b", "wire", "module", "entity", "x[0]", "a.b"] {
            XCTAssertThrowsError(try ProjectIP(name: bad, vlnv: counter.vlnv).validate(), bad.debugDescription)
        }
    }

    func testBadVLNVsAreRefused() {
        for bad in ["", "a:b:c", "a:b:c:d:e", "xilinx.com:ip:c counter:12.0", "xilinx.com:ip:x;y:1.0", "a:b:{c}:1.0", "a:b:c:$d"] {
            XCTAssertThrowsError(try ProjectIP(name: "ok", vlnv: bad).validate(), bad)
        }
    }

    func testTclSyntaxInSettingsIsRefused() {
        for bad in ["[exec rm -rf /]", "a}b", "{x", "$env(HOME)", "a;b", "\"q\"", "a\nb", "`x`", "a\\b"] {
            XCTAssertThrowsError(try ProjectIP(name: "ok", vlnv: counter.vlnv, config: ["CONFIG.A": bad]).validate(), "value \(bad.debugDescription)")
        }
        for badKey in ["Output_Width", "CONFIG.", "CONFIG.a b", "CONFIG.x}", "config.A", "CONFIG.A;B", "CONFIG.Component_Name"] {
            XCTAssertThrowsError(try ProjectIP(name: "ok", vlnv: counter.vlnv, config: [badKey: "1"]).validate(), "key \(badKey)")
        }
    }

    func testAProjectRefusesDuplicateAndInvalidIP() {
        func project(_ ips: [ProjectIP]) -> Project { Project(name: "p", top: "t", part: "x", sources: ["a"], constraints: [], ips: ips) }
        XCTAssertNoThrow(try project([counter]).validate())
        XCTAssertThrowsError(try project([counter, counter]).validate()) { XCTAssertTrue($0.userMessage.contains("both named")) }
        XCTAssertThrowsError(try project([ProjectIP(name: "bad name", vlnv: counter.vlnv)]).validate())
    }

    // MARK: Scripts

    func testThePropertiesScriptCreatesTheIPInAScratchFolderAndCleansUp() {
        let tcl = IPScripts.propertiesScript(vlnv: counter.vlnv, part: "xc7a35tcpg236-1", token: "abcd1234")
        XCTAssertTrue(tcl.hasPrefix("set_part {xc7a35tcpg236-1}\nfile mkdir ipwork_abcd1234\n"))
        XCTAssertTrue(tcl.contains("create_ip -name c_counter_binary -vendor xilinx.com -library ip -version 12.0 -module_name fpgabridge_probe -dir ipwork_abcd1234"))
        XCTAssertTrue(tcl.contains("list_property [get_ips fpgabridge_probe] CONFIG.*"))
        XCTAssertTrue(tcl.contains("catch { file delete -force ipwork_abcd1234 }"), "always cleaned up")
        XCTAssertTrue(tcl.contains("catch {"), "a failure is reported, not fatal")
    }

    func testTheTemplateScriptAppliesTheSettingsBeforeGenerating() {
        let tcl = IPScripts.templateScript(ip: counter, part: "x", token: "abcd1234")
        let set = tcl.range(of: "set_property -dict [list CONFIG.CE {true} CONFIG.Output_Width {8}] [get_ips cnt8]")
        let generate = tcl.range(of: "generate_target {instantiation_template} [get_ips cnt8]")
        XCTAssertNotNil(set)
        XCTAssertNotNil(generate)
        XCTAssertTrue(set!.lowerBound < generate!.lowerBound)
        XCTAssertTrue(tcl.contains("ipwork_abcd1234/cnt8/cnt8.$ext"))
    }

    // MARK: Parsing real output

    func testTheRealPropertyListParses() throws {
        let parsed = IPScripts.parse(output: try fixture("ip_properties_vivado2025"))
        XCTAssertNil(parsed.error)
        XCTAssertEqual(parsed.properties.count, 25, "26 settings, less the instance name")
        XCTAssertFalse(parsed.properties.contains { $0.name == "CONFIG.Component_Name" })
        let width = try XCTUnwrap(parsed.properties.first { $0.name == "CONFIG.Output_Width" })
        XCTAssertEqual(width.value, "16")
        XCTAssertEqual(width.title, "Output_Width")
        XCTAssertTrue(try XCTUnwrap(parsed.properties.first { $0.name == "CONFIG.CE" }).isBoolean)
        XCTAssertFalse(width.isBoolean)
        XCTAssertEqual(parsed.properties.map(\.name), parsed.properties.map(\.name).sorted(), "sorted by name")
    }

    func testTheRealVerilogTemplateIsCutOutOfItsLicenceText() throws {
        let parsed = IPScripts.parse(output: try fixture("ip_template_vivado2025"))
        XCTAssertGreaterThan(parsed.verilogTemplate.count, 40, "the whole .veo, licence and all")
        XCTAssertEqual(IPScripts.cutSection(of: parsed.verilogTemplate), """
            cnt8 your_instance_name (
              .CLK(CLK),  // input wire CLK
              .Q(Q)      // output wire [7 : 0] Q
            );

            """)
    }

    func testTheRealVHDLTemplateHasTheComponentAndTheInstance() throws {
        let parsed = IPScripts.parse(output: try fixture("ip_template_vivado2025"))
        XCTAssertEqual(IPScripts.cutSection(of: parsed.vhdlTemplate), """
            COMPONENT cnt8
              PORT (
                CLK : IN STD_LOGIC;
                Q : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)\u{20}
              );
            END COMPONENT;

            your_instance_name : cnt8
              PORT MAP (
                CLK => CLK,
                Q => Q
              );

            """)
    }

    func testAScriptErrorIsReportedInVivadosWords() {
        let parsed = IPScripts.parse(output: "INFO: x\nFPGABRIDGE-IP\tERROR\tERROR: [Common 17-69] Command failed: value 'foo' is not valid\nFPGABRIDGE-IP\tCFG\tCONFIG.A\t1\n")
        XCTAssertEqual(parsed.error, "ERROR: [Common 17-69] Command failed: value 'foo' is not valid")
        XCTAssertEqual(parsed.properties.map(\.name), ["CONFIG.A"])
    }

    func testAnEmptyDefaultValueIsKept() {
        let parsed = IPScripts.parse(output: "FPGABRIDGE-IP\tCFG\tCONFIG.Thing\t\n")
        XCTAssertEqual(parsed.properties, [IPProperty(name: "CONFIG.Thing", value: "")])
    }

    func testCutSectionOfNothingIsEmpty() {
        XCTAssertEqual(IPScripts.cutSection(of: []), "")
        XCTAssertEqual(IPScripts.cutSection(of: ["// no markers here"]), "")
    }

    // MARK: The catalog cache

    func testACatalogSurvivesBeingSavedAndLoaded() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ip_catalog_vivado2025", withExtension: "txt", subdirectory: "Fixtures"))
        let original = IPCatalog.parse(output: try String(contentsOf: url, encoding: .utf8), part: "xc7a35tcpg236-1")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString)/catalog.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try original.save(to: file)
        let loaded = try XCTUnwrap(IPCatalog.load(from: file))
        XCTAssertEqual(loaded.definitions, original.definitions)
        XCTAssertEqual(loaded.vivado, original.vivado)
    }

    func testNoCacheOrAnEmptyOneMeansAskVivado() throws {
        XCTAssertNil(IPCatalog.load(from: URL(fileURLWithPath: "/nonexistent/catalog.txt")))
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).txt")
        try "nothing useful\n".write(to: empty, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(IPCatalog.load(from: empty))
    }

    func testTheCacheIsPerBuildMachineAndPart() {
        let a = IPCatalog.cacheURL(host: "pc.tailnet.ts.net", part: "xc7a35tcpg236-1")
        let b = IPCatalog.cacheURL(host: "pc.tailnet.ts.net", part: "xc7a100tcsg324-1")
        let c = IPCatalog.cacheURL(host: "other", part: "xc7a35tcpg236-1")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        XCTAssertTrue(a.path.contains("/Library/Caches/fpga-bridge/"))
        XCTAssertFalse(a.lastPathComponent.contains("/") || a.lastPathComponent.contains(" "))
    }
}
