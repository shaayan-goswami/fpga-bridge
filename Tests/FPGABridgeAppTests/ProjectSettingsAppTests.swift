import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

@MainActor
final class ProjectSettingsAppTests: ExampleSandboxTestCase {
    func makeModel() async throws -> AppModel {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        model.run(.bitstream)
        for _ in 0..<500 where model.isRunning || !(model.runs[.implementation]?.isUpToDate ?? false) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.runs[.synthesis]?.isUpToDate == true && model.runs[.implementation]?.isUpToDate == true, "set up: both runs complete")
        return model
    }

    func apply(_ model: AppModel, _ change: (inout ProjectSettings) -> Void, simulationTop: String? = nil) throws {
        let project = try XCTUnwrap(model.project)
        var settings = project.settings ?? ProjectSettings()
        change(&settings)
        model.applySettings(top: project.top, part: project.part, board: project.board, language: project.targetLanguage ?? "Verilog",
                            vivadoVersion: project.vivadoVersion, settings: settings, simulationTop: simulationTop ?? project.simulationTop)
    }

    func testSettingsAreSavedInTheProjectFile() async throws {
        let model = try await makeModel()
        try apply(model) { $0.synthesis.retiming = true; $0.bitstream.binFile = true }
        let url = try XCTUnwrap(model.projectURL)
        let saved = try Project.load(from: url)
        XCTAssertEqual(saved.settings?.synthesis.retiming, true)
        XCTAssertEqual(saved.settings?.bitstream.binFile, true)
        XCTAssertEqual(model.project?.settings, saved.settings)
        XCTAssertNil(model.errorMessage)
    }

    func testDefaultSettingsLeaveNothingInTheFile() async throws {
        let model = try await makeModel()
        try apply(model) { $0.synthesis.retiming = true }
        try apply(model) { $0 = ProjectSettings() }
        XCTAssertNil(try Project.load(from: XCTUnwrap(model.projectURL)).settings, "back to defaults means no settings block")
    }

    func testChangingSynthesisSettingsMakesBothRunsOutOfDate() async throws {
        let model = try await makeModel()
        try apply(model) { $0.synthesis.flattenHierarchy = .full }
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, true)
        XCTAssertEqual(model.runs[.implementation]?.outOfDate, true)
    }

    func testChangingLanguageSettingsMakesBothRunsOutOfDate() async throws {
        let model = try await makeModel()
        try apply(model) { $0.language.defines = ["FAST"] }
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, true)
        XCTAssertEqual(model.runs[.implementation]?.outOfDate, true)
    }

    func testChangingImplementationOrBitstreamSettingsOnlyOutdatesImplementation() async throws {
        let model = try await makeModel()
        try apply(model) { $0.implementation.routeDirective = "Explore" }
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, false, "synthesis doesn't depend on it")
        XCTAssertEqual(model.runs[.implementation]?.outOfDate, true)

        let model2 = try await makeModel()
        try apply(model2) { $0.bitstream.compress = true }
        XCTAssertEqual(model2.runs[.synthesis]?.outOfDate, false)
        XCTAssertEqual(model2.runs[.implementation]?.outOfDate, true)
    }

    func testSimulationSettingsOutdateNothing() async throws {
        let model = try await makeModel()
        try apply(model) { $0.simulation.timeLimit = 30; $0.simulation.recordWaveform = false }
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, false)
        XCTAssertEqual(model.runs[.implementation]?.outOfDate, false)
        XCTAssertEqual(model.project?.settings?.simulation.timeLimit, 30)
    }

    func testTheSimulationTopIsSaved() async throws {
        let model = try await makeModel()
        try apply(model, { _ in }, simulationTop: "blinky_tb")
        XCTAssertEqual(try Project.load(from: XCTUnwrap(model.projectURL)).simulationTop, "blinky_tb")
    }

    func testInvalidSettingsAreRefusedAndNothingIsSaved() async throws {
        let model = try await makeModel()
        try apply(model) { $0.synthesis.moreOptions = "[exec x]" }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("Invalid settings") == true, model.errorMessage ?? "")
        XCTAssertNil(try Project.load(from: XCTUnwrap(model.projectURL)).settings, "the file is untouched")
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, false)
    }

    func testTheConsoleSaysWhatTheNextRunWillDo() async throws {
        let model = try await makeModel()
        try apply(model) { $0.implementation.routeDirective = "Explore" }
        XCTAssertTrue(model.tclLines.contains { $0.kind == .info && $0.text.contains("route_design -directive Explore") }, "\(model.tclLines.map(\.text))")
        XCTAssertFalse(model.tclLines.contains { $0.text.contains("…") }, "no placeholder text posing as a command")
    }

    func testWhichRunsAChangeAffects() {
        let base = Project(name: "p", top: "t", part: "x", sources: ["a"], constraints: [])
        func with(_ change: (inout Project) -> Void) -> Project { var p = base; change(&p); return p }
        XCTAssertEqual(AppModel.runsAffected(by: base, with { $0.top = "u" }), [.synthesis, .implementation])
        XCTAssertEqual(AppModel.runsAffected(by: base, with { $0.part = "y" }), [.synthesis, .implementation])
        XCTAssertEqual(AppModel.runsAffected(by: base, with { $0.settings = { var s = ProjectSettings(); s.language.defines = ["A"]; return s }() }),
                       [.synthesis, .implementation])
        XCTAssertEqual(AppModel.runsAffected(by: base, with { $0.settings = { var s = ProjectSettings(); s.bitstream.compress = true; return s }() }), [.implementation])
        XCTAssertEqual(AppModel.runsAffected(by: base, with { $0.settings = { var s = ProjectSettings(); s.simulation.allWarnings = true; return s }() }), [])
        XCTAssertEqual(AppModel.runsAffected(by: base, with { $0.simulationTop = "tb"; $0.board = "basys3" }), [], "labels only")
    }
}
