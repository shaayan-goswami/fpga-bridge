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
        XCTAssertEqual(Programmer.arguments(bitstream: "x.bit", board: nil, target: .sram), ["-c", "digilent", "x.bit"],
                       "the default cable finds nothing on a Digilent board, so name it")
    }

    func testEveryBoardHasAUniqueLoaderName() {
        let names = BoardCatalog.all.compactMap(\.loaderName)
        XCTAssertEqual(names.count, BoardCatalog.all.count)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0 == $0.lowercased() && !$0.contains("-") }, "openFPGALoader names use underscores")
        // Checked against `openFPGALoader --list-boards` (v1.1.1).
        XCTAssertEqual(BoardCatalog.lookup("cmod-a7-35")?.loaderName, "cmoda7_35t")
        XCTAssertEqual(BoardCatalog.lookup("cmod-a7-15")?.loaderName, "cmoda7_15t")
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

    /// What openFPGALoader v1.1.1 printed for a Basys 3.
    private let basys3Detect = """
        empty
        Jtag frequency : requested 6.00MHz    -> real 6.00MHz
        index 0:
        \tidcode 0x362d093
        \tmanufacturer xilinx
        \tfamily artix a7 35t
        \tmodel  xc7a35
        \tirlength 6
        """

    func testDetectParsesTheChipsOnTheChain() throws {
        let loader = try fakeLoader(status: 0, output: basys3Detect)
        let devices = try loader.detect(board: BoardCatalog.lookup("basys3"))
        XCTAssertEqual(devices, [Programmer.Device(idcode: "0x362d093", family: "artix a7 35t", model: "xc7a35")])
        XCTAssertEqual(try recordedArguments(), "-b basys3 --detect")
        XCTAssertEqual(Programmer.boards(matching: devices[0]).map(\.id).sorted(), ["arty-a7-35", "basys3", "cmod-a7-35"],
                       "the chip alone can't tell these boards apart, so all three are offered")
    }

    func testDetectingNothingIsAnEmptyListNotAnError() throws {
        // openFPGALoader exits 0 when no chip answers.
        let loader = try fakeLoader(status: 0, output: "empty\nJtag frequency : requested 6.00MHz")
        XCTAssertEqual(try loader.detect(), [])
        XCTAssertEqual(try recordedArguments(), "-c digilent --detect")
    }

    func testDetectThrowsWhenTheLoaderFails() throws {
        let loader = try fakeLoader(status: 1, output: "unable to open ftdi device")
        XCTAssertThrowsError(try loader.detect()) { XCTAssertTrue($0.userMessage.contains("unable to open ftdi device")) }
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
