import XCTest
@testable import FPGABridgeCore

/// The project file's optional `disabled` list (Vivado's Disable File).
final class ProjectDisabledFilesTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-bridge-disabled-\(UUID().uuidString)")
        for dir in ["src", "tb", "xdc"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["src/top.v", "src/old.v", "tb/tb.v", "tb/tb_old.v", "xdc/a.xdc", "xdc/b.xdc"] {
            try "// \(file)\n".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAProjectFileWithoutTheListStillLoads() throws {
        let json = #"{"name":"demo","top":"top","part":"xc7a35tcpg236-1","sources":["src"],"constraints":["xdc"]}"#
        try json.write(to: root.appendingPathComponent(Project.fileName), atomically: true, encoding: .utf8)
        let project = try Project.load(from: root)
        XCTAssertNil(project.disabled)
        XCTAssertEqual(try project.resolveSources(in: root), ["src/old.v", "src/top.v"])
    }

    func testDisabledFilesAreLeftOutOfEverySetUnlessAskedFor() throws {
        var project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1", sources: ["src"], constraints: ["xdc"],
                              simulationSources: ["tb"])
        project.disabled = ["src/old.v", "tb/tb_old.v", "xdc/b.xdc"]
        try project.save(to: root)
        let loaded = try Project.load(from: root)
        XCTAssertEqual(loaded.disabled, ["src/old.v", "tb/tb_old.v", "xdc/b.xdc"])
        XCTAssertEqual(try loaded.resolveSources(in: root), ["src/top.v"])
        XCTAssertEqual(try loaded.resolveConstraints(in: root), ["xdc/a.xdc"])
        XCTAssertEqual(try loaded.resolveSimulationSources(in: root), ["tb/tb.v"])
        XCTAssertEqual(try loaded.resolveSources(in: root, includingDisabled: true), ["src/old.v", "src/top.v"])
        XCTAssertFalse(loaded.buildScript(sources: try loaded.resolveSources(in: root), constraints: try loaded.resolveConstraints(in: root))
            .contains("old.v"))
    }

    func testExcludedFilesAreLeftOutEvenWithDisabledOnesIncluded() throws {
        var project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1", sources: ["src"], constraints: ["xdc"],
                              simulationSources: ["tb"])
        project.excluded = ["src/old.v", "xdc/b.xdc", "tb/tb_old.v"]
        project.disabled = ["src/top.v"]
        try project.save(to: root)
        let loaded = try Project.load(from: root)
        XCTAssertEqual(loaded.excluded, ["src/old.v", "xdc/b.xdc", "tb/tb_old.v"])
        XCTAssertEqual(try loaded.resolveSources(in: root), [])
        XCTAssertEqual(try loaded.resolveSources(in: root, includingDisabled: true), ["src/top.v"])
        XCTAssertEqual(try loaded.resolveConstraints(in: root, includingDisabled: true), ["xdc/a.xdc"])
        XCTAssertEqual(try loaded.resolveSimulationSources(in: root, includingDisabled: true), ["tb/tb.v"])
    }

    func testAnEmptyListIsNotWrittenAsAnythingSpecial() throws {
        let project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1", sources: ["src"], constraints: [])
        try project.save(to: root)
        let text = try String(contentsOf: root.appendingPathComponent(Project.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains("disabled"), "old versions of the app keep reading files with nothing disabled")
        XCTAssertFalse(text.contains("excluded"))
    }
}
