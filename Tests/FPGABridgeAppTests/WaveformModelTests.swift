import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

@MainActor
final class WaveformModelTests: ExampleSandboxTestCase {
    let vcd = """
    $timescale 1ns $end
    $scope module tb $end
    $var reg 1 ! clk $end
    $var reg 8 " count [7:0] $end
    $var integer 32 # errors [31:0] $end
    $scope module dut $end
    $var wire 1 ! clk $end
    $var reg 1 $ tick $end
    $var parameter 32 % WIDTH $end
    $upscope $end
    $upscope $end
    $enddefinitions $end
    #0
    0!
    b0 "
    b0 #
    0$
    #1000
    1!
    b1 "
    #2000
    0!
    1$
    #4000
    1!
    b11111111 "
    0$
    #10000
    0!
    """

    func makeModel() throws -> WaveformModel {
        let model = WaveformModel()
        model.adopt(try Waveform.parse(vcd), from: nil)
        return model
    }

    func names(_ model: WaveformModel) -> [String] { model.shown.compactMap { model.waveform?.signals[$0].name } }

    func testTheDefaultSignalsAreTheTestbenchsOwnPlusTheInstancesNewOnes() throws {
        let model = try makeModel()
        XCTAssertEqual(names(model), ["clk", "count [7:0]", "tick"],
                       "no integers or parameters, and the instance's clk is the same net as the testbench's")
    }

    func testFitShowsTheWholeRunWithAMarginAtTheEnd() throws {
        let model = try makeModel()
        XCTAssertEqual(model.viewStart, 0)
        XCTAssertEqual(model.viewEnd, 10_000 * 1.02, accuracy: 0.001)
    }

    func testZoomingKeepsTheTickUnderTheAnchorStill() throws {
        let model = try makeModel()
        model.zoom(by: 2, anchor: 0.5)
        XCTAssertEqual(model.span, 5_100, accuracy: 0.001)
        XCTAssertEqual(model.viewStart + 0.5 * model.span, 5_100, accuracy: 0.001, "the middle stays in the middle")

        model.fit()
        model.zoom(by: 4, anchor: 0.25)
        XCTAssertEqual(model.viewStart + 0.25 * model.span, 10_200 * 0.25, accuracy: 0.001, "and so does a quarter of the way in")
    }

    func testZoomHasLimits() throws {
        let model = try makeModel()
        for _ in 0..<40 { model.zoom(by: 2) }
        XCTAssertGreaterThanOrEqual(model.span, 10, "can't zoom in past a few ticks")
        for _ in 0..<40 { model.zoom(by: 0.5) }
        XCTAssertLessThanOrEqual(model.span, 10_000 * 4, "or out to nothing")
        model.zoom(by: 0)
        model.zoom(by: -1)
        XCTAssertTrue(model.span.isFinite && model.span > 0)
    }

    func testPanStaysInsideTheRun() throws {
        let model = try makeModel()
        model.zoom(by: 4)
        model.pan(byTicks: -50_000)
        XCTAssertEqual(model.viewStart, 0, "not before time zero")
        let span = model.span
        model.pan(byTicks: 1_000_000)
        XCTAssertEqual(model.viewEnd, 10_000 * 1.02, accuracy: 0.001, "not past the end")
        XCTAssertEqual(model.span, span, accuracy: 0.001, "panning doesn't change the zoom")
    }

    func testTheCursorIsClampedAndGivesValues() throws {
        let model = try makeModel()
        XCTAssertNil(model.cursor)
        XCTAssertNil(model.displayValue(of: 1))
        model.setCursor(tick: -500)
        XCTAssertEqual(model.cursor, 0)
        model.setCursor(tick: 99_999_999)
        XCTAssertEqual(model.cursor, 10_000)
        model.setCursor(tick: 4_500)
        let count = model.shown[1]
        XCTAssertEqual(model.displayValue(of: count), "ff", "hex by default")
        model.setRadix(.decimal, for: count)
        XCTAssertEqual(model.displayValue(of: count), "255")
        model.setRadix(nil, for: count)
        model.defaultRadix = .binary
        XCTAssertEqual(model.displayValue(of: count), "11111111", "an override beats the default, and clearing it goes back")
    }

    func testStepToTheNextAndPreviousChangeOfTheSelectedSignal() throws {
        let model = try makeModel()
        let tick = model.shown[2]
        model.selected = tick
        model.setCursor(tick: 0)
        model.moveCursorToNextChange(forward: true)
        XCTAssertEqual(model.cursor, 2_000)
        model.moveCursorToNextChange(forward: true)
        XCTAssertEqual(model.cursor, 4_000)
        model.moveCursorToNextChange(forward: true)
        XCTAssertEqual(model.cursor, 4_000, "no later change: stays")
        model.moveCursorToNextChange(forward: false)
        XCTAssertEqual(model.cursor, 2_000)
    }

    func testSteppingToAChangeOffScreenScrollsToIt() throws {
        let model = try makeModel()
        model.selected = model.shown[0]       // clk changes at 1000, 2000, 4000, 10000
        model.zoom(by: 10, anchor: 0)         // window 0...1020
        model.setCursor(tick: 4_000)
        model.moveCursorToNextChange(forward: true)
        XCTAssertEqual(model.cursor, 10_000)
        XCTAssertTrue(model.viewStart <= 10_000 && 10_000 <= model.viewEnd, "\(model.viewStart)...\(model.viewEnd)")
    }

    func testSignalsCanBeAddedRemovedAndToggled() throws {
        let model = try makeModel()
        let errors = try XCTUnwrap(model.waveform?.signals.first { $0.name == "errors [31:0]" }?.id)
        XCTAssertFalse(model.isShown(errors))
        model.toggle(errors)
        XCTAssertTrue(model.isShown(errors))
        model.show(errors)
        XCTAssertEqual(model.shown.filter { $0 == errors }.count, 1, "no duplicates")
        model.selected = errors
        model.hide(errors)
        XCTAssertNil(model.selected, "removing the selected signal clears the selection")
        model.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(names(model), ["count [7:0]", "tick", "clk"])
    }

    func testLoadingAFileReadsItAndAnErrorSaysWhy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wfm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.vcd")
        try vcd.write(to: good, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("bad.vcd")
        try "not a waveform".write(to: bad, atomically: true, encoding: .utf8)

        let model = WaveformModel()
        await model.load(good)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.source, good)
        XCTAssertEqual(model.waveform?.signals.count, 6)

        await model.load(bad)
        XCTAssertNil(model.waveform, "the old waveform is gone")
        XCTAssertTrue(model.loadError?.contains("isn't a VCD") == true, model.loadError ?? "nil")
        await model.load(dir.appendingPathComponent("missing.vcd"))
        XCTAssertNotNil(model.loadError)

        model.clear()
        XCTAssertNil(model.source)
        XCTAssertNil(model.loadError)
    }

    // MARK: The ruler

    func testNiceStepsAreOneTwoOrFiveTimesAPowerOfTen() {
        XCTAssertEqual(WaveformPainter.niceStep(0.7), 1)
        XCTAssertEqual(WaveformPainter.niceStep(1.5), 2)
        XCTAssertEqual(WaveformPainter.niceStep(3), 5)
        XCTAssertEqual(WaveformPainter.niceStep(7), 10)
        XCTAssertEqual(WaveformPainter.niceStep(130), 200)
        XCTAssertEqual(WaveformPainter.niceStep(0.03), 0.05, accuracy: 1e-12)
        XCTAssertEqual(WaveformPainter.niceStep(0), 1)
    }

    func testMajorTicksAreEvenlySpacedAndInsideTheWindow() throws {
        let waveform = try Waveform.parse(vcd)
        let painter = WaveformPainter(waveform: waveform, rows: [], start: 1_234, end: 6_789, cursor: nil, selected: nil,
                                      rowHeight: 30, radix: { _ in .hex })
        let ticks = painter.majorTicks(width: 1000)
        XCTAssertGreaterThan(ticks.count, 3)
        XCTAssertLessThan(ticks.count, 20)
        XCTAssertTrue(ticks.allSatisfy { $0 >= 1_234 && $0 <= 6_789 })
        let steps = Set(zip(ticks, ticks.dropFirst()).map { $1 - $0 })
        XCTAssertEqual(steps.count, 1, "one step size")
        XCTAssertEqual(WaveformPainter.niceStep(steps.first ?? 0), steps.first, "a round number")
        XCTAssertEqual(painter.x(1_234, 1000), 0, accuracy: 0.001)
        XCTAssertEqual(painter.x(6_789, 1000), 1000, accuracy: 0.001)
    }

    // MARK: Through the app

    func testAFinishedSimulationOpensItsWaveformLikeVivado() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wfa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sim.vcd")
        try vcd.write(to: file, atomically: true, encoding: .utf8)

        let backend = ScriptedSimulation()
        backend.outcome = SimulationOutcome(result: .finished, top: "tb", waveform: file, finishedAt: "10 ns")
        let model = AppModel(backend: DemoBackend(speed: 0), simulation: backend, persist: false)
        model.openExampleProject()
        model.runSimulation()
        for _ in 0..<500 where model.waveform.waveform == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.waveform.waveform)
        XCTAssertEqual(model.selectedTab, .waveform)
        XCTAssertEqual(model.title(of: .waveform), "Waveform")
        XCTAssertEqual(model.waveform.source, file)
    }

    func testAFailedSimulationDoesNotOpenTheWaveformTab() async throws {
        let backend = ScriptedSimulation()
        backend.outcome = SimulationOutcome(result: .failed, top: "tb")
        let model = AppModel(backend: DemoBackend(speed: 0), simulation: backend, persist: false)
        model.openExampleProject()
        model.runSimulation()
        for _ in 0..<300 {
            if case .done = model.simulation.state { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(model.selectedTab, .waveform)
        XCTAssertNil(model.waveform.waveform)
    }

    func testOpeningAnotherProjectClearsTheWaveform() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        model.waveform.adopt(try Waveform.parse(vcd), from: nil)
        model.closeProject()
        XCTAssertNil(model.waveform.waveform)
        XCTAssertTrue(model.waveform.shown.isEmpty)
    }
}
