import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// The Flow Navigator as Vivado 2025.2 lays it out, its per-design commands, the Hardware Manager's, and Run Linter.
@MainActor
final class FlowCommandsAppTests: ExampleSandboxTestCase {
    func until(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func built(reports: [String] = ["synth_drc.rpt", "drc.rpt"]) async throws -> (AppModel, ScriptedBuildBackend) {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        let snapshot: (DesignStage) -> DesignSnapshot = { stage in
            DesignSnapshot(stage: stage, info: DesignInfo(top: "top"), cells: [DesignCell(name: "ff", type: "FDRE", isPrimitive: true)], ports: [])
        }
        backend.outcome.designs = [.rtl: snapshot(.rtl), .synth: snapshot(.synth), .impl: snapshot(.impl)]
        backend.outcome.reports = reports.map {
            ReportFile(run: DesignReportKind.stage(ofFile: $0) == .impl ? .implementation : .synthesis, name: $0, text: "report \($0)")
        }
        model.run(.bitstream)
        try await until("the build") { !model.isRunning && model.designs[.impl] != nil }
        return (model, backend)
    }

    // MARK: Layout

    func testTheSectionsAndItemsAreVivados() {
        XCTAssertEqual(FlowSection.allCases.map(\.rawValue),
                       ["Project Manager", "IP Integrator", "Simulation", "RTL Analysis", "Synthesis", "Implementation", "Program and Debug"])
        XCTAssertEqual(FlowSection.ipIntegrator.items.map(\.title), ["Create Block Design", "Open Block Design", "Generate Block Design"])
        XCTAssertEqual(FlowSection.rtlAnalysis.items.map(\.title), ["Run Linter", "Open Elaborated Design"])
        XCTAssertEqual(FlowSection.synthesis.designStage, .synth)
        XCTAssertNil(FlowSection.projectManager.designStage)
    }

    func testEachDesignListsVivadosCommandsInOrder() {
        XCTAssertEqual(DesignCommand.commands(for: .rtl).map(\.title), ["Report Methodology", "Report DRC", "Report Noise", "Schematic"])
        XCTAssertEqual(DesignCommand.commands(for: .synth).map(\.title), [
            "Constraints Wizard", "Edit Timing Constraints", "Set Up Debug", "Open Dataflow Design", "Report Timing Summary",
            "Report Clock Networks", "Report Clock Interaction", "Report Methodology", "Report DRC", "Report Noise",
            "Report Utilization", "Report Power", "Schematic"])
        XCTAssertEqual(DesignCommand.commands(for: .impl).map(\.title), [
            "Constraints Wizard", "Open Dataflow Design", "Edit Timing Constraints", "Report Timing Summary", "Report Clock Networks",
            "Report Clock Interaction", "Report Methodology", "Report DRC", "Report Noise", "Report Utilization", "Report Power", "Schematic"])
        XCTAssertEqual(HardwareCommand.allCases.map(\.title), ["Open Target", "Program Device", "Add Configuration Memory Device"])
        XCTAssertNotNil(DesignCommand.setUpDebug.unavailableReason)
        XCTAssertNil(DesignCommand.reportDRC.unavailableReason)
    }

    // MARK: Design commands

    func testAReportCommandOpensThatDesignsReport() async throws {
        let (model, _) = try await built()
        model.perform(.reportDRC, stage: .synth)
        XCTAssertEqual(model.selectedTab, .report("synth_1/synth_drc.rpt"))
        XCTAssertTrue(model.isDesignOpen(.synth), "the design opens too")
        XCTAssertTrue(model.tclLines.contains { $0.text.hasPrefix("report_drc") })
        model.perform(.reportDRC, stage: .impl)
        XCTAssertEqual(model.selectedTab, .report("impl_1/drc.rpt"))
    }

    func testAReportTheBuildDidntWriteSaysHowToGetIt() async throws {
        let (model, _) = try await built(reports: [])
        model.perform(.reportPower, stage: .impl)
        XCTAssertEqual(model.errorMessage, "The last build didn't write this report. Run implementation again to produce it.")
        model.errorMessage = nil
        model.perform(.reportNoise, stage: .rtl)
        XCTAssertNotNil(model.errorMessage, "Vivado has no noise report for the elaborated design")
    }

    func testSchematicAndUnavailableCommands() async throws {
        let (model, _) = try await built()
        model.perform(.schematic, stage: .impl)
        XCTAssertEqual(model.selectedTab, .schematic(.impl))
        let before = model.selectedTab
        model.perform(.constraintsWizard, stage: .impl)
        XCTAssertEqual(model.selectedTab, before, "greyed out: does nothing")
    }

    func testACommandBeforeAnyBuildBuildsTheDesign() async throws {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        model.perform(.reportDRC, stage: .synth)
        try await until("the build") { !backend.runs.isEmpty }
        XCTAssertEqual(backend.runs.first, .synthesis)
    }

    // MARK: Hardware

    func testHardwareCommandsNeedAnOpenTargetToProgram() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        XCTAssertTrue(model.isAvailable(.openTarget))
        XCTAssertFalse(model.isAvailable(.programDevice), "greyed until a target is open, as in Vivado")
        XCTAssertFalse(model.isAvailable(.addConfigurationMemoryDevice))
        model.perform(.openTarget)
        XCTAssertEqual(model.selectedTab, .hardware)
        try await until("the target") { model.hardware.target == .open }
        XCTAssertTrue(model.isAvailable(.programDevice))
        model.perform(.programDevice)
        XCTAssertEqual(model.hardware.sheet, .device)
        model.hardware.sheet = nil
        model.perform(.addConfigurationMemoryDevice)
        XCTAssertEqual(model.hardware.sheet, .memory)
    }

    // MARK: Run Linter

    func testRunLinterShowsWhatItFoundAndLinksTheFile() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        model.perform(.runLinter)
        XCTAssertEqual(model.selectedTab, .linter)
        XCTAssertTrue(model.tclLines.contains { $0.text.hasPrefix("synth_design -lint -top") })
        try await until("the linter") { if case .done = model.lint { return true } else { return false } }
        guard case .done(let report) = model.lint else { return XCTFail() }
        XCTAssertEqual(report.messages.first?.rule, "ASSIGN-10")
        let file = try XCTUnwrap(report.messages.first?.file)
        let path = try XCTUnwrap(model.projectFile(named: file), "the file name resolves to a project file")
        XCTAssertTrue(path.hasSuffix(file))
        model.goToSource(file: path, line: 1)
        XCTAssertEqual(model.selectedTab, .file(path))
    }

    func testABackendWithoutALinterSaysSo() async throws {
        let model = AppModel(backend: ScriptedBuildBackend(), persist: false)
        model.openExampleProject()
        model.runLinter()
        try await until("the answer") { if case .failed = model.lint { return true } else { return false } }
        model.resetRuns()
        XCTAssertEqual(model.lint, .idle, "forgotten with the other results")
    }
}
