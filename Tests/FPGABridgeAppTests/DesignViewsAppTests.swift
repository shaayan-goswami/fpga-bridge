import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// A build machine that isn't Demo Mode: it reports what the test tells it to, and remembers what it was asked.
final class ScriptedBuildBackend: Backend, @unchecked Sendable {
    let isDemo = false
    let hostName = "buildbox"
    let vivadoPath: String? = nil
    let canStop = true
    private let lock = NSLock()
    private var _runs: [RunKind] = []
    var outcome = RunOutcome(completed: [.synthesis, .implementation, .bitstream])

    var runs: [RunKind] { lock.withLock { _runs } }

    func checkConnection() async -> ConnectionState { .connected("buildbox") }
    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {}
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        lock.withLock { _runs.append(step) }
        return outcome
    }
}

@MainActor
final class DesignViewsAppTests: ExampleSandboxTestCase {
    func until(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func snapshot(_ stage: DesignStage) -> DesignSnapshot {
        DesignSnapshot(stage: stage, info: DesignInfo(stage: stage.rawValue, part: "xc7a35t", top: "top", vivado: "2025.2"),
                       cells: [DesignCell(name: "top_ff", type: "FDRE", isPrimitive: true)], ports: [])
    }

    // MARK: Flow Navigator

    func testEveryFlowNavigatorItemIsNowAvailable() {
        XCTAssertEqual(FlowItem.allCases.filter { !$0.isAvailable }, [], "nothing is greyed out any more")
        XCTAssertTrue(FlowItem.openElaboratedDesign.isAvailable)
        XCTAssertTrue(FlowItem.openSynthesizedDesign.isAvailable)
        XCTAssertTrue(FlowItem.openImplementedDesign.isAvailable)
        XCTAssertTrue(FlowItem.ipCatalog.isAvailable)
        XCTAssertEqual(FlowItem.openElaboratedDesign.designStage, .rtl)
        XCTAssertEqual(FlowItem.openSynthesizedDesign.designStage, .synth)
        XCTAssertEqual(FlowItem.openImplementedDesign.designStage, .impl)
        XCTAssertNil(FlowItem.runSynthesis.designStage)
    }

    // MARK: Opening a design

    func testOpeningADesignThatExistsJustShowsIt() async throws {
        let backend = ScriptedBuildBackend()
        backend.outcome.designs = [.synth: snapshot(.synth)]
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        model.run(.synthesis)
        try await until("the build") { !model.isRunning && model.designs[.synth] != nil }
        model.selectedTab = .summary
        let runsBefore = backend.runs.count

        model.perform(.openSynthesizedDesign)
        XCTAssertEqual(model.selectedTab, .design(.synth))
        XCTAssertEqual(model.title(of: .design(.synth)), "Synthesized Design")
        XCTAssertEqual(backend.runs.count, runsBefore, "no new build")
    }

    func testOpeningADesignWithNoDataRunsABuildThenShowsIt() async throws {
        let backend = ScriptedBuildBackend()
        backend.outcome.designs = [.rtl: snapshot(.rtl), .synth: snapshot(.synth)]
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        XCTAssertNil(model.designs[.synth])

        model.perform(.openSynthesizedDesign)
        try await until("the design tab") { model.selectedTab == .design(.synth) }
        XCTAssertEqual(backend.runs, [.synthesis], "synthesis was enough")
        XCTAssertNotNil(model.designs[.synth])
    }

    func testTheImplementedDesignRunsImplementation() async throws {
        let backend = ScriptedBuildBackend()
        backend.outcome.designs = [.impl: snapshot(.impl)]
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        model.perform(.openImplementedDesign)
        try await until("the design tab") { model.selectedTab == .design(.impl) }
        // This build machine does everything in one script, so the first step completes implementation too.
        XCTAssertFalse(backend.runs.isEmpty)
        XCTAssertNotNil(model.designs[.impl])
    }

    func testAFailedBuildDoesNotOpenAViewNowOrLater() async throws {
        let backend = ScriptedBuildBackend()
        backend.outcome = RunOutcome(failed: true)
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        model.perform(.openSynthesizedDesign)
        try await until("the build to fail") { !model.isRunning && model.lastOutcome == .failed }
        XCTAssertNotEqual(model.selectedTab, .design(.synth))

        // A later, hand-started build that does produce the data must not pop the old request open.
        backend.outcome = RunOutcome(completed: [.synthesis], designs: [.synth: snapshot(.synth)])
        model.run(.synthesis)
        try await until("the second build") { !model.isRunning && model.designs[.synth] != nil }
        XCTAssertNotEqual(model.selectedTab, .design(.synth), "the request died with the failed build")
    }

    func testNewProjectClearsTheDesigns() async throws {
        let backend = ScriptedBuildBackend()
        backend.outcome.designs = [.synth: snapshot(.synth)]
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        model.run(.synthesis)
        try await until("designs") { model.designs[.synth] != nil }
        model.closeProject()
        XCTAssertTrue(model.designs.isEmpty)
    }

    // MARK: Demo mode

    func testDemoModeBuildsProduceSampleDesigns() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        model.run(.synthesis)
        try await until("synthesis") { model.runs[.synthesis]?.isUpToDate == true }
        XCTAssertEqual(Set(model.designs.keys), [.rtl, .synth], "synthesis gives the first two views")
        model.run(.implementation)
        try await until("implementation") { model.runs[.implementation]?.isUpToDate == true }
        XCTAssertEqual(Set(model.designs.keys), [.rtl, .synth, .impl])

        let synth = try XCTUnwrap(model.designs[.synth])
        XCTAssertEqual(synth.info.top, model.project?.top)
        XCTAssertTrue(synth.info.vivado.contains("demo"), "sample data says so")
        XCTAssertEqual(synth.root.children?.count, 2, "one instance per other module in the example (debounce, clk_div)")
        XCTAssertGreaterThan(synth.root.totals.lut, 0)
        XCTAssertEqual(model.designs[.rtl]?.root.totals.lut, 0, "no LUTs before synthesis")
        XCTAssertTrue(synth.ports.allSatisfy(\.isPlaced))
    }

    // MARK: Reports

    func testReportTitlesCoverEveryReportTheBuildWrites() {
        for (stage, reports) in DesignDump.reports {
            for report in reports {
                let entry = ReportEntry(run: stage == "synth" ? .synthesis : .implementation, fileName: report.file, text: "")
                XCTAssertNotEqual(entry.title, report.file, "\(report.file) has a readable title")
            }
        }
    }

    func testLiveReportsAreSplitBySynthesisAndImplementation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["synth_utilization.rpt", "timing_summary.rpt", "power.rpt", "notes.txt", "top.bit"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let reports = LiveBackend.reports(in: dir)
        XCTAssertEqual(reports.map(\.name), ["power.rpt", "synth_utilization.rpt", "timing_summary.rpt"], "only .rpt files, sorted")
        XCTAssertEqual(reports.first { $0.name == "synth_utilization.rpt" }?.run, .synthesis)
        XCTAssertEqual(reports.first { $0.name == "power.rpt" }?.run, .implementation)
    }

    // MARK: Reopening a project

    func testReopeningAProjectRestoresTheLastBuildsReportsAndDesigns() async throws {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        let project = try XCTUnwrap(model.projectURL)
        // Leave what a build leaves, in build/.
        let out = project.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try "Design Timing Summary".write(to: out.appendingPathComponent("timing_summary.rpt"), atomically: true, encoding: .utf8)
        try "synth_cells".write(to: out.appendingPathComponent("synth_utilization.rpt"), atomically: true, encoding: .utf8)
        try "top_ff\tFDRE\t1\n".write(to: out.appendingPathComponent("synth_cells.tsv"), atomically: true, encoding: .utf8)
        try "top\ttop\npart\txc7\n".write(to: out.appendingPathComponent("synth_info.tsv"), atomically: true, encoding: .utf8)

        model.closeProject()
        XCTAssertTrue(model.reports.isEmpty)
        model.openProject(at: project)
        try await until("the restored build") { model.designs[.synth] != nil }
        XCTAssertEqual(model.designs[.synth]?.cells.count, 1)
        XCTAssertEqual(Set(model.reports.map(\.fileName)), ["timing_summary.rpt", "synth_utilization.rpt"])
        XCTAssertEqual(model.runs[.synthesis]?.status, .notStarted, "results may be older than the sources: only a run can mark it complete")
        XCTAssertNil(model.selectedTab.designStage, "restoring doesn't open any view")
    }

    func testDemoModeRestoresNothing() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        let out = try XCTUnwrap(model.projectURL).appendingPathComponent("build")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try "x".write(to: out.appendingPathComponent("timing_summary.rpt"), atomically: true, encoding: .utf8)
        model.closeProject()
        model.openProject(at: try XCTUnwrap(model.recentProjects.first ?? out.deletingLastPathComponent()))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.reports.isEmpty, "a simulated build machine has no results to show")
    }
}

private extension WorkspaceTab {
    var designStage: DesignStage? { if case .design(let stage) = self { stage } else { nil } }
}
