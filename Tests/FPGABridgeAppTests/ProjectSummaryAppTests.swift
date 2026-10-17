import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// What the Project Summary and Design Runs read from a build, and how a previous build is restored.
@MainActor
final class ProjectSummaryAppTests: ExampleSandboxTestCase {
    nonisolated(unsafe) var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    func write(_ name: String, in dir: URL, date: Date? = nil) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    func testWhichStepsABuildFolderShowsWereDone() throws {
        XCTAssertEqual(AppModel.completedSteps(reports: [], designs: [], out: tmp, top: "top"), [])
        XCTAssertEqual(AppModel.completedSteps(reports: ["synth_utilization.rpt"], designs: [], out: tmp, top: "top"), [.synthesis])
        try write("top.bit", in: tmp)
        XCTAssertEqual(AppModel.completedSteps(reports: ["synth_drc.rpt", "timing_summary.rpt"], designs: [.rtl], out: tmp, top: "top"),
                       [.synthesis, .implementation, .bitstream])
    }

    func testABuildIsStaleWhenASourceChangedAfterIt() throws {
        let root = tmp.appendingPathComponent("p")
        let project = Project(name: "p", top: "top", part: "x", sources: ["src"], constraints: [])
        try write("src/top.v", in: root, date: Date(timeIntervalSinceNow: -3600))
        try write(Project.fileName, in: root, date: Date(timeIntervalSinceNow: -3600))
        let out = root.appendingPathComponent("build")
        try write("synth_drc.rpt", in: out, date: Date(timeIntervalSinceNow: -60))
        XCTAssertFalse(AppModel.isStale(build: out, project: project, root: root), "nothing changed since the build")
        try write("src/top.v", in: root)
        XCTAssertTrue(AppModel.isStale(build: out, project: project, root: root), "the source is newer than the build")
        XCTAssertFalse(AppModel.isStale(build: root.appendingPathComponent("nothing"), project: project, root: root), "no build at all")
    }

    func testTheSummaryReadsTheBuildsReports() async throws {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        func fixture(_ name: String) throws -> String {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "rpt")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("FPGABridgeCoreTests/Fixtures/\(name).rpt"))
            return try String(contentsOf: url, encoding: .utf8)
        }
        backend.outcome.reports = [
            ReportFile(run: .implementation, name: "power.rpt", text: try fixture("power_vivado2025")),
            ReportFile(run: .implementation, name: "methodology.rpt", text: try fixture("methodology_vivado2025")),
            ReportFile(run: .implementation, name: "route_status.rpt", text: try fixture("route_status_vivado2025")),
            ReportFile(run: .implementation, name: "drc.rpt", text: try fixture("drc_vivado2025")),
        ]
        model.run(.bitstream)
        for _ in 0..<300 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.power(at: .impl)?.totalOnChip, 0.081)
        XCTAssertEqual(model.checks(.methodology, at: .impl)?.total, 33)
        XCTAssertEqual(model.checks(.drc, at: .impl)?.total, 0)
        XCTAssertEqual(model.routeStatus?.failedRoutes, 0)
        XCTAssertNil(model.power(at: .synth), "no synthesis power report in this build")
        XCTAssertEqual(model.runStatusText(.implementation), "write_bitstream Complete!")
        XCTAssertEqual(model.runStatusText(.synthesis), "synth_design Complete!")
        XCTAssertEqual(model.synthesisStrategy, "Vivado Synthesis Defaults")
    }

    func testMessageCountsComeFromTheRunsLog() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        XCTAssertNil(model.messageCounts(.synthesis), "no run yet in this session")
        model.run(.synthesis)
        for _ in 0..<300 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.messageCounts(.synthesis))
    }
}
