import XCTest
@testable import FPGABridgeCore

final class ProgrammerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("programmer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stand-in openFPGALoader that records its arguments and exits with `status`.
    private func fakeLoader(status: Int32 = 0, output: String = "") throws -> Programmer {
        let path = directory.appendingPathComponent(Programmer.executableName)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" > "\(directory.path)/args.txt"
        [ "$1" = "--Version" ] && echo "openFPGALoader v9.9.9" && exit 0
        printf '%s' '\(output)'
        exit \(status)
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return Programmer(executable: path.path)
    }

    private func recordedArguments() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("args.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testArgumentsNameTheBoardAndTheBitstream() {
        let board = BoardCatalog.lookup("basys3")
        XCTAssertEqual(Programmer.arguments(bitstream: "build/top.bit", board: board, target: .sram),
                       ["-b", "basys3", "build/top.bit"])
        XCTAssertEqual(Programmer.arguments(bitstream: "build/top.bit", board: board, target: .flash),
                       ["-b", "basys3", "-f", "build/top.bit"])
        XCTAssertEqual(Programmer.arguments(bitstream: "x.bit", board: nil, target: .sram), ["x.bit"],
                       "without a board, openFPGALoader finds the cable itself")
    }

    func testEveryBoardHasAUniqueLoaderName() {
        let names = BoardCatalog.all.compactMap(\.loaderName)
        XCTAssertEqual(names.count, BoardCatalog.all.count)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0 == $0.lowercased() && !$0.contains("-") }, "openFPGALoader names use underscores")
    }

    func testLocateFindsTheProgramOnThePathOrInTheFallbackFolders() throws {
        _ = try fakeLoader()
        XCTAssertEqual(Programmer.locate(path: directory.path, searchPaths: [])?.executable,
                       directory.appendingPathComponent(Programmer.executableName).path)
        XCTAssertNotNil(Programmer.locate(path: "", searchPaths: [directory.path]), "the app has no shell PATH")
        XCTAssertNil(Programmer.locate(path: "/nonexistent", searchPaths: []))
    }

    func testBitstreamPathPointsAtTheBuildFolderAndSaysToBuildFirst() throws {
        let project = Project(name: "p", top: "top", part: "xc7a35tcpg236-1", sources: ["a.v"], constraints: [])
        XCTAssertThrowsError(try Programmer.bitstreamPath(for: project, root: directory)) { error in
            XCTAssertTrue(error.userMessage.contains("fpga-bridge build"), error.userMessage)
        }
        let build = directory.appendingPathComponent(Remote.localOutputDir)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data().write(to: build.appendingPathComponent("top.bit"))
        XCTAssertEqual(try Programmer.bitstreamPath(for: project, root: directory), build.appendingPathComponent("top.bit").path)
    }

    func testProgramRunsTheLoaderWithTheRightArgumentsAndReturnsItsStatus() throws {
        let ok = try fakeLoader(status: 0)
        XCTAssertEqual(try ok.program(bitstream: "t.bit", board: BoardCatalog.lookup("arty-a7-35"), target: .flash, output: { _ in }), 0)
        XCTAssertEqual(try recordedArguments(), "-b arty_a7_35t -f t.bit")

        let failing = try fakeLoader(status: 3)
        XCTAssertEqual(try failing.program(bitstream: "t.bit", board: nil, target: .sram, output: { _ in }), 3)
    }

    func testDetectReportsWhatTheLoaderSaw() throws {
        let loader = try fakeLoader(status: 0, output: "found Xilinx xc7a35t")
        let result = try loader.detect(board: BoardCatalog.lookup("basys3"))
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("xc7a35t"))
        XCTAssertEqual(try recordedArguments(), "-b basys3 --detect")
    }

    func testDoctorCheckSaysHowToInstallWhenMissing() throws {
        let missing = Programmer.check(locate: { nil })
        XCTAssertEqual(missing.level, .fail)
        XCTAssertTrue(missing.detail.contains("brew install openfpgaloader"))

        let loader = try fakeLoader()
        let present = Programmer.check(locate: { loader })
        XCTAssertEqual(present.level, .ok)
        XCTAssertEqual(present.detail, "openFPGALoader v9.9.9")
    }
}
