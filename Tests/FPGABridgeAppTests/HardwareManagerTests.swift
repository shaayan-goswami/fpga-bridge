import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// A board that answers however the test says, and records what it was asked to program.
final class FakeHardware: HardwareBackend, @unchecked Sendable {
    let isDemo = false
    private let lock = NSLock()
    private var _programmed: [(path: String, persist: Bool, board: String?)] = []

    var devices: [Programmer.Device] = [Programmer.Device(idcode: "0x362d093", family: "artix a7 35t", model: "xc7a35")]
    var detectError: Error?
    var programStatus: Int32 = 0
    var programOutput: [String] = []

    var programmed: [(path: String, persist: Bool, board: String?)] { lock.withLock { _programmed } }

    func detect(board: Board?) async throws -> [Programmer.Device] {
        if let detectError { throw detectError }
        return devices
    }

    func program(bitstream: String, board: Board?, persist: Bool, log: @escaping @Sendable (String) -> Void) async -> Int32 {
        lock.withLock { _programmed.append((bitstream, persist, board?.id)) }
        programOutput.forEach(log)
        return programStatus
    }
}

@MainActor
final class HardwareManagerTests: XCTestCase {
    func makeManager(_ hardware: FakeHardware) -> (HardwareManager, () -> [ConsoleLine]) {
        let manager = HardwareManager(backend: hardware)
        var lines: [ConsoleLine] = []
        manager.console = { text, kind in lines.append(ConsoleLine(text: text, kind: kind)) }
        return (manager, { lines })
    }

    func testOpeningATargetListsTheDevicesNamedLikeVivado() async {
        let (manager, lines) = makeManager(FakeHardware())
        XCTAssertEqual(manager.target, .closed)
        await manager.openTarget(board: nil)
        XCTAssertEqual(manager.target, .open)
        XCTAssertEqual(manager.devices.map(\.name), ["xc7a35t_0"])
        XCTAssertEqual(manager.selected?.name, "xc7a35t_0", "the only device is selected")
        XCTAssertEqual(lines().first?.text, "open_hw_target")
        XCTAssertEqual(lines().first?.kind, .command)
    }

    func testNoBoardGivesAnErrorThatSaysWhatToCheck() async {
        let hardware = FakeHardware()
        hardware.devices = []
        let (manager, lines) = makeManager(hardware)
        await manager.openTarget(board: nil)
        guard case .failed(let reason) = manager.target else { return XCTFail("\(manager.target)") }
        XCTAssertTrue(reason.contains("USB cable") && reason.contains("power switch"), reason)
        XCTAssertTrue(lines().contains { $0.kind == .error })
        XCTAssertTrue(manager.devices.isEmpty)
    }

    func testAMissingLoaderSaysHowToInstallIt() async {
        let hardware = FakeHardware()
        hardware.detectError = ProgrammerError.notInstalled
        let (manager, _) = makeManager(hardware)
        await manager.openTarget(board: nil)
        guard case .failed(let reason) = manager.target else { return XCTFail("\(manager.target)") }
        XCTAssertTrue(reason.contains("brew install openfpgaloader"), reason)
    }

    func testProgrammingRecordsTheResultAndPassesTheTargetThrough() async {
        let hardware = FakeHardware()
        hardware.programOutput = ["Open file DONE\n", "Load SRAM: [=====      ] 32.00%\r", "Load SRAM: [==========] 100.00%\n", "Done\n"]
        let (manager, lines) = makeManager(hardware)
        await manager.openTarget(board: nil)

        let ok = await manager.program(bitstream: "/tmp/a.bit", board: BoardCatalog.lookup("basys3"), kind: .device)
        XCTAssertTrue(ok)
        guard case .programmed(_, let persistent) = manager.status(of: manager.devices[0]) else { return XCTFail() }
        XCTAssertFalse(persistent)
        XCTAssertEqual(hardware.programmed.count, 1)
        XCTAssertEqual(hardware.programmed[0].path, "/tmp/a.bit")
        XCTAssertFalse(hardware.programmed[0].persist)
        XCTAssertEqual(hardware.programmed[0].board, "basys3")

        let text = lines().map(\.text)
        XCTAssertTrue(text.contains("program_hw_devices [get_hw_devices xc7a35t_0]"), "\(text)")
        XCTAssertTrue(text.contains("Open file DONE"))
        XCTAssertFalse(text.contains { $0.contains("32.00%") }, "intermediate progress is dropped")
        XCTAssertTrue(text.contains { $0.contains("100.00%") })
        XCTAssertEqual(text.last, "INFO: programmed xc7a35t_0")
        XCTAssertFalse(manager.isProgramming)
    }

    func testConfigurationMemoryIsWrittenAsFlash() async {
        let hardware = FakeHardware()
        let (manager, _) = makeManager(hardware)
        await manager.openTarget(board: nil)
        await manager.program(bitstream: "/tmp/a.bit", board: nil, kind: .memory)
        XCTAssertTrue(hardware.programmed[0].persist)
        guard case .programmed(_, let persistent) = manager.status(of: manager.devices[0]) else { return XCTFail() }
        XCTAssertTrue(persistent)
    }

    func testAFailedProgramIsReportedAndLeavesTheTargetOpen() async {
        let hardware = FakeHardware()
        hardware.programStatus = 1
        let (manager, lines) = makeManager(hardware)
        await manager.openTarget(board: nil)
        let ok = await manager.program(bitstream: "/tmp/a.bit", board: nil, kind: .device)
        XCTAssertFalse(ok)
        XCTAssertEqual(manager.status(of: manager.devices[0]), .failed)
        XCTAssertEqual(manager.target, .open)
        XCTAssertTrue(lines().contains { $0.kind == .error && $0.text.contains("failed") })
        XCTAssertFalse(manager.isProgramming)
    }

    func testProgrammingNeedsASelectedDevice() async {
        let hardware = FakeHardware()
        let (manager, _) = makeManager(hardware)
        let ok = await manager.program(bitstream: "/tmp/a.bit", board: nil, kind: .device)
        XCTAssertFalse(ok, "no target is open")
        XCTAssertTrue(hardware.programmed.isEmpty)
    }

    func testClosingTheTargetForgetsTheDevices() async {
        let (manager, _) = makeManager(FakeHardware())
        await manager.openTarget(board: nil)
        manager.closeTarget()
        XCTAssertEqual(manager.target, .closed)
        XCTAssertTrue(manager.devices.isEmpty)
        XCTAssertNil(manager.selectedID)
    }

    func testTheManagerKeepsItsOwnLogForAWindowWithNoConsole() async {
        let hardware = FakeHardware()
        hardware.programOutput = ["Open file DONE\n", "Done\n"]
        let manager = HardwareManager(backend: hardware)   // no console connected, as in the standalone window
        await manager.openTarget(board: nil)
        await manager.program(bitstream: "/tmp/a.bit", board: nil, kind: .device)
        let text = manager.lines.map(\.text)
        XCTAssertEqual(text.first, "open_hw_target")
        XCTAssertTrue(text.contains("Open file DONE") && text.contains("Done"), "\(text)")
        XCTAssertEqual(text.last, "INFO: programmed xc7a35t_0")
    }

    func testAFailureIsInTheLogWithoutAnyConsole() async {
        let hardware = FakeHardware()
        hardware.detectError = ProgrammerError.notInstalled
        let manager = HardwareManager(backend: hardware)
        await manager.openTarget(board: nil)
        XCTAssertTrue(manager.lines.contains { $0.kind == .error && $0.text.contains("brew install openfpgaloader") }, "\(manager.lines.map(\.text))")
    }

    func testTheProgramSheetBelongsToTheWindowThatAskedForIt() {
        let manager = HardwareManager(backend: FakeHardware())
        manager.present(.memory, host: "standalone")
        XCTAssertEqual(manager.sheet, .memory)
        XCTAssertEqual(manager.sheetHost, "standalone", "the main window must not also show it")
        manager.present(.device, host: "main")
        XCTAssertEqual(manager.sheetHost, "main")
    }

    // MARK: Through the app model

    func testTheFlowNavigatorItemOpensTheHardwareManagerTab() throws {
        let model = AppModel(backend: DemoBackend(speed: 0), hardware: FakeHardware(), persist: false)
        model.openExampleProject()
        XCTAssertTrue(FlowItem.openHardwareManager.isAvailable)
        model.perform(.openHardwareManager)
        XCTAssertEqual(model.selectedTab, .hardware)
        XCTAssertEqual(model.title(of: .hardware), "Hardware Manager")
        model.close(.hardware)
        XCTAssertFalse(model.openTabs.contains(.hardware))
    }

    func testHardwareMessagesLandInTheTclConsole() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), hardware: FakeHardware(), persist: false)
        model.openExampleProject()
        await model.hardware.openTarget(board: model.projectBoard)
        XCTAssertTrue(model.tclLines.contains { $0.text == "open_hw_target" })
        XCTAssertTrue(model.tclLines.contains { $0.text.contains("xc7a35t_0") })
    }

    func testTheDefaultBitstreamIsTheProjectsBuildOutput() throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        XCTAssertEqual(model.defaultBitstreamPath, "", "no project")
        model.openExampleProject()
        XCTAssertTrue(model.defaultBitstreamPath.hasSuffix("/build/\(model.project?.top ?? "?").bit"), model.defaultBitstreamPath)
    }
}
