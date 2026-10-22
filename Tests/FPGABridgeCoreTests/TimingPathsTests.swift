import XCTest
@testable import FPGABridgeCore

/// The timing paths a build saves (see `fpgabridge_timing` in DesignDump.swift), read from what Vivado 2025.2 wrote
/// for demo_top on a Basys 3: as built (Fixtures/design_vivado2025), with the clock tightened to 1.6 ns so 89 setup
/// endpoints fail (timing_fail_vivado2025), and with input and output delays on the switches and LEDs so paths start
/// and end at ports (timing_io_vivado2025). The last two are the routed design re-timed, not rebuilt.
final class TimingPathsTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    func paths(_ fixtureName: String = "design_vivado2025", stage: DesignStage = .impl) throws -> TimingPathSet {
        TimingPathSet.load(stage: stage, from: try fixture(fixtureName))
    }

    // MARK: The paths file

    func testTheWorstSetupAndHoldPathsOfTheImplementedDesign() throws {
        let set = try paths()
        XCTAssertEqual(set.paths.count, 200)
        XCTAssertEqual(set.paths(.setup).count, 100)
        XCTAssertEqual(set.paths(.hold).count, 100)
        let worst = try XCTUnwrap(set.path(1))
        XCTAssertEqual(worst.name, "Path 1")
        XCTAssertEqual(worst.check, .setup)
        XCTAssertEqual(worst.group, "sys_clk")
        XCTAssertEqual(worst.slack, 6.356)
        XCTAssertEqual(worst.requirement, 10.0)
        XCTAssertEqual(worst.dataPathDelay, 3.158)
        XCTAssertEqual(worst.logicDelay, 0.704)
        XCTAssertEqual(worst.netDelay, 2.454)
        XCTAssertEqual(worst.logicLevels, 2)
        XCTAssertEqual(worst.maxFanout, 24)
        XCTAssertEqual(worst.startPoint, "u_tick/count_reg[21]/C")
        XCTAssertEqual(worst.endPoint, "u_tick/count_reg[10]/R")
        XCTAssertEqual(worst.startClock, "sys_clk")
        XCTAssertEqual(worst.endClock, "sys_clk")
        XCTAssertEqual(worst.skew, -0.022)
        XCTAssertEqual(worst.uncertainty, 0.035)
        XCTAssertEqual(worst.exception, "")
        XCTAssertEqual(worst.corner, "Slow")
        XCTAssertEqual(worst.arrivalTime, 8.309)
        XCTAssertEqual(worst.requiredTime, 14.665)
        XCTAssertFalse(worst.isFailing)

        let hold = try XCTUnwrap(set.path(101))
        XCTAssertEqual(hold.check, .hold)
        XCTAssertEqual(hold.slack, 0.131)
        XCTAssertEqual(hold.corner, "Fast")
        XCTAssertNil(hold.uncertainty, "Vivado leaves it empty for hold")
        XCTAssertEqual(hold.logicLevels, 0)
    }

    func testAPathsElementsAreInPathOrder() throws {
        let path = try XCTUnwrap(try paths().path(1))
        XCTAssertEqual(path.pins, ["u_tick/count_reg[21]/Q", "u_tick/count[0]_i_3/I1", "u_tick/count[0]_i_3/O",
                                   "u_tick/count[0]_i_1__0/I0", "u_tick/count[0]_i_1__0/O", "u_tick/count_reg[10]/R"])
        XCTAssertEqual(path.pinsInOrder.first, "u_tick/count_reg[21]/C", "the startpoint's clock pin comes first")
        XCTAssertEqual(path.nets, ["u_tick/count_reg[21]", "u_tick/count[0]_i_3_n_0", "u_tick/count[0]_i_1__0_n_0"])
        XCTAssertEqual(path.cells, ["u_tick/count_reg[21]", "u_tick/count[0]_i_3", "u_tick/count[0]_i_1__0", "u_tick/count_reg[10]"])
        XCTAssertEqual(path.routes, 3)
        XCTAssertEqual(path.ports, [], "the clock port Vivado lists with the path isn't on its data path")
        XCTAssertEqual(path.objects, [.cell("u_tick/count_reg[21]"), .net("u_tick/count_reg[21]"),
                                      .cell("u_tick/count[0]_i_3"), .net("u_tick/count[0]_i_3_n_0"),
                                      .cell("u_tick/count[0]_i_1__0"), .net("u_tick/count[0]_i_1__0_n_0"),
                                      .cell("u_tick/count_reg[10]")])
    }

    func testEveryPathObjectIsInTheDesign() throws {
        for stage in [DesignStage.synth, .impl] {
            let design = try DesignSnapshot.load(stage: stage, from: try fixture("design_vivado2025"))
            XCTAssertEqual(design.timing.paths.count, 200, "the snapshot loads its timing paths")
            for path in design.timing.paths {
                for ref in path.objects { XCTAssertTrue(design.contains(ref), "\(stage) path \(path.id): \(ref)") }
                for pin in path.pinsInOrder { XCTAssertNotNil(design.pins[pin], "\(stage) path \(path.id): pin \(pin)") }
            }
        }
    }

    func testPathsFromAndToPorts() throws {
        let set = try paths("timing_io_vivado2025")
        let fromSwitch = try XCTUnwrap(set.path(9))
        XCTAssertEqual(fromSwitch.startPoint, "sw[8]")
        XCTAssertEqual(fromSwitch.endPoint, "led[8]")
        XCTAssertEqual(fromSwitch.ports, ["sw[8]", "led[8]"])
        XCTAssertTrue(fromSwitch.startIsPort && fromSwitch.endIsPort)
        XCTAssertEqual(fromSwitch.pinsInOrder, fromSwitch.pins, "a port has no clock pin to add")
        XCTAssertEqual(fromSwitch.objects.first, .port("sw[8]"))
        XCTAssertEqual(fromSwitch.objects.last, .port("led[8]"))

        let toLED = try XCTUnwrap(set.path(1))
        XCTAssertEqual(toLED.startPoint, "scan_reg[1]/C")
        XCTAssertEqual(toLED.ports, ["led[1]"])
        XCTAssertEqual(toLED.objects.last, .port("led[1]"))
        XCTAssertEqual(toLED.slack, -13.435)
    }

    func testFailingPathsWorstFirst() throws {
        let set = try paths("timing_fail_vivado2025")
        let failing = set.failing(.setup)
        XCTAssertEqual(failing.count, 89, "the timing summary's 89 failing endpoints, one path each")
        XCTAssertEqual(failing.first?.slack, -2.044)
        XCTAssertEqual(failing.map { $0.slack ?? 0 }, failing.map { $0.slack ?? 0 }.sorted())
        XCTAssertTrue(set.failing(.hold).isEmpty)
    }

    func testTheElaboratedDesignAndOlderBuildsHaveNoPaths() throws {
        XCTAssertTrue(try paths(stage: .rtl).isEmpty)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(TimingPathSet.load(stage: .impl, from: empty).isEmpty)
        XCTAssertTrue(try DesignSnapshot.load(stage: .rtl, from: try fixture("design_vivado2025")).timing.isEmpty)
    }

    func testColumnsAreFoundByTheirHeader() {
        // The same path with its columns in another order, Windows line endings, and an unknown extra column.
        let text = "#ID\tSLACK\tEXTRA\tDELAY_TYPE\tGROUP\tSTARTPOINT_PIN\tENDPOINT_PIN\r\n7\t-0.500\tx\tmax\tclk\ta/C\tb/D\r\n"
        let set = TimingPathSet.parse(paths: text, elements: "7\tcell\ta\r\n7\tnet\tn\r\n7\tcell\tb\r\n")
        let path = set.path(7)
        XCTAssertEqual(path?.slack, -0.5)
        XCTAssertEqual(path?.group, "clk")
        XCTAssertEqual(path?.check, .setup)
        XCTAssertEqual(path?.objects, [.cell("a"), .net("n"), .cell("b")])
        XCTAssertTrue(path?.isFailing == true)
    }

    func testAPathWithoutARequirementIsNotFailing() {
        let set = TimingPathSet.parse(paths: "#ID\tDELAY_TYPE\tGROUP\tSLACK\n1\tmax\t(none)\t\n")
        XCTAssertNil(set.path(1)?.slack)
        XCTAssertFalse(set.path(1)?.isFailing ?? true)
    }

    func testTheScriptWritesWhatTheReaderReads() {
        let tcl = DesignDump.procedures
        XCTAssertTrue(tcl.contains("proc fpgabridge_timing {stage}"))
        XCTAssertTrue(tcl.contains("catch { fpgabridge_timing synth }"))
        XCTAssertTrue(tcl.contains("catch { fpgabridge_timing impl }"))
        XCTAssertFalse(tcl.contains("fpgabridge_timing rtl"), "an elaborated design has no timing")
        XCTAssertTrue(tcl.contains("-delay_type max -max_paths 100 -nworst 1 -sort_by group"))
        XCTAssertTrue(tcl.contains("-delay_type min -max_paths 100 -nworst 1 -sort_by group"))
        for stage in ["synth", "impl"] {
            XCTAssertEqual(DesignDump.timingPathsFile(stage), "\(stage)_timing_paths.tsv")
            XCTAssertEqual(DesignDump.timingElementsFile(stage), "\(stage)_timing_elements.tsv")
            XCTAssertEqual(DesignDump.timingReportsFile(stage), "\(stage)_timing_reports.txt")
        }
        XCTAssertTrue(tcl.contains("out/${stage}_timing_paths.tsv"))
        XCTAssertTrue(tcl.contains("out/${stage}_timing_elements.tsv"))
        XCTAssertTrue(tcl.contains("out/${stage}_timing_reports.txt"))
        XCTAssertTrue(tcl.contains("set props {\(DesignDump.timingPathProperties.joined(separator: " "))}"))
        XCTAssertTrue(tcl.contains("puts $r \"\(TimingPathSet.reportMarker)$id\""), "the marker the reader splits on")
    }

    // MARK: Groups, as the Timing window's tree shows them

    func testPathGroupsByCategory() throws {
        let set = try paths()
        let intra = set.groups(in: .intraClock)
        XCTAssertEqual(intra.map(\.title), ["sys_clk"])
        XCTAssertTrue(set.groups(in: .interClock).isEmpty)
        XCTAssertTrue(set.groups(in: .otherGroups).isEmpty)
        XCTAssertEqual(set.paths(in: intra[0], check: .setup).count, 100)
        XCTAssertEqual(set.paths(in: intra[0], check: .hold).count, 100)
    }

    func testInterClockAndOtherGroups() {
        let text = """
            #ID\tDELAY_TYPE\tGROUP\tSLACK\tSTARTPOINT_CLOCK\tENDPOINT_CLOCK
            1\tmax\tclk_b\t1.0\tclk_a\tclk_b
            2\tmax\t**async_default**\t2.0\tclk_a\tclk_a
            3\tmax\tclk_a\t3.0\tclk_a\tclk_a
            4\tmin\tclk_b\t0.1\tclk_a\tclk_b
            """
        let set = TimingPathSet.parse(paths: text)
        XCTAssertEqual(set.groups(in: .intraClock).map(\.title), ["clk_a"])
        XCTAssertEqual(set.groups(in: .interClock).map(\.title), ["clk_a to clk_b"])
        XCTAssertEqual(set.groups(in: .otherGroups).map(\.title), ["**async_default**: clk_a to clk_a"])
        let inter = set.groups(in: .interClock)[0]
        XCTAssertEqual(set.paths(in: inter, check: .setup).map(\.id), [1])
        XCTAssertEqual(set.paths(in: inter, check: .hold).map(\.id), [4])
    }

    // MARK: Each path's report

    func testTheReportsFileSplitsByPath() throws {
        let set = try paths()
        XCTAssertEqual(Set(set.reports.keys), [1, 2, 101], "the fixture keeps three of the build's reports")
        XCTAssertTrue(set.reports[1]?.hasPrefix("Slack (MET) :") == true)
        XCTAssertFalse(set.reports[1]?.contains("#fpga-bridge") == true)
        XCTAssertFalse(set.reports[1]?.contains("Copyright") == true, "the build leaves out Vivado's repeated header")
    }

    func testAPathReportFromRealVivado() throws {
        let report = try XCTUnwrap(try paths().report(for: 1))
        func item(_ name: String) -> String? { report.summary.first { $0.name == name }?.value }
        XCTAssertEqual(item("Slack (MET)"), "6.356ns  (required time - arrival time)")
        XCTAssertEqual(item("Source"), "u_tick/count_reg[21]/C (rising edge-triggered cell FDRE clocked by sys_clk  {rise@0.000ns fall@5.000ns period=10.000ns})")
        XCTAssertEqual(item("Path Group"), "sys_clk")
        XCTAssertEqual(item("Path Type"), "Setup (Max at Slow Process Corner)")
        XCTAssertEqual(item("Logic Levels"), "2  (LUT5=1 LUT6=1)")
        XCTAssertEqual(report.summary.first { $0.name == "Source Clock Delay      (SCD)" }?.isDetail, true)

        XCTAssertEqual(report.sourceClockPath.count, 10)
        XCTAssertEqual(report.sourceClockPath.first?.delayType, "(clock sys_clk rise edge)")
        XCTAssertEqual(report.sourceClockPath[1].object, .port("clk"))
        XCTAssertEqual(report.sourceClockPath.last?.resource, "u_tick/count_reg[21]/C")

        XCTAssertEqual(report.dataPath.count, 9)
        let launch = report.dataPath[0]
        XCTAssertEqual(launch.location, "SLICE_X3Y16")
        XCTAssertEqual(launch.delayType, "FDRE (Prop_fdre_C_Q)")
        XCTAssertEqual(launch.increment, 0.456)
        XCTAssertEqual(launch.total, 5.607)
        XCTAssertEqual(launch.edge, "r")
        XCTAssertEqual(launch.object, .pin("u_tick/count_reg[21]/Q"))
        XCTAssertEqual(report.dataPath[1].delayType, "net (fo=2, routed)")
        XCTAssertEqual(report.dataPath[1].object, .net("u_tick/count_reg[21]"))
        XCTAssertEqual(report.dataPath[2].object, .pin("u_tick/count[0]_i_3/I1"))
        XCTAssertEqual(report.dataPath[2].increment, nil)
        XCTAssertEqual(report.dataPath.last?.total, nil)

        XCTAssertEqual(report.destinationClockPath.first?.total, 10.0)
        XCTAssertEqual(report.destinationClockPath.first { $0.delayType == "clock pessimism" }?.increment, 0.274)
        XCTAssertEqual(report.destinationClockPath.first { $0.delayType == "clock uncertainty" }?.increment, -0.035)
        let check = try XCTUnwrap(report.destinationClockPath.last)
        XCTAssertEqual(check.delayType, "FDRE (Setup_fdre_C_R)")
        XCTAssertEqual(check.object, .cell("u_tick/count_reg[10]"))
        XCTAssertEqual(report.requiredTime, 14.665)
        XCTAssertEqual(report.arrivalTime, -8.309)
        XCTAssertEqual(report.slack, 6.356)
    }

    func testAHoldReport() throws {
        let report = try XCTUnwrap(try paths().report(for: 101))
        XCTAssertEqual(report.summary.first?.name, "Slack (MET)")
        XCTAssertEqual(report.dataPath.map(\.resource), ["meta_reg[0]/Q", "meta[0]", "stable_reg[0]/D"])
        XCTAssertEqual(report.destinationClockPath.last?.delayType, "FDRE (Hold_fdre_C_D)")
        XCTAssertEqual(report.slack, 0.131)
    }

    func testAReportFromAnInputPortHasNoSourceClockPath() throws {
        let report = try XCTUnwrap(try paths("timing_io_vivado2025").report(for: 9))
        XCTAssertEqual(report.summary.first?.name, "Slack (VIOLATED)")
        XCTAssertEqual(report.summary.first { $0.name == "Input Delay" }?.value, "2.000ns")
        XCTAssertTrue(report.sourceClockPath.isEmpty)
        XCTAssertEqual(report.dataPath.first?.delayType, "(clock sys_clk rise edge)")
        XCTAssertEqual(report.dataPath[1].delayType, "input delay")
        XCTAssertEqual(report.dataPath[2].object, .port("sw[8]"))
        XCTAssertEqual(report.dataPath.last?.object, .port("led[8]"))
        XCTAssertEqual(report.destinationClockPath.last?.delayType, "output delay")
        XCTAssertEqual(report.slack, -11.7)
    }

    func testAnUnconstrainedReportIsAllDataPath() {
        let text = """
            Slack:                    inf
              Source:                 sw[8]
                                        (input port)
              Destination:            led[8]
                                        (output port)
              Path Group:             (none)

                Location             Delay type                Incr(ns)  Path(ns)    Netlist Resource(s)
              -------------------------------------------------------------------    -------------------
                V2                                                0.000     0.000 r  sw[8] (IN)
                                     net (fo=0)                   0.000     0.000    sw[8]
                V13                                                               r  led[8] (OUT)
              -------------------------------------------------------------------    -------------------
            """
        let report = TimingPathReport.parse(text)
        XCTAssertEqual(report.summary.map(\.name), ["Slack", "Source", "Destination", "Path Group"])
        XCTAssertEqual(report.summary[1].value, "sw[8] (input port)")
        XCTAssertEqual(report.dataPath.count, 3)
        XCTAssertTrue(report.sourceClockPath.isEmpty && report.destinationClockPath.isEmpty)
        XCTAssertNil(report.slack)
    }

    // MARK: The timing summary's other pages

    func testTheTimingSummarysSections() throws {
        let text = try String(contentsOf: try fixture("timing_fail_vivado2025").appendingPathComponent("timing_summary.rpt"), encoding: .utf8)
        let sections = TimingSummarySections.parse(text)
        XCTAssertEqual(sections.generalInformation.map(\.name),
                       ["Tool Version", "Date", "Command", "Design", "Device", "Speed File", "Design State"])
        XCTAssertEqual(sections.generalInformation.first { $0.name == "Design State" }?.value, "Routed")
        XCTAssertTrue(sections.timerSettings.hasPrefix("  Enable Multi Corner Analysis"))
        XCTAssertTrue(sections.timerSettings.contains("Fast    Yes        Yes"))
        XCTAssertTrue(sections.checkTiming.hasPrefix("check_timing report"))
        XCTAssertFalse(sections.checkTiming.contains("Design Timing Summary"))
        XCTAssertEqual(sections.checks.count, 12)
        XCTAssertEqual(sections.checks.first { $0.name == "no_input_delay" }?.count, 3)
        XCTAssertEqual(sections.checks.first { $0.name == "no_output_delay" }?.count, 8)
        XCTAssertEqual(sections.checkTimingProblems, 11)
        XCTAssertEqual(sections.clocks.count, 1)
        XCTAssertEqual(sections.clocks.first?.name, "sys_clk")
        XCTAssertEqual(sections.clocks.first?.waveform, "{0.000 0.800}")
        XCTAssertEqual(sections.clocks.first?.period, "1.600")
        XCTAssertEqual(sections.clocks.first?.frequency, "625.000")
    }

    func testTheSectionsOfAWindowsReport() throws {
        let text = try String(contentsOf: try fixture("timing_vivado2025.rpt"), encoding: .utf8)
        let sections = TimingSummarySections.parse(text)   // this one has CR LF line endings, as Vivado on Windows wrote it
        XCTAssertEqual(sections.clocks.first?.period, "10.000")
        XCTAssertEqual(sections.checks.count, 12)
    }
}
