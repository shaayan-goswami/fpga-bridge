import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

@MainActor
final class ProjectToolsAppTests: XCTestCase {
    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("inputs"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    let top = "demo.srcs/sources_1/imports/top.v"
    let counter = "demo.srcs/sources_1/imports/counter.v"
    let tb = "demo.srcs/sim_1/imports/tb.v"

    /// A project with top (instantiating counter), counter, a constraint and a CR LF testbench, open in a model with
    /// finished runs.
    func openProject(runs: Bool = true) async throws -> (AppModel, URL) {
        func input(_ name: String, _ text: String) throws -> URL {
            let url = tmp.appendingPathComponent("inputs/\(name)")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        var request = NewProjectRequest(name: "demo", location: tmp, part: "xc7a35tcpg236-1")
        request.designSources = [try input("top.v", "module top(input clk);\n  counter u_c(.clk(clk));\nendmodule\n"),
                                 try input("counter.v", "module counter(input clk);\n  reg [3:0] count;\nendmodule\n")]
        request.constraints = [try input("pins.xdc", "set_property PACKAGE_PIN W5 [get_ports clk]\n")]
        request.simulationSources = [try input("tb.v", "module tb;\r\n  reg clk;\r\n  top dut(.clk(clk));\r\nendmodule\r\n")]
        let dir = try ProjectCreator.create(request)
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.tools.deleteFile = { try FileManager.default.removeItem(at: $0) }
        model.openProject(at: dir)
        if runs {
            model.run(.implementation)
            try await until { !model.isRunning && model.runs[.implementation]?.status == .complete }
        }
        return (model, dir)
    }

    func until(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out")
    }

    func outOfDate(_ model: AppModel) -> Bool { model.runs[.synthesis]?.outOfDate == true }

    func paths(_ nodes: [SourceNode]) -> [String] { nodes.flatMap { [$0.path].compactMap { $0 } + paths($0.children ?? []) } }

    // MARK: Sources context menu

    func testDisablingADesignFileGreysItAndMarksRunsOutOfDate() async throws {
        let (model, _) = try await openProject()
        model.setFileEnabled(counter, false)
        XCTAssertFalse(model.isFileEnabled(counter))
        XCTAssertTrue(outOfDate(model))
        let node = model.node(withID: "file:\(counter)")
        XCTAssertEqual(node?.isDisabled, true, "still listed, greyed")
        XCTAssertEqual(model.tclLines.last?.text, "set_property is_enabled false [get_files {\(counter)}]")
    }

    func testDisablingATestbenchLeavesRunsAlone() async throws {
        let (model, _) = try await openProject()
        model.setFileEnabled(tb, false)
        XCTAssertFalse(outOfDate(model))
    }

    func testMovingATestbenchIntoDesignSourcesMarksRunsOutOfDateAndFollowsTheOpenTab() async throws {
        let (model, dir) = try await openProject()
        model.openFile(tb)
        model.moveFile(tb, to: .design)
        let moved = "demo.srcs/sources_1/imports/tb.v"
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(moved).path))
        XCTAssertTrue(outOfDate(model))
        XCTAssertEqual(model.selectedTab, .file(moved))
        XCTAssertFalse(model.openTabs.contains(.file(tb)))
        XCTAssertEqual(model.setOf(moved), .design)
    }

    func testMovingAFileWithUnsavedEditsAsksFirst() async throws {
        let (model, _) = try await openProject(runs: false)
        model.updateDraft("module tb; // edited\nendmodule\n", for: tb)
        model.moveFile(tb, to: .design)
        XCTAssertEqual(model.unsavedPrompt?.files, [tb])
        XCTAssertEqual(model.setOf(tb), .simulation, "nothing moved yet")
        model.resolveUnsaved(.save)
        XCTAssertEqual(model.setOf("demo.srcs/sources_1/imports/tb.v"), .design)
    }

    func testSetAsTopForDesignAndSimulation() async throws {
        let (model, _) = try await openProject()
        model.setAsTop("tb", in: .simulation)
        XCTAssertEqual(model.project?.simulationTop, "tb")
        XCTAssertFalse(outOfDate(model), "the testbench to simulate doesn't affect synthesis")
        model.setAsTop("counter", in: .design)
        XCTAssertEqual(model.project?.top, "counter")
        XCTAssertTrue(outOfDate(model))
        XCTAssertEqual(model.sourceTree.first?.children?.first?.title, "counter")
    }

    func testRemovingAFileClosesItsTabAndDropsItFromTheTree() async throws {
        let (model, dir) = try await openProject()
        model.openFile(counter)
        model.removeFile(counter, deleteFromDisk: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(counter).path))
        XCTAssertFalse(model.openTabs.contains(.file(counter)))
        XCTAssertFalse(paths(model.sourceTree).contains(counter))
        XCTAssertTrue(outOfDate(model))
    }

    func testRemovingWithoutDeletingKeepsTheFileButTakesItOutOfTheProject() async throws {
        let (model, dir) = try await openProject()
        model.removeFile(counter, deleteFromDisk: false)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(counter).path))
        XCTAssertEqual(model.project?.excluded, [counter])
        XCTAssertFalse(paths(model.sourceTree).contains(counter), "excluded files aren't in the Sources window")
        XCTAssertFalse(model.allProjectFiles.map(\.path).contains(counter), "nor searched by Find in Files")
        XCTAssertTrue(outOfDate(model))
        XCTAssertEqual(model.tclLines.last?.text, "remove_files {\(counter)}")

        model.addSources([tmp.appendingPathComponent("inputs/counter.v")], to: .design)
        XCTAssertNil(model.project?.excluded, "adding it again brings it back")
        XCTAssertTrue(paths(model.sourceTree).contains(counter))
    }

    func testBlockDesignsStayInTheTreeWhenFilesAreDisabledOrRemoved() async throws {
        let (model, dir) = try await openProject(runs: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FPGABridgeCoreTests/Fixtures/blockdesign_vivado2025/mb_system")
        let bd = "demo.srcs/sources_1/bd/mb_system"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("demo.srcs/sources_1/bd"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: dir.appendingPathComponent(bd))
        model.refreshHierarchy()
        func hasBlockDesign() -> Bool { model.sourceTree.first { $0.id == "group.design" }?.children?.contains { $0.id == "bd:\(bd)/mb_system.bd" } == true }
        XCTAssertTrue(hasBlockDesign())
        model.setFileEnabled(counter, false)
        XCTAssertTrue(hasBlockDesign())
        model.removeFile(counter, deleteFromDisk: false)
        XCTAssertTrue(hasBlockDesign())
        XCTAssertFalse(model.allProjectFiles.contains { Project.isBlockDesign($0.path) }, "Find in Files searches HDL and constraints only")
    }

    func testReplaceFile() async throws {
        let (model, dir) = try await openProject()
        let newer = tmp.appendingPathComponent("inputs/counter_v2.v")
        try "module counter(input clk); // v2\nendmodule\n".write(to: newer, atomically: true, encoding: .utf8)
        model.openFile(counter)
        model.replaceFile(counter, with: newer)
        let path = "demo.srcs/sources_1/imports/counter_v2.v"
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path))
        XCTAssertEqual(model.selectedTab, .file(path))
        XCTAssertTrue(outOfDate(model))
    }

    // MARK: File > Project

    func testSaveAsOpensTheCopy() async throws {
        let (model, dir) = try await openProject(runs: false)
        model.saveProjectAs(name: "demo_copy", location: tmp, includeResults: false)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.project?.name, "demo_copy")
        XCTAssertEqual(model.projectURL?.lastPathComponent, "demo_copy")
        XCTAssertEqual(try Project.load(from: dir).name, "demo")
    }

    func testSaveAsWithUnsavedEditsAsksFirst() async throws {
        let (model, _) = try await openProject(runs: false)
        model.updateDraft("module top(input clk); // edited\nendmodule\n", for: top)
        model.saveProjectAs(name: "demo_copy", location: tmp, includeResults: false)
        XCTAssertNotNil(model.unsavedPrompt)
        model.resolveUnsaved(.save)
        XCTAssertEqual(model.project?.name, "demo_copy")
        XCTAssertTrue(model.contents(of: "demo_copy.srcs/sources_1/imports/top.v").contains("// edited"))
    }

    func testWriteTclWritesBothScripts() async throws {
        let (model, dir) = try await openProject(runs: false)
        let written = model.writeTcl(buildScript: true, projectScript: true, to: dir)
        XCTAssertEqual(written.map(\.lastPathComponent), ["demo.tcl", "demo_build.tcl"])
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("demo.tcl"), encoding: .utf8).contains("create_project demo"))
        XCTAssertTrue(model.tclLines.contains { $0.text.hasPrefix("write_project_tcl") })
    }

    // MARK: Find / Replace in Files

    func testFindInFilesSearchesDraftsAndReportsCRLFLines() async throws {
        let (model, _) = try await openProject(runs: false)
        model.updateDraft("module counter(input clk);\n  // clk edited\nendmodule\n", for: counter)
        model.tools.options = FileSearch.Options(text: "clk", wholeWord: true)
        model.findInFiles(replacing: false)
        XCTAssertEqual(model.consoleTab, .findResults)
        await model.tools.waitForSearch()
        let results = try XCTUnwrap(model.tools.results)
        XCTAssertEqual(results.matches(in: tb).map(\.line), [2, 3, 3], "CR LF lines")
        XCTAssertEqual(results.matches(in: counter).map(\.line), [1, 2], "the unsaved text is searched")
        XCTAssertEqual(results.matches(in: "demo.srcs/constrs_1/imports/pins.xdc").count, 1)
        XCTAssertEqual(results.filesSearched, 4)

        model.tools.scope = .simulation
        model.findInFiles(replacing: false)
        await model.tools.waitForSearch()
        XCTAssertEqual(model.tools.results?.files, [tb])

        model.tools.scope = .all
        model.tools.fileTypes = "*.xdc"
        model.findInFiles(replacing: false)
        await model.tools.waitForSearch()
        XCTAssertEqual(model.tools.results?.files, ["demo.srcs/constrs_1/imports/pins.xdc"])
    }

    func testClickingAResultOpensTheFileAtTheMatch() async throws {
        let (model, _) = try await openProject(runs: false)
        model.tools.options = FileSearch.Options(text: "dut")
        model.findInFiles(replacing: false)
        await model.tools.waitForSearch()
        let match = try XCTUnwrap(model.tools.results?.matches.first)
        model.reveal(match)
        XCTAssertEqual(model.selectedTab, .file(tb))
        let text = model.editedText(for: tb) as NSString
        XCTAssertEqual(text.substring(with: try XCTUnwrap(model.editorReveal[tb]).range), "dut")
    }

    func testReplaceInFilesEditsDraftsOnlyAndCanBeUndone() async throws {
        let (model, dir) = try await openProject()
        model.tools.options = FileSearch.Options(text: "clk", matchCase: true, wholeWord: true)
        model.tools.replacement = "clock"
        model.findInFiles(replacing: true)
        await model.tools.waitForSearch()
        XCTAssertEqual(model.tools.results?.matches.first { $0.path == tb }?.replacedLine, "  reg clock;")

        let changed = model.replaceInFiles([tb, top])
        XCTAssertEqual(changed, 6, "three in each file: the port name counts too")
        XCTAssertTrue(model.isDirty(tb))
        XCTAssertTrue(model.isDirty(top))
        XCTAssertFalse(model.isDirty(counter), "unticked files are left alone")
        XCTAssertEqual(model.editedText(for: tb), "module tb;\r\n  reg clock;\r\n  top dut(.clock(clock));\r\nendmodule\r\n",
                       "CR LF line ends are kept")
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent(tb), encoding: .utf8).contains("reg clk;"), "nothing written yet")
        XCTAssertFalse(outOfDate(model), "an unsaved edit changes no run")

        model.undoReplaceInFiles()
        XCTAssertFalse(model.isDirty(tb))
        XCTAssertFalse(model.isDirty(top))
        XCTAssertNil(model.tools.undoText)
    }

    func testABadPatternIsReportedAndANewSearchReplacesTheOld() async throws {
        let (model, _) = try await openProject(runs: false)
        model.tools.options = FileSearch.Options(text: "(", regularExpression: true)
        model.findInFiles(replacing: false)
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil

        model.tools.options = FileSearch.Options(text: "module")
        model.findInFiles(replacing: false)
        model.tools.options = FileSearch.Options(text: "endmodule")
        model.findInFiles(replacing: false)
        await model.tools.waitForSearch()
        XCTAssertEqual(model.tools.results?.options.text, "endmodule")
        XCTAssertEqual(model.tools.results?.matches.count, 3)
        XCTAssertFalse(model.tools.results?.cancelled ?? true)
    }

    func testCancelStopsTheSearch() async throws {
        let (model, _) = try await openProject(runs: false)
        model.tools.options = FileSearch.Options(text: "module")
        model.findInFiles(replacing: false)
        model.tools.cancelSearch()
        XCTAssertFalse(model.tools.isSearching)
        XCTAssertEqual(model.tools.results?.cancelled, true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.tools.results?.matches.count, 0, "nothing lands after Cancel")
    }
}
