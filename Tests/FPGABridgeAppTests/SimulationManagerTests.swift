import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// A simulator the test controls: it logs what it's told and waits to be released.
final class ScriptedSimulation: SimulationBackend, @unchecked Sendable {
    let isDemo = false
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var gated = false

    var output: [String] = []
    var outcome = SimulationOutcome(result: .finished, top: "tb", waveform: URL(fileURLWithPath: "/tmp/sim.vcd"), finishedAt: "1 µs")
    private(set) var lastDirectory: URL?
    private(set) var stopFlag: Shell.StopFlag?

    /// Makes the next run wait for `release()`.
    func holdNextRun() { lock.withLock { gated = true } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in let g = gate; gate = nil; return g }
        continuation?.resume()
    }

    var isWaiting: Bool { lock.withLock { gate != nil } }

    func run(project: Project, directory: URL, stop: Shell.StopFlag, log: @escaping @Sendable (String) -> Void) async -> SimulationOutcome {
        lock.withLock { lastDirectory = directory; stopFlag = stop }
        output.forEach(log)
        if lock.withLock({ gated }) {
            await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
            lock.withLock { gated = false }
        }
        return outcome
    }
}

@MainActor
final class SimulationManagerTests: ExampleSandboxTestCase {
    let project = Project(name: "p", top: "top", part: "x", sources: ["src"], constraints: [])
    let directory = URL(fileURLWithPath: "/tmp/p")

    func until(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting")
    }

    func testARunKeepsItsLogAndReportsTheOutcome() async {
        let backend = ScriptedSimulation()
        backend.output = ["INFO: hello\n", "plain line\n", "ERROR: bad\n"]
        let manager = SimulationManager(backend: backend)
        var console: [(String, ConsoleLine.Kind)] = []
        manager.console = { console.append(($0, $1)) }
        XCTAssertEqual(manager.state, .idle)

        let outcome = await manager.run(project: project, directory: directory)
        XCTAssertEqual(outcome?.result, .finished)
        XCTAssertEqual(manager.state, .done(backend.outcome))
        XCTAssertEqual(manager.lines.map(\.text), ["INFO: hello", "plain line", "ERROR: bad", "INFO: simulation of tb finished at 1 µs"])
        XCTAssertEqual(manager.lines.map(\.kind), [.info, .output, .error, .info])
        XCTAssertEqual(console.first?.0, "launch_simulation", "echoed like the Tcl command it stands for")
        XCTAssertEqual(console.first?.1, .command)
        XCTAssertTrue(console.contains { $0.0 == "ERROR: bad" })
        XCTAssertEqual(backend.lastDirectory, directory)
    }

    func testAFailedCompileAndATimeoutAreReportedAsErrors() async {
        let backend = ScriptedSimulation()
        let manager = SimulationManager(backend: backend)

        backend.outcome = SimulationOutcome(result: .failed, stage: .compile, top: "tb")
        await manager.run(project: project, directory: directory)
        XCTAssertEqual(manager.lines.last?.text, "ERROR: simulation failed to compile")
        XCTAssertEqual(manager.lines.last?.kind, .error)

        backend.outcome = SimulationOutcome(result: .timedOut, top: "tb")
        await manager.run(project: project, directory: directory)
        XCTAssertTrue(manager.lines.last?.text.contains("timed out") == true)
        XCTAssertEqual(manager.lines.last?.kind, .error)
    }

    func testOnlyOneSimulationRunsAtATime() async throws {
        let backend = ScriptedSimulation()
        backend.holdNextRun()
        let manager = SimulationManager(backend: backend)
        let first = Task { await manager.run(project: project, directory: directory) }
        try await until { backend.isWaiting }
        XCTAssertTrue(manager.isRunning)

        let second = await manager.run(project: project, directory: directory)
        XCTAssertNil(second, "refused while one is running")

        backend.release()
        _ = await first.value
        XCTAssertFalse(manager.isRunning)
    }

    func testStopAsksTheSimulatorToStop() async throws {
        let backend = ScriptedSimulation()
        backend.holdNextRun()
        let manager = SimulationManager(backend: backend)
        let run = Task { await manager.run(project: project, directory: directory) }
        try await until { backend.isWaiting }
        XCTAssertEqual(backend.stopFlag?.isSet, false)
        manager.stop()
        XCTAssertEqual(backend.stopFlag?.isSet, true)
        backend.release()
        _ = await run.value
    }

    func testAnAbandonedRunDoesNotLandInTheNextProjectsTab() async throws {
        let backend = ScriptedSimulation()
        backend.holdNextRun()
        backend.output = ["old output\n"]
        let manager = SimulationManager(backend: backend)
        let old = Task { await manager.run(project: project, directory: directory) }
        try await until { backend.isWaiting }

        manager.reset()                      // another project was opened
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(manager.lines.isEmpty)

        backend.release()
        _ = await old.value
        XCTAssertEqual(manager.state, .idle, "the old run's result is ignored")
        XCTAssertTrue(manager.lines.isEmpty)
    }

    func testTheFlowItemRunsTheSimulationAndShowsItsTab() async throws {
        let backend = ScriptedSimulation()
        let model = AppModel(backend: DemoBackend(speed: 0), simulation: backend, persist: false)
        model.openExampleProject()
        XCTAssertTrue(FlowItem.runSimulation.isAvailable)
        model.perform(.runSimulation)
        XCTAssertEqual(model.selectedTab, .simulation)
        XCTAssertEqual(model.title(of: .simulation), "Simulation")
        try await until { if case .done = model.simulation.state { return true } else { return false } }
        XCTAssertEqual(backend.lastDirectory?.standardizedFileURL, model.projectURL?.standardizedFileURL)
    }

    func testOpeningAnotherProjectForgetsTheLastSimulation() async throws {
        let model = AppModel(backend: DemoBackend(speed: 0), simulation: ScriptedSimulation(), persist: false)
        model.openExampleProject()
        model.perform(.runSimulation)
        try await until { if case .done = model.simulation.state { return true } else { return false } }
        model.closeProject()
        XCTAssertEqual(model.simulation.state, .idle)
        XCTAssertTrue(model.simulation.lines.isEmpty)
    }
}

@MainActor
final class OpenWaveformTests: XCTestCase {
    let wave = URL(fileURLWithPath: "/tmp/sim.vcd")

    func makeModel() -> AppModel { AppModel(backend: DemoBackend(speed: 0), persist: false) }

    func testAViewerIsLaunchedWithTheFile() {
        let model = makeModel()
        var launched: [(String, URL)] = []
        model.findWaveformViewer = { WaveformViewer(executable: "/opt/homebrew/bin/surfer") }
        model.launchWaveformViewer = { launched.append(($0.name, $1)) }
        model.hasDefaultApp = { _ in XCTFail("a viewer was found, so the default app isn't consulted"); return false }
        model.openWaveform(wave)
        XCTAssertEqual(launched.count, 1)
        XCTAssertEqual(launched.first?.0, "surfer")
        XCTAssertEqual(launched.first?.1, wave)
        XCTAssertNil(model.errorMessage)
    }

    func testWithoutAViewerTheDefaultAppIsUsedIfThereIsOne() {
        let model = makeModel()
        var opened: [URL] = []
        model.findWaveformViewer = { nil }
        model.hasDefaultApp = { _ in true }
        model.openInDefaultApp = { opened.append($0) }
        model.openWaveform(wave)
        XCTAssertEqual(opened, [wave])
        XCTAssertNil(model.errorMessage)
    }

    func testWithNothingInstalledTheMessageSaysHowToInstallSurfer() {
        let model = makeModel()
        model.findWaveformViewer = { nil }
        model.hasDefaultApp = { _ in false }
        model.openInDefaultApp = { _ in XCTFail("nothing can open it") }
        model.openWaveform(wave)
        XCTAssertTrue(model.errorMessage?.contains("brew install surfer") == true, model.errorMessage ?? "nil")
    }

    func testAViewerThatWontStartIsReportedByName() {
        let model = makeModel()
        model.findWaveformViewer = { WaveformViewer(executable: "/opt/homebrew/bin/surfer") }
        model.launchWaveformViewer = { _, _ in throw ProgrammerError.notInstalled }
        model.openWaveform(wave)
        XCTAssertTrue(model.errorMessage?.hasPrefix("Couldn't open surfer") == true, model.errorMessage ?? "nil")
    }
}
