import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// The Timing window: Report Timing Summary opens it, selecting a path selects it in every design window, and
/// Schematic (F4) on a path draws just the path.
@MainActor
final class TimingWindowAppTests: ExampleSandboxTestCase {
    func until(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Two flip-flops through a LUT; the LUT's output also reaches a third flip-flop, which isn't on the path.
    static func design(_ stage: DesignStage, timed: Bool = true) -> DesignSnapshot {
        let cells = ["a_reg", "lut", "b_reg", "c_reg"].map { DesignCell(name: $0, type: $0 == "lut" ? "LUT2" : "FDRE", isPrimitive: true) }
        let pins = [DesignPin(name: "a_reg/C", direction: "IN", isClock: true), DesignPin(name: "a_reg/Q", direction: "OUT"),
                    DesignPin(name: "lut/I0", direction: "IN"), DesignPin(name: "lut/O", direction: "OUT"),
                    DesignPin(name: "b_reg/D", direction: "IN"), DesignPin(name: "c_reg/D", direction: "IN")]
        let nets = [DesignNet(name: "q", type: "SIGNAL", endpoints: [NetEndpoint(name: "a_reg/Q", isPort: false), NetEndpoint(name: "lut/I0", isPort: false)]),
                    DesignNet(name: "o", type: "SIGNAL", endpoints: [NetEndpoint(name: "lut/O", isPort: false), NetEndpoint(name: "b_reg/D", isPort: false),
                                                                    NetEndpoint(name: "c_reg/D", isPort: false)])]
        var snapshot = DesignSnapshot(stage: stage, info: DesignInfo(stage: stage.rawValue, top: "top"), cells: cells, ports: [], pins: pins, nets: nets)
        if timed && stage != .rtl {
            snapshot.timing = TimingPathSet.parse(paths: """
                #ID\tDELAY_TYPE\tGROUP\tSLACK\tLOGIC_LEVELS\tSTARTPOINT_PIN\tENDPOINT_PIN\tSTARTPOINT_CLOCK\tENDPOINT_CLOCK
                1\tmax\tclk\t-0.500\t1\ta_reg/C\tb_reg/D\tclk\tclk
                2\tmax\tclk\t1.000\t0\ta_reg/C\tlut/I0\tclk\tclk
                3\tmin\tclk\t0.100\t1\ta_reg/C\tb_reg/D\tclk\tclk
                """, elements: """
                1\tpin\ta_reg/Q\n1\tpin\tlut/I0\n1\tpin\tlut/O\n1\tpin\tb_reg/D
                1\tnet\tq\n1\tnet\to\n1\tcell\ta_reg\n1\tcell\tlut\n1\tcell\tb_reg
                3\tnet\tq\n3\tnet\to\n3\tnet\tnot_in_this_design\n3\tcell\ta_reg\n3\tcell\tlut\n3\tcell\tb_reg
                """)
        }
        return snapshot
    }

    func built(timed: Bool = true, reports: [String] = [BuildSummary.timingReport, "synth_timing_summary.rpt"]) async throws -> AppModel {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        backend.outcome.designs = [.rtl: Self.design(.rtl), .synth: Self.design(.synth, timed: timed), .impl: Self.design(.impl, timed: timed)]
        backend.outcome.reports = reports.map {
            ReportFile(run: DesignReportKind.stage(ofFile: $0) == .impl ? .implementation : .synthesis, name: $0, text: "report \($0)")
        }
        model.run(.bitstream)
        try await until("the build") { !model.isRunning && model.designs[.impl] != nil }
        return model
    }

    // MARK: Opening it

    func testReportTimingSummaryOpensTheTimingWindow() async throws {
        let model = try await built()
        model.perform(.reportTimingSummary, stage: .impl)
        XCTAssertEqual(model.consoleTab, .timing)
        XCTAssertTrue(model.consoleVisible)
        XCTAssertEqual(model.activeDesign, .impl)
        XCTAssertEqual(model.timingStage, .impl)
        XCTAssertTrue(model.tclLines.contains { $0.text.hasPrefix("report_timing_summary") }, "the Tcl it stands for is echoed")
        XCTAssertEqual(model.timingSummaryReport(for: .impl)?.fileName, "timing_summary.rpt")
        XCTAssertEqual(model.timingSummaryReport(for: .synth)?.fileName, "synth_timing_summary.rpt")
    }

    func testWithoutTimingResultsTheReportIsShownAsBefore() async throws {
        let model = try await built(timed: false, reports: [])
        model.perform(.reportTimingSummary, stage: .impl)
        XCTAssertNotEqual(model.consoleTab, .timing)
        XCTAssertNotNil(model.errorMessage, "says how to get the report")
    }

    func testTheElaboratedDesignHasNoTiming() async throws {
        let model = try await built()
        model.open(.design(.rtl))
        XCTAssertNil(model.timingStage)
        model.open(.design(.synth))
        XCTAssertEqual(model.timingStage, .synth)
        XCTAssertEqual(model.timingPaths(for: .synth).paths.count, 3)
    }

    // MARK: Selecting a path

    func testSelectingAPathSelectsItsCellsAndNets() async throws {
        let model = try await built()
        model.showTimingWindow(.impl)
        let path = try XCTUnwrap(model.timingPaths(for: .impl).path(1))
        model.selectTimingPath(path, in: .impl)
        XCTAssertEqual(model.designSelection, [.cell("a_reg"), .net("q"), .cell("lut"), .net("o"), .cell("b_reg")])
        XCTAssertEqual(model.shownTimingPath?.id, 1, "Properties shows the path")
        XCTAssertTrue(model.propertiesShowsDesign)

        model.select(.cell("c_reg"))
        XCTAssertNil(model.shownTimingPath, "selecting something else shows that object instead")
    }

    func testObjectsTheDesignDoesntHaveAreLeftOut() async throws {
        let model = try await built()
        let hold = try XCTUnwrap(model.timingPaths(for: .impl).path(3))
        model.selectTimingPath(hold, in: .impl)
        XCTAssertFalse(model.designSelection.contains(.net("not_in_this_design")))
        XCTAssertEqual(model.shownTimingPath?.id, 3)
    }

    func testAPathOfTheOtherDesignIsNotShown() async throws {
        let model = try await built()
        let path = try XCTUnwrap(model.timingPaths(for: .synth).path(1))
        model.selectTimingPath(path, in: .synth)
        XCTAssertEqual(model.activeDesign, .synth, "selecting a path opens its design")
        model.open(.design(.impl))
        XCTAssertNil(model.shownTimingPath)
    }

    // MARK: Schematic

    func testSchematicOfAPathDrawsJustItsCells() async throws {
        let model = try await built()
        let path = try XCTUnwrap(model.timingPaths(for: .impl).path(1))
        model.selectTimingPath(path, in: .impl)
        model.schematicOfSelection()
        XCTAssertEqual(model.schematicSpecs[.impl]?.only, ["a_reg", "lut", "b_reg"], "not c_reg, which net o also reaches")
        XCTAssertEqual(model.selectedTab, .schematic(.impl))

        // The same nets selected by hand draw everything they reach, as before.
        model.select([.net("o")])
        model.schematicOfSelection()
        XCTAssertEqual(model.schematicSpecs[.impl]?.only, ["lut", "b_reg", "c_reg"])
    }

    func testSchematicFromThePathsTableSelectsThePath() async throws {
        let model = try await built()
        let path = try XCTUnwrap(model.timingPaths(for: .impl).path(1))
        model.open(.design(.impl))
        model.schematicOfTimingPath(path, in: .impl)
        XCTAssertEqual(model.shownTimingPath?.id, 1)
        XCTAssertEqual(model.schematicSpecs[.impl]?.only, ["a_reg", "lut", "b_reg"])
    }

    // MARK: The paths table

    func testThePathsTableSortsByVivadosColumns() {
        let set = TimingPathSet.parse(paths: """
            #ID\tDELAY_TYPE\tGROUP\tSLACK\tLOGIC_LEVELS\tSTARTPOINT_PIN
            1\tmax\tclk\t0.5\t3\tb/C
            2\tmax\tclk\t-1.0\t1\ta/C
            3\tmax\tclk\t\t2\tc/C
            4\tmax\tclk\t0.5\t1\td/C
            """)
        XCTAssertEqual(set.paths.sorted(using: TimingPathOrder(.slack)).map(\.id), [2, 1, 4, 3], "no requirement sorts as infinite slack")
        XCTAssertEqual(set.paths.sorted(using: TimingPathOrder(.slack, order: .reverse)).map(\.id), [3, 1, 4, 2], "ties keep the build's order")
        XCTAssertEqual(set.paths.sorted(using: TimingPathOrder(.levels)).map(\.id), [2, 4, 3, 1])
        XCTAssertEqual(set.paths.sorted(using: TimingPathOrder(.from)).map(\.id), [2, 1, 3, 4])
        XCTAssertEqual(formatNs(nil, missing: "inf"), "inf")
        XCTAssertEqual(formatNs(-2.0441), "-2.044")
    }

    func testCopyingARowGivesVivadosColumns() throws {
        let path = try XCTUnwrap(Self.design(.impl).timing.path(1))
        let columns = TimingPathsTable.copyLine(path).components(separatedBy: "\t")
        XCTAssertEqual(columns.count, 15)
        XCTAssertEqual(Array(columns.prefix(4)), ["Path 1", "-0.500", "1", "2"])
        XCTAssertEqual(columns[5], "a_reg/C")
        XCTAssertEqual(columns[6], "b_reg/D")
    }
}
