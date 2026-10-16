import XCTest
@testable import FPGABridgeCore

final class SimulatorTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tb"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, to path: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    var project: Project {
        Project(name: "p", top: "counter", part: "xc7a35tcpg236-1", sources: ["src"], constraints: [], simulationSources: ["tb"])
    }

    let dut = """
    module counter(input clk, input rst, output reg [3:0] count);
        always @(posedge clk) if (rst) count <= 0; else count <= count + 1;
    endmodule
    """

    func testbench(body: String = "#100 $display(\"count=%0d\", count); $finish;", extra: String = "") -> String {
        """
        `timescale 1ns / 1ps
        module tb;
            reg clk = 0, rst = 1;
            wire [3:0] count;
            counter dut (.clk(clk), .rst(rst), .count(count));
            always #5 clk = ~clk;
            \(extra)
            initial begin #12 rst = 0; \(body) end
        endmodule
        """
    }

    // MARK: Planning

    func testThePlanPicksTheTestbenchAndOrdersDesignBeforeSimulationFiles() throws {
        try write(dut, to: "src/counter.v")
        try write(testbench(), to: "tb/tb.v")
        let plan = try Simulator.plan(project: project, root: root)
        XCTAssertEqual(plan.top, "tb", "the module nothing instantiates, among the simulation sources")
        XCTAssertEqual(plan.sources.map { ($0 as NSString).lastPathComponent }, ["counter.v", "tb.v"])
        XCTAssertTrue(plan.sources.allSatisfy { $0.hasPrefix("/") })
        XCTAssertTrue(plan.dumpsWaveform)
        XCTAssertEqual(plan.directory.path, root.appendingPathComponent("build/sim").path)
        XCTAssertEqual(Array(plan.compileArguments.prefix(5)), ["-g2012", "-s", "tb", "-s", "__fpgabridge_dump"])
        XCTAssertTrue(plan.compileArguments.contains("-I"))
        XCTAssertTrue(plan.compileArguments.last == plan.dumpModulePath, "the dump module is compiled last")
        XCTAssertTrue(plan.dumpModule.contains("$dumpvars(0, tb)"))
    }

    func testATestbenchThatDumpsItsOwnWaveformIsLeftAlone() throws {
        try write(dut, to: "src/counter.v")
        try write(testbench(extra: "initial begin $dumpfile(\"mine.vcd\"); $dumpvars; end"), to: "tb/tb.v")
        let plan = try Simulator.plan(project: project, root: root)
        XCTAssertFalse(plan.dumpsWaveform)
        XCTAssertFalse(plan.compileArguments.contains("__fpgabridge_dump"))
    }

    func testTheTopCanBeChosenByTheProjectOrTheCaller() throws {
        try write(dut, to: "src/counter.v")
        try write(testbench(), to: "tb/tb.v")
        try write("module other_tb; endmodule", to: "tb/other_tb.v")
        XCTAssertEqual(try Simulator.plan(project: project, root: root).top, "other_tb", "first by name among the roots")
        var pinned = project
        pinned.simulationTop = "tb"
        XCTAssertEqual(try Simulator.plan(project: pinned, root: root).top, "tb")
        XCTAssertEqual(try Simulator.plan(project: pinned, root: root, top: "other_tb").top, "other_tb", "the caller wins")
        XCTAssertThrowsError(try Simulator.plan(project: project, root: root, top: "a b"))
    }

    func testAProjectWithoutATestbenchSaysSo() throws {
        try write(dut, to: "src/counter.v")
        var noSim = project
        noSim.simulationSources = nil
        XCTAssertThrowsError(try Simulator.plan(project: noSim, root: root)) { error in
            XCTAssertTrue(error.userMessage.contains("no simulation sources"), error.userMessage)
        }
    }

    func testVHDLIsRefusedWithTheFilesNamed() throws {
        try write(dut, to: "src/counter.v")
        try write("entity e is end;", to: "src/e.vhd")
        try write(testbench(), to: "tb/tb.v")
        XCTAssertThrowsError(try Simulator.plan(project: project, root: root)) { error in
            XCTAssertTrue(error.userMessage.contains("e.vhd"), error.userMessage)
            XCTAssertTrue(error.userMessage.contains("Verilog and SystemVerilog only"))
        }
    }

    func testSimulationTopIsValidatedLikeTheOtherNames() throws {
        var bad = project
        bad.simulationTop = "tb; rm -rf"
        XCTAssertThrowsError(try bad.validate())
        var ok = project
        ok.simulationTop = "tb"
        XCTAssertNoThrow(try ok.validate())
    }

    // MARK: Helpers

    func testFinishTimeIsReadAsAHumanDuration() {
        XCTAssertEqual(Simulator.finishTime(in: "x\n$finish called at 2000100000 (1ps)\n"), "2.0001 ms")
        XCTAssertEqual(Simulator.finishTime(in: "$finish called at 1000 (1ns)"), "1 µs")
        XCTAssertEqual(Simulator.finishTime(in: "$finish called at 112 (1ns)"), "112 ns")
        XCTAssertEqual(Simulator.finishTime(in: "$finish called at 5 (1s)"), "5 s")
        XCTAssertNil(Simulator.finishTime(in: "no finish here"))
    }

    func testLocateNeedsBothProgramsAndTheCheckSaysHowToInstall() throws {
        XCTAssertNil(Simulator.locate(path: root.path, searchPaths: []))
        for name in [Simulator.compilerName, Simulator.runnerName] {
            let path = root.appendingPathComponent(name)
            try "#!/bin/sh\necho 'Icarus Verilog version 99'\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            if name == Simulator.compilerName {
                XCTAssertNil(Simulator.locate(path: root.path, searchPaths: []), "vvp is missing")
            }
        }
        let found = try XCTUnwrap(Simulator.locate(path: root.path, searchPaths: []))
        XCTAssertEqual(Simulator.check(locate: { found }).level, .ok)
        XCTAssertEqual(Simulator.check(locate: { found }).detail, "Icarus Verilog version 99")

        let missing = Simulator.check(locate: { nil })
        XCTAssertEqual(missing.level, .warn, "building and flashing work without it")
        XCTAssertTrue(missing.detail.contains("brew install icarus-verilog"))
    }

    // MARK: Running (needs Icarus Verilog installed)

    func realSimulator() throws -> Simulator {
        try XCTSkipUnless(Simulator.locate() != nil, "Icarus Verilog isn't installed")
        return try Simulator.require()
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func add(_ s: String) { lock.withLock { text += s } }
        var value: String { lock.withLock { text } }
    }

    func testASimulationRunsAndLeavesAWaveform() throws {
        let simulator = try realSimulator()
        try write(dut, to: "src/counter.v")
        try write(testbench(), to: "tb/tb.v")
        let log = Log()
        let result = try simulator.simulate(try Simulator.plan(project: project, root: root), stop: Shell.StopFlag(), output: { log.add($0) })
        XCTAssertTrue(result.succeeded, log.value)
        XCTAssertEqual(result.stage, .run)
        XCTAssertTrue(log.value.contains("count="), log.value)
        XCTAssertEqual(result.finishedAt, "112 ns")
        let waveform = try XCTUnwrap(result.waveform)
        XCTAssertEqual(waveform.lastPathComponent, "sim.vcd")
        XCTAssertTrue(try String(contentsOf: waveform, encoding: .utf8).contains("$var"), "a real VCD")
        XCTAssertEqual(waveform.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       root.appendingPathComponent("build/sim").resolvingSymlinksInPath().path)
    }

    func testACompileErrorStopsBeforeRunning() throws {
        let simulator = try realSimulator()
        try write(dut, to: "src/counter.v")
        try write("module tb; this is not verilog; endmodule", to: "tb/tb.v")
        let log = Log()
        let result = try simulator.simulate(try Simulator.plan(project: project, root: root), stop: Shell.StopFlag(), output: { log.add($0) })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stage, .compile)
        XCTAssertNil(result.waveform)
        XCTAssertTrue(log.value.contains("tb.v"), "the error names the file: \(log.value)")
    }

    func testATestbenchThatNeverFinishesTimesOut() throws {
        let simulator = try realSimulator()
        try write(dut, to: "src/counter.v")
        try write(testbench(body: ""), to: "tb/tb.v")
        let started = Date()
        let result = try simulator.simulate(try Simulator.plan(project: project, root: root), stop: Shell.StopFlag(), timeout: 1, output: { _ in })
        XCTAssertTrue(result.timedOut, "status \(result.status)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testStoppingASimulationEndsIt() throws {
        let simulator = try realSimulator()
        try write(dut, to: "src/counter.v")
        try write(testbench(body: ""), to: "tb/tb.v")
        let stop = Shell.StopFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { stop.set() }
        let result = try simulator.simulate(try Simulator.plan(project: project, root: root), stop: stop, timeout: 60, output: { _ in })
        XCTAssertTrue(result.wasStopped, "status \(result.status)")
    }

    func testAStaleWaveformIsNotReportedForANewRun() throws {
        let simulator = try realSimulator()
        try write(dut, to: "src/counter.v")
        try write(testbench(), to: "tb/tb.v")
        let sim = root.appendingPathComponent("build/sim")
        try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
        try "old".write(to: sim.appendingPathComponent("stale.vcd"), atomically: true, encoding: .utf8)
        let result = try simulator.simulate(try Simulator.plan(project: project, root: root), stop: Shell.StopFlag(), output: { _ in })
        XCTAssertEqual(result.waveform?.lastPathComponent, "sim.vcd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sim.appendingPathComponent("stale.vcd").path))
    }
}
