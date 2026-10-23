import XCTest
@testable import FPGABridgeCore

final class ProjectOperationsTests: XCTestCase {
    var tmp: URL!
    let deleteNow: ProjectOperations.Delete = { try FileManager.default.removeItem(at: $0) }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-bridge-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("inputs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func input(_ name: String, _ text: String) throws -> URL {
        let url = tmp.appendingPathComponent("inputs/\(name)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A project with a top that instantiates a counter, a constraint and a testbench (written with CR LF).
    func makeProject(_ name: String = "demo") throws -> URL {
        var request = NewProjectRequest(name: name, location: tmp, part: "xc7a35tcpg236-1")
        request.designSources = [try input("top.v", "module top(input clk); counter u_c(.clk(clk)); endmodule\n"),
                                 try input("counter.v", "module counter(input clk); endmodule\n")]
        request.constraints = [try input("pins.xdc", "# pins\n")]
        request.simulationSources = [try input("tb top.v", "module tb;\r\n  top dut(.clk());\r\nendmodule\r\n")]
        return try ProjectCreator.create(request)
    }

    func exists(_ dir: URL, _ path: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }

    // MARK: Save As

    func testSaveAsCopiesRenamesFoldersAndPathsAndLeavesTheOriginal() throws {
        let dir = try makeProject()
        var project = try Project.load(from: dir)
        project.disabled = ["demo.srcs/sources_1/imports/counter.v"]
        project.excluded = ["demo.srcs/sources_1/imports/old.v"]
        var settings = ProjectSettings(); settings.language.includeDirectories = ["demo.srcs/sources_1/imports"]
        project.settings = settings
        try project.save(to: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("build/top.bit"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("demo.sim/sim_1/behav"), withIntermediateDirectories: true)

        let location = tmp.appendingPathComponent("copies with space")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let copy = try ProjectOperations.saveAs(dir, name: "demo2", location: location, includeResults: false)
        XCTAssertEqual(copy.lastPathComponent, "demo2")
        let saved = try Project.load(from: copy)
        XCTAssertEqual(saved.name, "demo2")
        XCTAssertEqual(saved.sources, ["demo2.srcs/sources_1"])
        XCTAssertEqual(saved.simulationSources, ["demo2.srcs/sim_1"])
        XCTAssertEqual(saved.disabled, ["demo2.srcs/sources_1/imports/counter.v"])
        XCTAssertEqual(saved.excluded, ["demo2.srcs/sources_1/imports/old.v"])
        XCTAssertEqual(saved.settings?.language.includeDirectories, ["demo2.srcs/sources_1/imports"])
        XCTAssertTrue(exists(copy, "demo2.srcs/sim_1/imports/tb top.v"))
        XCTAssertFalse(exists(copy, "demo.srcs"))
        XCTAssertFalse(exists(copy, "build"), "run results are left out")
        XCTAssertFalse(exists(copy, "demo2.sim"))
        XCTAssertEqual(try saved.resolveSources(in: copy), ["demo2.srcs/sources_1/imports/top.v"])
        XCTAssertEqual(try Project.load(from: dir).name, "demo", "the original is untouched")

        let withResults = try ProjectOperations.saveAs(dir, name: "demo3", location: location, includeResults: true)
        XCTAssertTrue(exists(withResults, "build/top.bit"))
        XCTAssertTrue(exists(withResults, "demo3.sim/sim_1/behav"))
    }

    func testSaveAsRefusesBadNamesExistingFoldersAndItsOwnFolder() throws {
        let dir = try makeProject()
        XCTAssertThrowsError(try ProjectOperations.saveAs(dir, name: "has space", location: tmp, includeResults: false))
        XCTAssertThrowsError(try ProjectOperations.saveAs(dir, name: "demo", location: tmp, includeResults: false)) {
            XCTAssertEqual($0 as? ProjectCreatorError, .alreadyExists(dir.path))
        }
        XCTAssertThrowsError(try ProjectOperations.saveAs(dir, name: "inner", location: dir, includeResults: false)) {
            XCTAssertEqual($0 as? ProjectOperationError, .insideItself)
        }
        XCTAssertFalse(exists(dir, "inner"))
    }

    // MARK: Archive

    func testArchiveZipsTheProjectWithOrWithoutResults() throws {
        let dir = try makeProject()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("build/top.bit"), atomically: true, encoding: .utf8)

        func listing(_ zip: URL) throws -> String {
            try Shell.run("/usr/bin/unzip", ["-l", zip.path]).stdout
        }
        let small = tmp.appendingPathComponent("demo archive.zip")
        try ProjectOperations.archive(dir, to: small, includeResults: false)
        let smallList = try listing(small)
        XCTAssertTrue(smallList.contains("demo/fpga-bridge.json"), smallList)
        XCTAssertTrue(smallList.contains("demo/demo.srcs/sim_1/imports/tb top.v"))
        XCTAssertFalse(smallList.contains("build/top.bit"))

        let full = tmp.appendingPathComponent("full.zip")
        try ProjectOperations.archive(dir, to: full, includeResults: true)
        XCTAssertTrue(try listing(full).contains("demo/build/top.bit"))

        try ProjectOperations.archive(dir, to: full, includeResults: false)
        XCTAssertFalse(try listing(full).contains("build/top.bit"), "an existing archive is replaced")
    }

    // MARK: Enable / Disable

    func testDisablingADesignFileDropsItFromTheBuildAndFixesTheTop() throws {
        let dir = try makeProject()
        let top = "demo.srcs/sources_1/imports/top.v"
        try ProjectOperations.setEnabled(top, false, in: dir)
        var project = try Project.load(from: dir)
        XCTAssertFalse(ProjectOperations.isEnabled(top, in: project))
        XCTAssertEqual(try project.resolveSources(in: dir), ["demo.srcs/sources_1/imports/counter.v"])
        try ProjectOperations.setEnabled(top, true, in: dir)
        project = try Project.load(from: dir)
        XCTAssertNil(project.disabled)
        XCTAssertThrowsError(try ProjectOperations.setEnabled("nope.v", false, in: dir))
    }

    // MARK: Remove

    func testRemovingAFileInASourceFolderKeepsItOnDiskByDefault() throws {
        let dir = try makeProject()
        let path = "demo.srcs/sources_1/imports/counter.v"
        try ProjectOperations.setEnabled(path, false, in: dir)
        try ProjectOperations.remove(path, from: dir, deleteFromDisk: false, delete: deleteNow)
        XCTAssertTrue(exists(dir, path), "still on disk")
        let after = try Project.load(from: dir)
        XCTAssertEqual(after.excluded, [path])
        XCTAssertNil(after.disabled, "no stale entry is left in the disabled list")
        XCTAssertEqual(try after.resolveSources(in: dir), ["demo.srcs/sources_1/imports/top.v"])
        XCTAssertEqual(try after.resolveSources(in: dir, includingDisabled: true), ["demo.srcs/sources_1/imports/top.v"],
                       "excluded files are left out even when disabled ones are asked for")
        XCTAssertNil(ProjectOperations.set(of: path, in: after, root: dir))

        // Add Sources of the same file takes it off the list.
        try ProjectCreator.add([try input("counter.v", "module counter(input clk); endmodule\n")], to: .design, projectDirectory: dir)
        let readded = try Project.load(from: dir)
        XCTAssertNil(readded.excluded)
        XCTAssertEqual(try readded.resolveSources(in: dir).count, 2)
    }

    func testRemovingWithDeleteSendsTheFileToTheTrashAndRemembersNothing() throws {
        let dir = try makeProject()
        let path = "demo.srcs/sources_1/imports/counter.v"
        let trash = tmp.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try ProjectOperations.remove(path, from: dir, deleteFromDisk: true, delete: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), ["counter.v"])
        XCTAssertFalse(exists(dir, path))
        let after = try Project.load(from: dir)
        XCTAssertNil(after.excluded)
        XCTAssertEqual(try after.resolveSources(in: dir, includingDisabled: true), ["demo.srcs/sources_1/imports/top.v"])
    }

    func testCreatingAFileAtAnExcludedPathBringsItBack() throws {
        let dir = try makeProject()
        let created = try ProjectCreator.createFile(NewFile(set: .design, name: "extra.v"), language: "Verilog", projectName: "demo", directory: dir)
        try ProjectOperations.remove(created, from: dir, deleteFromDisk: true, delete: deleteNow)
        try ProjectOperations.remove("demo.srcs/sources_1/imports/counter.v", from: dir, deleteFromDisk: false, delete: deleteNow)
        var project = try Project.load(from: dir)
        project.excluded = (project.excluded ?? []) + [created]
        try project.save(to: dir)
        _ = try ProjectCreator.createFile(NewFile(set: .design, name: "extra.v"), language: "Verilog", projectName: "demo", directory: dir)
        XCTAssertEqual(try Project.load(from: dir).excluded, ["demo.srcs/sources_1/imports/counter.v"])
    }

    func testOldProjectFilesWithoutTheListLoadAndAnEmptyListIsNotWritten() throws {
        let dir = try makeProject()
        let text = try String(contentsOf: dir.appendingPathComponent(Project.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains("excluded"))
        XCTAssertNil(try Project.load(from: dir).excluded)
    }

    func testRemovingAFileListedByNameCanKeepItOnDisk() throws {
        let dir = try makeProject()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("extra"), withIntermediateDirectories: true)
        try "module helper; endmodule\n".write(to: dir.appendingPathComponent("extra/helper.v"), atomically: true, encoding: .utf8)
        var project = try Project.load(from: dir)
        project.sources.append("extra/helper.v")
        try project.save(to: dir)
        try ProjectOperations.remove("extra/helper.v", from: dir, deleteFromDisk: false, delete: deleteNow)
        XCTAssertTrue(exists(dir, "extra/helper.v"))
        let after = try Project.load(from: dir)
        XCTAssertEqual(after.sources, ["demo.srcs/sources_1"])
        XCTAssertNil(after.excluded, "dropping the entry is enough")
    }

    func testRemovingTheTopsFilePicksANewTop() throws {
        let dir = try makeProject()
        try ProjectOperations.remove("demo.srcs/sources_1/imports/top.v", from: dir, deleteFromDisk: true, delete: deleteNow)
        XCTAssertEqual(try Project.load(from: dir).top, "counter")
    }

    // MARK: Move

    func testMovingBetweenDesignAndSimulationSourcesMovesTheFile() throws {
        let dir = try makeProject()
        let tb = "demo.srcs/sim_1/imports/tb top.v"
        try ProjectOperations.setEnabled(tb, false, in: dir)
        let moved = try ProjectOperations.move(tb, to: .design, in: dir)
        XCTAssertEqual(moved, "demo.srcs/sources_1/imports/tb top.v")
        XCTAssertTrue(exists(dir, moved))
        XCTAssertFalse(exists(dir, tb))
        var project = try Project.load(from: dir)
        XCTAssertEqual(project.disabled, [moved], "the disabled entry follows the file")
        XCTAssertEqual(ProjectOperations.set(of: moved, in: project, root: dir), .design)

        let back = try ProjectOperations.move(moved, to: .simulation, in: dir)
        XCTAssertEqual(back, tb)
        project = try Project.load(from: dir)
        XCTAssertEqual(ProjectOperations.set(of: tb, in: project, root: dir), .simulation)
        XCTAssertThrowsError(try ProjectOperations.move("demo.srcs/constrs_1/imports/pins.xdc", to: .design, in: dir))
    }

    func testMovingIntoASetWithNoFolderAddsTheFolder() throws {
        let dir = try makeProject()
        var project = try Project.load(from: dir)
        project.simulationSources = nil
        try project.save(to: dir)
        let moved = try ProjectOperations.move("demo.srcs/sources_1/imports/counter.v", to: .simulation, in: dir)
        project = try Project.load(from: dir)
        XCTAssertEqual(project.simulationSources, ["demo.srcs/sim_1"])
        XCTAssertEqual(try project.resolveSimulationSources(in: dir).filter { $0 == moved }, [moved])
    }

    // MARK: Set as Top

    func testSetAsTopForDesignAndSimulation() throws {
        let dir = try makeProject()
        try ProjectOperations.setTop("counter", for: .design, in: dir)
        try ProjectOperations.setTop("tb", for: .simulation, in: dir)
        let project = try Project.load(from: dir)
        XCTAssertEqual(project.top, "counter")
        XCTAssertEqual(project.simulationTop, "tb")
        XCTAssertThrowsError(try ProjectOperations.setTop("bad name", for: .design, in: dir))
        XCTAssertEqual(ProjectOperations.modules(in: "demo.srcs/sim_1/imports/tb top.v", root: dir), ["tb"])
    }

    // MARK: Replace

    func testReplaceFileKeepsTheSetAndEnabledState() throws {
        let dir = try makeProject()
        let old = "demo.srcs/sources_1/imports/counter.v"
        try ProjectOperations.setEnabled(old, false, in: dir)
        let newer = try input("counter2.v", "module counter(input clk, input rst); endmodule\n")
        let path = try ProjectOperations.replace(old, with: newer, in: dir, delete: deleteNow)
        XCTAssertEqual(path, "demo.srcs/sources_1/imports/counter2.v")
        XCTAssertFalse(exists(dir, old))
        XCTAssertEqual(try Project.load(from: dir).disabled, [path])

        let same = try input("counter2.v", "module counter(input clk); // v3\nendmodule\n")
        XCTAssertEqual(try ProjectOperations.replace(path, with: same, in: dir, delete: deleteNow), path)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8).contains("v3"))
        XCTAssertThrowsError(try ProjectOperations.replace(path, with: try input("pins2.xdc", ""), in: dir, delete: deleteNow))
    }

    // MARK: Copy File Into Project

    func testCopyIntoProjectOnlyForFilesListedByNameOutsideSrcs() throws {
        let dir = try makeProject()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try "module helper; endmodule\n".write(to: dir.appendingPathComponent("shared/helper.v"), atomically: true, encoding: .utf8)
        var project = try Project.load(from: dir)
        project.sources.append("shared/helper.v")
        try project.save(to: dir)
        XCTAssertFalse(ProjectOperations.canCopyIntoProject("demo.srcs/sources_1/imports/top.v", in: project))
        XCTAssertTrue(ProjectOperations.canCopyIntoProject("shared/helper.v", in: project))
        let copy = try ProjectOperations.copyIntoProject("shared/helper.v", in: dir)
        XCTAssertEqual(copy, "demo.srcs/sources_1/imports/helper.v")
        XCTAssertTrue(exists(dir, "shared/helper.v"), "the original stays")
        project = try Project.load(from: dir)
        XCTAssertEqual(project.sources, ["demo.srcs/sources_1", copy])
        XCTAssertThrowsError(try ProjectOperations.copyIntoProject(copy, in: dir))
    }
}
