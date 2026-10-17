import XCTest
@testable import FPGABridgeCore

/// The build manifest: what a bitstream was built from, and whether the project still matches it.
final class BuildManifestTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)")
        let project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1", sources: ["src"], constraints: ["constraints"], board: "basys3")
        try write("src/top.v", "module top(); endmodule")
        try write("constraints/pins.xdc", "# pins")
        try project.save(to: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    var project: Project { get throws { try Project.load(from: root) } }

    func manifest(git: BuildManifest.Git? = nil) throws -> BuildManifest {
        let p = try project
        return BuildManifest(project: p.name, top: p.top, part: p.part, board: p.board, vivadoVersion: "2025.2", buildMachine: "buildbox",
                             builtAt: Date(timeIntervalSince1970: 1_800_000_000),
                             files: BuildManifest.fingerprint(try BuildManifest.inputs(of: p, root: root), root: root), git: git)
    }

    func testItFingerprintsEverythingABuildSendsAndNothingElse() throws {
        try write("build/top.bit", "bits")
        let m = try manifest()
        XCTAssertEqual(Set(m.files.keys), ["src/top.v", "constraints/pins.xdc", Project.fileName], "sources, constraints and the project file; not the build output")
        XCTAssertEqual(m.files["src/top.v"]?.count, 64, "SHA-256 in hex")
        XCTAssertEqual(m.sourceID.count, 12)
    }

    func testAnEditAnAddedFileAndADeletedOneAreAllChanges() throws {
        let m = try manifest()
        XCTAssertEqual(m.changes(project: try project, root: root), [], "nothing changed since the build")
        try write("src/top.v", "module top(input a); endmodule")
        try write("src/extra.v", "module extra(); endmodule")
        try FileManager.default.removeItem(at: root.appendingPathComponent("constraints/pins.xdc"))
        XCTAssertEqual(m.changes(project: try project, root: root), ["constraints/pins.xdc", "src/extra.v", "src/top.v"])
    }

    func testSavingTheFileAgainUnchangedIsNotAChange() throws {
        let m = try manifest()
        try write("src/top.v", "module top(); endmodule")
        XCTAssertEqual(m.changes(project: try project, root: root), [], "content decides, not the file's date")
    }

    func testItSavesAndLoads() throws {
        let m = try manifest(git: .init(commit: "0123456789abcdef", uncommittedChanges: true))
        let out = root.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try m.save(to: out)
        XCTAssertEqual(BuildManifest.load(from: out), m)
        XCTAssertNil(BuildManifest.load(from: root), "no manifest: an older build")
    }

    func testTheSummaryShownBeforeProgramming() throws {
        let m = try manifest(git: .init(commit: "0123456789abcdef", uncommittedChanges: true))
        let clean = m.summary(changes: [], project: try project, devicePart: "xc7a35t")
        XCTAssertTrue(clean.warnings.isEmpty, "\(clean.warnings)")
        XCTAssertTrue(clean.lines.contains { $0.contains("buildbox") && $0.contains("Vivado 2025.2") })
        XCTAssertTrue(clean.lines.contains { $0.contains("Basys 3") && $0.contains("xc7a35tcpg236-1") && $0.contains("top") })
        XCTAssertTrue(clean.lines.contains { $0.contains(m.sourceID) && $0.contains("01234567") && $0.contains("uncommitted") })

        var moved = try project
        moved.top = "other_top"
        let warned = m.summary(changes: ["a.v", "b.v", "c.v", "d.v"], project: moved, devicePart: "xc7a100t")
        XCTAssertEqual(warned.warnings.count, 3)
        XCTAssertTrue(warned.warnings[0].contains("a.v, b.v, c.v and 1 more"))
        XCTAssertTrue(warned.warnings[1].contains("xc7a100t"), "a bitstream for another FPGA")
        XCTAssertTrue(warned.warnings[2].contains("other_top"), "the project's top changed since")
    }

    func testGitStateOfARepository() throws {
        XCTAssertNil(BuildManifest.gitState(of: root), "not in a repository")
        guard (try? Shell.run("/usr/bin/xcode-select", ["-p"]))?.succeeded == true else { throw XCTSkip("no developer tools") }
        func git(_ args: String...) throws {
            let r = try Shell.run("/usr/bin/git", ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args)
            XCTAssertTrue(r.succeeded, r.stderr)
        }
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "first")
        let committed = try XCTUnwrap(BuildManifest.gitState(of: root))
        XCTAssertEqual(committed.commit.count, 40)
        XCTAssertFalse(committed.uncommittedChanges)
        try write("build/top.bit", "bits")
        XCTAssertFalse(try XCTUnwrap(BuildManifest.gitState(of: root)).uncommittedChanges, "build output doesn't count")
        try write("src/top.v", "module top(input a); endmodule")
        XCTAssertTrue(try XCTUnwrap(BuildManifest.gitState(of: root)).uncommittedChanges)
    }
}
