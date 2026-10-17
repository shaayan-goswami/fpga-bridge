import XCTest
@testable import FPGABridgeCore

final class DesignReportsTests: XCTestCase {
    // MARK: Which file each report is

    func testEveryReportTheBuildWritesHasAName() {
        let written = Set(DesignDump.reports.values.flatMap { $0.map(\.file) })
        for kind in DesignReportKind.allCases {
            for stage in DesignStage.allCases {
                guard let file = kind.fileName(for: stage) else { continue }
                if file == "timing_summary.rpt" || file == "utilization.rpt" { continue }   // written by the main script
                XCTAssertTrue(written.contains(file), "\(kind) at \(stage): the build writes \(file)")
                XCTAssertEqual(DesignReportKind.stage(ofFile: file), stage)
            }
        }
    }

    func testTheElaboratedDesignOnlyHasDRCAndMethodology() {
        XCTAssertEqual(DesignReportKind.allCases.filter { $0.fileName(for: .rtl) != nil }, [.methodology, .drc])
        XCTAssertTrue(DesignReportKind.allCases.allSatisfy { $0.fileName(for: .synth) != nil })
        XCTAssertTrue(DesignReportKind.allCases.allSatisfy { $0.fileName(for: .impl) != nil })
    }

    func testTitlesIgnoreTheStagePrefix() {
        XCTAssertEqual(DesignReportKind.title(ofFile: "synth_drc.rpt"), "DRC Report")
        XCTAssertEqual(DesignReportKind.title(ofFile: "rtl_methodology.rpt"), "Methodology Report")
        XCTAssertEqual(DesignReportKind.title(ofFile: "clock_interaction.rpt"), "Clock Interaction Report")
        XCTAssertEqual(DesignReportKind.title(ofFile: "timing_summary.rpt"), "Timing Summary Report")
        XCTAssertEqual(DesignReportKind.title(ofFile: "other.rpt"), "other.rpt")
    }

    func testTheElaboratedStageNowWritesItsReports() {
        let tcl = DesignDump.procedures
        XCTAssertTrue(tcl.contains("catch { report_drc -file out/rtl_drc.rpt }"))
        XCTAssertTrue(tcl.contains("catch { report_methodology -file out/rtl_methodology.rpt }"))
        XCTAssertTrue(tcl.contains("catch { report_clock_interaction -file out/clock_interaction.rpt }"))
        XCTAssertTrue(tcl.contains("catch { report_clock_networks -file out/synth_clock_networks.rpt }"))
    }

    // MARK: Linter

    func testTheRealLinterOutputParses() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lint_vivado2025", withExtension: "txt", subdirectory: "Fixtures"))
        let report = LintReport.parse(log: try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(report.finished)
        XCTAssertEqual(report.rules, [LintReport.RuleCount(rule: "ASSIGN-10", severity: "WARNING", violations: 1, waived: 0)])
        XCTAssertEqual(report.messages.count, 1)
        let m = try XCTUnwrap(report.messages.first)
        XCTAssertEqual(m.severity, "WARNING")
        XCTAssertEqual(m.rule, "ASSIGN-10")
        XCTAssertEqual(m.text, "Some bits in IO 'sw' are not read. First unread bit index is 2.")
        XCTAssertEqual(m.rtlName, "sw")
        XCTAssertEqual(m.hierarchy, "demo_top")
        XCTAssertEqual(m.file, "demo_top.v")
        XCTAssertEqual(m.line, 15)
    }

    func testOtherSynthMessagesAreNotLinterMessages() {
        let log = """
            WARNING: [Synth 8-7129] Port x in module y is either unconnected or has no load
            CRITICAL WARNING: [Synth 37-9] [INFER-1]Latch inferred for 'q'.
            RTL Name 'q', Hierarchy 'top', File 'top.v', Line 7.
            ERROR: [Synth 37-1] [MULTIDRIVEN-1]Net 'n' has more than one driver.
            INFO: [Synth 37-45] Linter Run Finished!
            """
        let report = LintReport.parse(log: log)
        XCTAssertEqual(report.messages.map(\.rule), ["INFER-1", "MULTIDRIVEN-1"])
        XCTAssertEqual(report.messages.map(\.severity), ["CRITICAL WARNING", "ERROR"])
        XCTAssertEqual(report.messages[0].line, 7)
        XCTAssertNil(report.messages[1].file, "no location line after it")
        XCTAssertTrue(report.finished)
        XCTAssertFalse(LintReport.parse(log: "ERROR: [Synth 8-439] module 'x' not found").finished)
    }

    func testAMessageRightAfterTheTableIsRead() {
        let report = LintReport.parse(log: "| Rule ID | Severity | # Violations | # Waived |\n| A-1 | WARNING | 1 | 0 |\nWARNING: [Synth 37-1] [A-1]x\n")
        XCTAssertEqual(report.rules.map(\.rule), ["A-1"])
        XCTAssertEqual(report.messages.map(\.rule), ["A-1"])
    }

    func testTheLintScriptReadsTheDesignAsABuildDoes() {
        var settings = ProjectSettings()
        settings.language.defines = ["SIM=1"]
        let p = Project(name: "p", top: "top", part: "xc7a35t", sources: ["src"], constraints: ["c"], settings: settings)
        let script = p.lintScript(sources: ["src/a.v", "src/b.sv", "src/c.vhd"], constraints: ["c/pins.xdc"])
        XCTAssertTrue(script.contains("read_verilog {src/a.v}\nread_verilog -sv {src/b.sv}\nread_vhdl {src/c.vhd}\nread_xdc {c/pins.xdc}"))
        XCTAssertTrue(script.contains("synth_design -lint -top top -part xc7a35t -verilog_define SIM=1"))
        XCTAssertFalse(script.contains("opt_design"), "only the linter")
        let build = p.buildScript(sources: ["src/a.v", "src/b.sv", "src/c.vhd"], constraints: ["c/pins.xdc"])
        XCTAssertTrue(build.contains("read_verilog {src/a.v}\nread_verilog -sv {src/b.sv}\nread_vhdl {src/c.vhd}\nread_xdc {c/pins.xdc}"),
                      "the same read lines as a build")
    }
}
