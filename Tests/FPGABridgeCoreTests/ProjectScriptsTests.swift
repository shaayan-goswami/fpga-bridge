import XCTest
@testable import FPGABridgeCore

final class ProjectScriptsTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-bridge-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("inputs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func makeProject() throws -> URL {
        func input(_ name: String, _ text: String) throws -> URL {
            let url = tmp.appendingPathComponent("inputs/\(name)")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        var request = NewProjectRequest(name: "blinky", location: tmp, part: "xc7a35tcpg236-1", board: "basys3")
        request.designSources = [try input("blinky.v", "`include \"defs.vh\"\nmodule blinky(input clk); endmodule\n"),
                                 try input("defs.vh", "`define W 4\n"), try input("old $[x].sv", "module old; endmodule\n")]
        request.constraints = [try input("basys3.xdc", "")]
        request.simulationSources = [try input("blinky_tb.v", "module blinky_tb; blinky dut(.clk()); endmodule\n")]
        return try ProjectCreator.create(request)
    }

    func testProjectModeScriptRecreatesTheProject() throws {
        let dir = try makeProject()
        var project = try Project.load(from: dir)
        project.simulationTop = "blinky_tb"
        project.disabled = ["blinky.srcs/sources_1/imports/old $[x].sv"]
        try project.save(to: dir)
        let script = try ProjectScripts.projectModeScript(project: project, root: dir)

        XCTAssertTrue(script.contains("set origin_dir [file dirname [file normalize [info script]]]"))
        XCTAssertTrue(script.contains("create_project blinky $proj_dir -part xc7a35tcpg236-1 -force"))
        XCTAssertTrue(script.contains("set proj_dir [file join [file dirname $origin_dir] blinky_vivado]"))
        XCTAssertTrue(script.contains("add_files -norecurse -fileset sources_1 [list \\\n"))
        XCTAssertTrue(script.contains(#"  [file normalize "$origin_dir/blinky.srcs/sources_1/imports/blinky.v"] \"#))
        XCTAssertTrue(script.contains(#"set_property file_type {Verilog Header} [get_files [file normalize "$origin_dir/blinky.srcs/sources_1/imports/defs.vh"]]"#))
        XCTAssertTrue(script.contains(#"[file normalize "$origin_dir/blinky.srcs/sources_1/imports/old \$\[x\].sv"]"#), "Tcl specials are escaped")
        XCTAssertTrue(script.contains(#"set_property is_enabled false [get_files [file normalize "$origin_dir/blinky.srcs/sources_1/imports/old \$\[x\].sv"]]"#))
        XCTAssertTrue(script.contains("add_files -norecurse -fileset constrs_1"))
        XCTAssertTrue(script.contains("add_files -norecurse -fileset sim_1"))
        XCTAssertTrue(script.contains("set_property top blinky [get_filesets sources_1]"))
        XCTAssertTrue(script.contains("set_property top blinky_tb [get_filesets sim_1]"))
        XCTAssertTrue(script.contains("set_property include_dirs [list [file normalize \"$origin_dir/blinky.srcs/sources_1/imports\"]] [get_filesets sources_1]"),
                      "the header's folder is an include folder, as in the build")
        XCTAssertFalse(script.contains("get_runs"), "default settings set nothing on the runs")
        XCTAssertFalse(script.contains("bitstream_settings.xdc"))
        // Every bracket opened is closed: a quick check that the script is well formed.
        XCTAssertEqual(script.filter { $0 == "[" }.count - script.components(separatedBy: "\\[").count + 1,
                       script.filter { $0 == "]" }.count - script.components(separatedBy: "\\]").count + 1)
    }

    func testSettingsBecomeRunPropertiesAndABitstreamConstraintsFile() throws {
        let dir = try makeProject()
        var project = try Project.load(from: dir)
        var settings = ProjectSettings()
        settings.synthesis.directive = "AreaOptimized_high"
        settings.synthesis.flattenHierarchy = .full
        settings.synthesis.retiming = true
        settings.synthesis.maxDSP = 0
        settings.synthesis.moreOptions = "-verbose"
        settings.implementation.placeDirective = "Explore"
        settings.implementation.physOpt = true
        settings.implementation.physOptDirective = "AggressiveExplore"
        settings.implementation.postRoutePhysOpt = true
        settings.bitstream.binFile = true
        settings.bitstream.compress = true
        settings.language.defines = ["SIM", "W=8"]
        project.settings = settings
        let script = try ProjectScripts.projectModeScript(project: project, root: dir)
        for line in [
            "set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AreaOptimized_high [get_runs synth_1]",
            "set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY full [get_runs synth_1]",
            "set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]",
            "set_property STEPS.SYNTH_DESIGN.ARGS.MAX_DSP 0 [get_runs synth_1]",
            "set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-verbose} -objects [get_runs synth_1]",
            "set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]",
            "set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]",
            "set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]",
            "set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]",
            "puts $f {set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]}",
            "set_property used_in_synthesis false [get_files $xdc]",
            "set_property verilog_define {SIM W=8} [get_filesets sources_1]",
            "set_property verilog_define {SIM W=8} [get_filesets sim_1]",
        ] {
            XCTAssertTrue(script.contains(line), "missing: \(line)")
        }
        XCTAssertFalse(script.contains("STEPS.PHYS_OPT_DESIGN.IS_ENABLED"), "on is Vivado's own default, so no line")
        settings.implementation.physOpt = false
        project.settings = settings
        XCTAssertTrue(try ProjectScripts.projectModeScript(project: project, root: dir)
            .contains("set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED false [get_runs impl_1]"), "turned off: said so")
    }

    func testIPIsCreatedInTheProject() throws {
        let dir = try makeProject()
        var project = try Project.load(from: dir)
        project.ips = [ProjectIP(name: "cnt8", vlnv: "xilinx.com:ip:c_counter_binary:12.0", config: ["CONFIG.Output_Width": "8"])]
        let script = try ProjectScripts.projectModeScript(project: project, root: dir)
        XCTAssertTrue(script.contains("create_ip -name c_counter_binary -vendor xilinx.com -library ip -version 12.0 -module_name cnt8\n"))
        XCTAssertTrue(script.contains("set_property -dict [list CONFIG.Output_Width {8}] [get_ips cnt8]"))
        XCTAssertTrue(script.contains("generate_target all [get_ips cnt8]"))
    }

    func testBuildScriptIsWhatTheBuildRunsWithANote() throws {
        let dir = try makeProject()
        let project = try Project.load(from: dir)
        let script = try ProjectScripts.buildScript(project: project, root: dir)
        XCTAssertTrue(script.hasPrefix("# The script FPGA Bridge runs"))
        XCTAssertTrue(script.hasSuffix(project.buildScript(sources: try project.resolveSources(in: dir),
                                                           constraints: try project.resolveConstraints(in: dir))))
    }
}
