import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// A build machine whose answer to each step comes from the test, and which records what it was asked.
final class ScriptedStepBackend: Backend, @unchecked Sendable {
    let isDemo = false
    let hostName = "buildbox"
    let vivadoPath: String? = "/tools/Xilinx/Vivado/2025.2/bin/vivado"
    let canStop = true
    private let lock = NSLock()
    private var _calls: [(step: RunKind, options: Project.FlowOptions)] = []
    /// What a step returns; the call count lets a test answer differently the second time.
    var answer: @Sendable (RunKind, Int) -> RunOutcome = { step, _ in RunOutcome(completed: [step]) }
    var output: @Sendable (RunKind) -> String = { _ in "" }

    var steps: [RunKind] { lock.withLock { _calls.map(\.step) } }
    var options: [Project.FlowOptions] { lock.withLock { _calls.map(\.options) } }

    func checkConnection() async -> ConnectionState { .connected("buildbox") }
    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {}
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        await run(step, project: project, directory: directory, options: Project.FlowOptions(), log: log)
    }
    func run(_ step: RunKind, project: Project, directory: URL, options: Project.FlowOptions,
             log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        let count = lock.withLock { () -> Int in
            _calls.append((step, options))
            return _calls.filter { $0.step == step }.count
        }
        let text = output(step)
        if !text.isEmpty { log(text) }
        return answer(step, count)
    }
}

/// Runs until its task is cancelled, as a live step does until Stop.
final class StoppableBackend: Backend, @unchecked Sendable {
    let isDemo = false
    let hostName = "buildbox"
    let vivadoPath: String? = nil
    let canStop = true
    private let lock = NSLock()
    private var _started = false
    var started: Bool { lock.withLock { _started } }

    func checkConnection() async -> ConnectionState { .connected("buildbox") }
    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {}
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        lock.withLock { _started = true }
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
        return RunOutcome(cancelled: true)
    }
}

@MainActor
final class RunEngineAppTests: XCTestCase {
    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("runengine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func makeProject(_ name: String = "demo") throws -> URL {
        let inputs = tmp.appendingPathComponent("inputs-\(name)")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let top = inputs.appendingPathComponent("top.v")
        try "module top(input clk); endmodule\n".write(to: top, atomically: true, encoding: .utf8)
        var request = NewProjectRequest(name: name, location: tmp, part: "xc7a35tcpg236-1")
        request.designSources = [top]
        return try ProjectCreator.create(request)
    }

    func makeModel(_ backend: Backend) -> AppModel { AppModel(backend: backend, persist: false) }

    func until(_ description: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    // MARK: One step at a time

    func testAStepWhoseCheckpointIsStaleRunsTheEarlierRunFirstAndSaysWhy() async throws {
        let backend = ScriptedStepBackend()
        backend.answer = { step, count in
            step == .implementation && count == 1
                ? RunOutcome(needs: RunNeed(run: .synthesis, reason: "src/top.v changed since the synth_1 checkpoint on buildbox was made"))
                : RunOutcome(completed: [step])
        }
        let model = makeModel(backend)
        model.openProject(at: try makeProject())
        // As far as the Mac knew, synthesis was current; the build machine says otherwise.
        model.run(.synthesis)
        try await until("synthesis") { !model.isRunning }
        model.run(.implementation)
        try await until("implementation") { !model.isRunning }

        XCTAssertEqual(backend.steps, [.synthesis, .implementation, .synthesis, .implementation])
        XCTAssertEqual(model.runs[.synthesis]?.status, .complete)
        XCTAssertEqual(model.runs[.implementation]?.status, .complete)
        XCTAssertTrue(model.tclLines.contains { $0.text.contains("src/top.v changed since the synth_1 checkpoint") && $0.text.contains("running synth_1 first") },
                      model.tclLines.map(\.text).joined(separator: "\n"))
    }

    func testAStepThatKeepsNeedingTheSameRunFailsInsteadOfLooping() async throws {
        let backend = ScriptedStepBackend()
        backend.answer = { step, _ in
            step == .implementation ? RunOutcome(needs: RunNeed(run: .synthesis, reason: "there is no synth_1 checkpoint on buildbox"))
                : RunOutcome(completed: [step])
        }
        let model = makeModel(backend)
        model.openProject(at: try makeProject())
        model.run(.implementation)
        try await until("the run to give up") { !model.isRunning }
        XCTAssertEqual(backend.steps, [.synthesis, .implementation, .synthesis, .implementation])
        XCTAssertEqual(model.runs[.implementation]?.status, .failed)
        XCTAssertTrue(model.messages(for: .implementation).contains { $0.kind == .error && $0.text.contains("no synth_1 checkpoint") })
    }

    func testStopCancelsTheRunningStep() async throws {
        let backend = StoppableBackend()
        let model = makeModel(backend)
        model.openProject(at: try makeProject())
        model.run(.implementation)
        try await until("the step to start") { backend.started }
        XCTAssertTrue(model.canStop)
        model.stop()
        try await until("the step to stop") { !model.isRunning }
        XCTAssertEqual(model.runs[.synthesis]?.status, .cancelled)
        XCTAssertEqual(model.runs[.implementation]?.status, .notStarted, "nothing after a stopped step runs")
        XCTAssertEqual(model.lastOutcome, .cancelled)
    }

    func testTheLiveBackendCanStop() {
        XCTAssertTrue(LiveBackend(config: BridgeConfig(host: "h", user: "u", vivadoPath: "/v")).canStop)
        XCTAssertFalse(LocalBackend().canStop, "without a build machine nothing runs")
    }

    func testNewSynthesisResultsResetImplementation() async throws {
        let model = makeModel(DemoBackend(speed: 0))
        model.openProject(at: try makeProject())
        model.run(.bitstream)
        try await until("the bitstream") { !model.isRunning && model.bitstreamReady }
        XCTAssertTrue(model.reports.contains { $0.run == .implementation })

        model.run(.synthesis)
        try await until("synthesis") { !model.isRunning && model.runs[.synthesis]?.status == .complete }
        XCTAssertEqual(model.runs[.implementation]?.status, .notStarted, "its results came from the old netlist")
        XCTAssertFalse(model.bitstreamReady)
        XCTAssertFalse(model.reports.contains { $0.run == .implementation })
        XCTAssertNil(model.designs[.impl])
    }

    func testAConstraintEditMakesBothRunsOutOfDateAsInVivado() async throws {
        let model = makeModel(DemoBackend(speed: 0))
        let dir = try makeProject()
        try "set_property PACKAGE_PIN W5 [get_ports clk]\n".write(to: dir.appendingPathComponent("pins.xdc"), atomically: true, encoding: .utf8)
        model.openProject(at: dir)
        model.addSources([dir.appendingPathComponent("pins.xdc")], to: .constraints)
        model.run(.implementation)
        try await until("the runs") { !model.isRunning && model.runs[.implementation]?.status == .complete }

        let xdc = try XCTUnwrap(model.allSourcePaths.first { $0.hasSuffix(".xdc") })
        model.updateDraft("set_property PACKAGE_PIN W6 [get_ports clk]\n", for: xdc)
        XCTAssertTrue(model.saveFile(xdc))
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, true, "constraints are used in synthesis by default in Vivado")
        XCTAssertEqual(model.runs[.implementation]?.outOfDate, true)

        // So Run Implementation runs synthesis first.
        XCTAssertEqual(RunPlanner.steps(for: .implementation, synthesisUpToDate: model.runs[.synthesis]?.isUpToDate == true,
                                        implementationUpToDate: model.runs[.implementation]?.isUpToDate == true), [.synthesis, .implementation])
    }

    func testDesignRunsShowsTheCommandVivadoIsOn() async throws {
        let backend = ScriptedStepBackend()
        backend.output = { step in step == .implementation ? "Command: opt_design\nCommand: place_design -directive Explore\n" : "" }
        backend.answer = { step, _ in step == .implementation ? RunOutcome(failed: true) : RunOutcome(completed: [step]) }
        let model = makeModel(backend)
        model.openProject(at: try makeProject())
        model.run(.implementation)
        try await until("the runs") { !model.isRunning }
        XCTAssertEqual(model.runStatusText(.implementation), "place_design ERROR")
        XCTAssertEqual(model.runStatusText(.synthesis), "synth_design Complete!")
        XCTAssertEqual(model.nextStep, .implementation)
    }

    // MARK: Launch Runs

    func testLaunchRunsAsksFirstAndItsJobsBecomeTheThreadLimit() async throws {
        let backend = ScriptedStepBackend()
        let model = makeModel(backend)
        model.openProject(at: try makeProject())
        model.asksBeforeLaunching = true
        model.run(.synthesis)
        XCTAssertEqual(model.launchRequest, .synthesis)
        XCTAssertFalse(model.isRunning, "nothing runs until OK")

        model.confirmLaunch(jobs: 3, dontAskAgain: false)
        try await until("synthesis") { !model.isRunning && model.runs[.synthesis]?.status == .complete }
        XCTAssertEqual(backend.options, [Project.FlowOptions(maxThreads: 3)])
        XCTAssertTrue(model.tclLines.contains { $0.text == "launch_runs synth_1 -jobs 3" })
        XCTAssertTrue(model.asksBeforeLaunching)

        model.run(.implementation)
        model.cancelLaunch()
        XCTAssertNil(model.launchRequest)
        XCTAssertEqual(backend.steps, [.synthesis], "Cancel runs nothing")

        model.run(.implementation)
        model.confirmLaunch(jobs: 99, dontAskAgain: true)
        try await until("implementation") { !model.isRunning && model.runs[.implementation]?.status == .complete }
        XCTAssertEqual(backend.options.last, Project.FlowOptions(maxThreads: Project.FlowOptions.threadRange.upperBound))
        XCTAssertFalse(model.asksBeforeLaunching, "Don't show this dialog again")
    }

    func testOpeningADesignThroughTheDialogStillOpensItAfterwards() async throws {
        let model = makeModel(DemoBackend(speed: 0))
        model.openProject(at: try makeProject())
        model.asksBeforeLaunching = true
        model.showsCompletionDialog = true
        model.openDesign(.synth)
        XCTAssertEqual(model.launchRequest, .synthesis)
        model.confirmLaunch(jobs: 4, dontAskAgain: false)
        try await until("the design") { model.selectedTab == .design(.synth) }
        XCTAssertNil(model.completionPrompt, "the design opening is the answer; no dialog on top of it")
    }

    // MARK: Completion dialog

    func testTheCompletionDialogOffersTheNextStep() async throws {
        let backend = ScriptedStepBackend()
        let model = makeModel(backend)
        model.openProject(at: try makeProject())
        model.showsCompletionDialog = true
        model.run(.synthesis)
        try await until("synthesis") { model.completionPrompt != nil }
        let prompt = try XCTUnwrap(model.completionPrompt)
        XCTAssertEqual(prompt, .completed(.synthesis))
        XCTAssertEqual(prompt.title, "Synthesis Completed")
        XCTAssertEqual(prompt.choices.first, .runImplementation)

        model.completionChosen(.runImplementation, dontShowAgain: false)
        try await until("implementation") { model.completionPrompt == .completed(.implementation) }
        XCTAssertEqual(backend.steps, [.synthesis, .implementation])
        XCTAssertEqual(model.completionPrompt?.choices, [.openImplementedDesign, .generateBitstream, .viewReports])

        model.completionChosen(.viewReports, dontShowAgain: true)
        XCTAssertEqual(model.consoleTab, .reports)
        XCTAssertFalse(model.showsCompletionDialog)
        XCTAssertEqual(RunCompletion.completed(.bitstream).title, "Bitstream Generation Completed")
        XCTAssertNotNil(RunCompletionChoice.generateMemoryConfigurationFile.unavailableReason)
    }

    func testAFailedRunSaysWhichStepFailed() async throws {
        let backend = ScriptedStepBackend()
        backend.answer = { step, _ in step == .implementation ? RunOutcome(failed: true) : RunOutcome(completed: [step]) }
        let model = makeModel(backend)
        model.openProject(at: try makeProject())
        model.showsCompletionDialog = true
        model.run(.bitstream)
        try await until("the failure") { model.completionPrompt != nil }
        XCTAssertEqual(model.completionPrompt, .failed(.implementation))
        XCTAssertEqual(model.completionPrompt?.title, "Implementation Failed")
        XCTAssertEqual(backend.steps, [.synthesis, .implementation], "the bitstream isn't attempted")
        model.completionChosen(.viewLog, dontShowAgain: false)
        XCTAssertEqual(model.consoleTab, .log)
        XCTAssertEqual(model.logRun, .implementation)
    }

    // MARK: Reopening a project

    func testReopeningJudgesEachRunByItsKey() throws {
        let dir = try makeProject()
        var project = try Project.load(from: dir)
        let xdc = dir.appendingPathComponent("pins.xdc")
        try "# pins\n".write(to: xdc, atomically: true, encoding: .utf8)
        project.constraints = ["pins.xdc"]
        try project.save(to: dir)
        let vivado = "/tools/Xilinx/Vivado/2025.2/bin/vivado"
        let out = dir.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let keys = try RunKeys(project: project, root: dir, vivadoPath: vivado)
        let files = BuildManifest.fingerprint(try BuildManifest.inputs(of: project, root: dir), root: dir)
        try BuildManifest(project: project.name, top: project.top, part: project.part, board: nil, vivadoVersion: "2025.2",
                          buildMachine: "buildbox", builtAt: Date(), files: files, git: nil, runs: keys.recorded(through: .bitstream)).save(to: out)

        XCTAssertEqual(AppModel.staleRuns(build: out, project: project, root: dir, vivadoPath: vivado), [])
        try "# pins, moved\n".write(to: xdc, atomically: true, encoding: .utf8)
        XCTAssertEqual(AppModel.staleRuns(build: out, project: project, root: dir, vivadoPath: vivado), [.synthesis, .implementation])
        XCTAssertEqual(AppModel.staleRuns(build: out, project: project, root: dir, vivadoPath: nil), [.synthesis, .implementation],
                       "without the Vivado path the keys can't be checked, so any change counts")
        let source = try XCTUnwrap(try project.resolveSources(in: dir).first)
        try "module top(input clk); wire w; endmodule\n".write(to: dir.appendingPathComponent(source), atomically: true, encoding: .utf8)
        XCTAssertEqual(AppModel.staleRuns(build: out, project: project, root: dir, vivadoPath: vivado), [.synthesis, .implementation])
    }
}
