import XCTest
@testable import FPGABridgeCore

final class ProjectCreatorTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-bridge-creator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("work"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    var work: URL { tmp.appendingPathComponent("work") }

    func input(_ name: String, _ text: String) throws -> URL {
        let url = tmp.appendingPathComponent("inputs/\(name)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func exists(_ url: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func request(_ name: String = "blinky") throws -> NewProjectRequest {
        var r = NewProjectRequest(name: name, location: work, part: "xc7a35tcpg236-1", board: "basys3")
        r.designSources = [
            try input("blinky.v", "module blinky(input clk, output led);\n  clk_div #(.N(4)) u_div (.clk(clk));\nendmodule\n"),
            try input("clk_div.v", "module clk_div #(parameter N=2) (input clk);\nendmodule\n"),
        ]
        r.constraints = [try input("pins.xdc", "set_property PACKAGE_PIN W5 [get_ports clk]\n")]
        r.simulationSources = [try input("blinky_tb.v", "module blinky_tb;\nendmodule\n")]
        return r
    }

    // MARK: Create

    func testCreatesVivadoStyleLayoutAndProjectFile() throws {
        let dir = try ProjectCreator.create(request())
        XCTAssertEqual(dir.lastPathComponent, "blinky")
        for path in ["blinky.srcs/sources_1/imports/blinky.v", "blinky.srcs/sources_1/imports/clk_div.v",
                     "blinky.srcs/constrs_1/imports/pins.xdc", "blinky.srcs/sim_1/imports/blinky_tb.v",
                     "blinky.srcs/sources_1/new", "blinky.srcs/constrs_1/new", "blinky.srcs/sim_1/new", "fpga-bridge.json"] {
            XCTAssertTrue(exists(dir, path), path)
        }
        let project = try Project.load(from: dir)
        XCTAssertEqual(project.name, "blinky")
        XCTAssertEqual(project.top, "blinky", "the module nothing instantiates")
        XCTAssertEqual(project.part, "xc7a35tcpg236-1")
        XCTAssertEqual(project.board, "basys3")
        XCTAssertEqual(project.targetLanguage, "Verilog")
        XCTAssertEqual(try project.resolveSources(in: dir),
                       ["blinky.srcs/sources_1/imports/blinky.v", "blinky.srcs/sources_1/imports/clk_div.v"])
        XCTAssertEqual(try project.resolveConstraints(in: dir), ["blinky.srcs/constrs_1/imports/pins.xdc"])
        XCTAssertEqual(try project.resolveSimulationSources(in: dir), ["blinky.srcs/sim_1/imports/blinky_tb.v"])
    }

    func testSourcesAreCopiedNotMoved() throws {
        let r = try request()
        try ProjectCreator.create(r)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.designSources[0].path), "the original must stay where it was")
    }

    func testWithoutSubdirectoryUsesTheLocationItself() throws {
        var r = try request()
        r.createSubdirectory = false
        let dir = try ProjectCreator.create(r)
        XCTAssertEqual(dir.standardizedFileURL, work.standardizedFileURL)
        XCTAssertTrue(exists(work, "fpga-bridge.json"))
        XCTAssertTrue(exists(work, "blinky.srcs/sources_1/imports/blinky.v"))
    }

    func testDoNotSpecifySourcesStillCreatesAProject() throws {
        let r = NewProjectRequest(name: "empty", location: work, part: "xc7a35tcpg236-1")
        let dir = try ProjectCreator.create(r)
        let project = try Project.load(from: dir)
        XCTAssertEqual(project.top, "empty", "no modules to detect, so fall back to the project name")
        XCTAssertEqual(try project.resolveSources(in: dir), [])
    }

    func testRejectsNamesVivadoWouldChokeOn() throws {
        for bad in ["my project", "", "a/b", "über", "x;y"] {
            var r = try request()
            r.name = bad
            XCTAssertThrowsError(try ProjectCreator.create(r), bad) { XCTAssertEqual($0 as? ProjectCreatorError, .invalidName) }
        }
    }

    func testRejectsExistingProjectDirectoryAndMissingLocation() throws {
        try ProjectCreator.create(request())
        XCTAssertThrowsError(try ProjectCreator.create(request())) {
            guard case .alreadyExists = $0 as? ProjectCreatorError else { return XCTFail("\($0)") }
        }
        var r = try request("other")
        r.location = tmp.appendingPathComponent("nowhere")
        XCTAssertThrowsError(try ProjectCreator.create(r)) {
            guard case .locationMissing = $0 as? ProjectCreatorError else { return XCTFail("\($0)") }
        }
    }

    func testBadFileTypeLeavesNothingBehind() throws {
        var r = try request()
        r.constraints = [try input("oops.v", "module x; endmodule")]
        XCTAssertThrowsError(try ProjectCreator.create(r)) {
            XCTAssertEqual($0 as? ProjectCreatorError, .unsupportedFile("oops.v", .constraints))
        }
        XCTAssertFalse(exists(work, "blinky"), "a failed create must not leave a half-made project")
    }

    func testBuildExplainsWhenThereAreNoSources() throws {
        let dir = try ProjectCreator.create(NewProjectRequest(name: "empty", location: work, part: "xc7a35tcpg236-1"))
        let project = try Project.load(from: dir)
        let config = BridgeConfig(host: "h", user: "u", vivadoPath: #"C:\v\2023.2\bin\vivado.bat"#)
        XCTAssertThrowsError(try Remote(config: config).build(project: project, root: dir)) {
            XCTAssertTrue("\($0)".contains("no design source files"), "\($0)")
        }
    }

    // MARK: Create File

    func testCreateFileWritesTemplatesWithTheRightExtension() throws {
        var r = NewProjectRequest(name: "p", location: work, part: "x")
        r.newFiles = [NewFile(set: .design, name: "top"), NewFile(set: .constraints, name: "pins")]
        let dir = try ProjectCreator.create(r)
        let verilog = try String(contentsOf: dir.appendingPathComponent("p.srcs/sources_1/new/top.v"), encoding: .utf8)
        XCTAssertTrue(verilog.contains("module top("), verilog)
        XCTAssertTrue(exists(dir, "p.srcs/constrs_1/new/pins.xdc"))
        XCTAssertEqual(try Project.load(from: dir).top, "top", "a created module becomes the detected top")

        r = NewProjectRequest(name: "q", location: work, part: "x")
        r.language = "VHDL"
        r.newFiles = [NewFile(set: .design, name: "core")]
        let vhdl = try ProjectCreator.create(r)
        let text = try String(contentsOf: vhdl.appendingPathComponent("q.srcs/sources_1/new/core.vhd"), encoding: .utf8)
        XCTAssertTrue(text.contains("entity core is"), text)
    }

    func testCreateFileRejectsBadNamesAndWrongTypes() throws {
        for bad in [NewFile(set: .design, name: "my file"), NewFile(set: .design, name: "x.xdc"), NewFile(set: .constraints, name: "x.v")] {
            var r = NewProjectRequest(name: "p\(abs(bad.name.hashValue) % 1000)", location: work, part: "x")
            r.newFiles = [bad]
            XCTAssertThrowsError(try ProjectCreator.create(r), bad.name)
        }
    }

    func testBadNewFileLeavesNothingBehind() throws {
        var r = NewProjectRequest(name: "p", location: work, part: "x")
        r.designSources = [try input("ok.v", "module ok; endmodule")]
        r.newFiles = [NewFile(set: .design, name: "bad name")]
        XCTAssertThrowsError(try ProjectCreator.create(r))
        XCTAssertFalse(exists(work, "p"))

        // Without a subdirectory the location is the user's own folder: only what we added may be removed.
        r.createSubdirectory = false
        XCTAssertThrowsError(try ProjectCreator.create(r))
        XCTAssertFalse(exists(work, "p.srcs"))
        XCTAssertFalse(exists(work, "fpga-bridge.json"))
    }

    // MARK: Add sources

    func testAddSourcesCopiesAndReplacesSameName() throws {
        let dir = try ProjectCreator.create(request())
        let extra = try input("debounce.v", "module debounce; endmodule")
        let added = try ProjectCreator.add([extra], to: .design, projectDirectory: dir)
        XCTAssertEqual(added, ["blinky.srcs/sources_1/imports/debounce.v"])
        XCTAssertTrue(exists(dir, added[0]))

        try "module debounce; // v2\nendmodule".write(to: extra, atomically: true, encoding: .utf8)
        try ProjectCreator.add([extra], to: .design, projectDirectory: dir)
        let text = try String(contentsOf: dir.appendingPathComponent(added[0]), encoding: .utf8)
        XCTAssertTrue(text.contains("v2"))
    }

    func testAddRejectsWrongType() throws {
        let dir = try ProjectCreator.create(request())
        let notes = try input("notes.txt", "hi")
        XCTAssertThrowsError(try ProjectCreator.add([notes], to: .design, projectDirectory: dir))
        XCTAssertThrowsError(try ProjectCreator.add([try input("x.v", "module x; endmodule")], to: .constraints, projectDirectory: dir))
    }

    func testAddingSourcesKeepsAnExistingTopButFixesAMissingOne() throws {
        let dir = try ProjectCreator.create(NewProjectRequest(name: "p", location: work, part: "x"))
        XCTAssertEqual(try Project.load(from: dir).top, "p", "no modules yet")
        try ProjectCreator.add([try input("adder.v", "module adder; endmodule")], to: .design, projectDirectory: dir)
        XCTAssertEqual(try Project.load(from: dir).top, "adder", "the placeholder top no longer exists, so it is replaced")
        try ProjectCreator.add([try input("zeta.v", "module zeta; endmodule")], to: .design, projectDirectory: dir)
        XCTAssertEqual(try Project.load(from: dir).top, "adder", "a top that still exists is kept")
    }

    // MARK: Top module detection

    func testTopIsTheModuleNothingInstantiates() throws {
        let top = try ProjectCreator.pickTop(from: [
            "module alu(input a); endmodule",
            "module cpu(input clk); alu u_alu (.a(clk)); endmodule",
            "module soc(input clk); cpu #(.W(8)) u_cpu (.clk(clk)); endmodule",
        ])
        XCTAssertEqual(top, "soc")
    }

    func testCommentedOutInstantiationsAndDeclarationsAreIgnored() throws {
        let top = try ProjectCreator.pickTop(from: [
            "// module ghost(); endmodule\nmodule real_top; /* old: helper u (); */ endmodule",
            "module helper; endmodule",
        ])
        // 'helper' is only "instantiated" inside a comment, so both modules are roots; 'helper' sorts before 'real_top'.
        XCTAssertEqual(top, "helper")
    }

    func testSeveralRootsPickTheFirstByNameAndACyclePicksTheFirstModule() throws {
        XCTAssertEqual(try ProjectCreator.pickTop(from: ["module zeta; endmodule", "module alpha; endmodule"]), "alpha")
        XCTAssertEqual(try ProjectCreator.pickTop(from: ["module a; b u (); endmodule", "module b; a u (); endmodule"]), "a")
    }

    func testNoModulesIsAnError() {
        XCTAssertThrowsError(try ProjectCreator.pickTop(from: ["// nothing here"]))
    }
}
