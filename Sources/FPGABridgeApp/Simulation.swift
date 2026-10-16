import FPGABridgeCore
import Foundation
import SwiftUI

/// How a simulation ended.
struct SimulationOutcome: Equatable {
    enum Result: Equatable { case finished, failed, stopped, timedOut }
    var result: Result
    /// Where it stopped, when it didn't finish: compiling or running.
    var stage: Simulator.Result.Stage = .run
    var top: String
    var waveform: URL?
    /// Simulated time at `$finish`, e.g. "2.0001 ms".
    var finishedAt: String?
}

/// Where simulations run: Icarus Verilog on this Mac, or a pretend one for Demo Mode and the tests.
protocol SimulationBackend: AnyObject, Sendable {
    var isDemo: Bool { get }
    func run(project: Project, directory: URL, stop: Shell.StopFlag, log: @escaping @Sendable (String) -> Void) async -> SimulationOutcome
}

final class LiveSimulation: SimulationBackend, Sendable {
    let isDemo = false

    func run(project: Project, directory: URL, stop: Shell.StopFlag, log: @escaping @Sendable (String) -> Void) async -> SimulationOutcome {
        await Task.detached {
            var top = project.simulationTop ?? ""
            do {
                let simulator = try Simulator.require()
                let plan = try Simulator.plan(project: project, root: directory)
                top = plan.top
                let result = try simulator.simulate(plan, stop: stop, output: log)
                let outcome: SimulationOutcome.Result =
                    result.succeeded ? .finished : result.wasStopped ? .stopped : result.timedOut ? .timedOut : .failed
                return SimulationOutcome(result: outcome, stage: result.stage, top: top, waveform: result.waveform, finishedAt: result.finishedAt)
            } catch {
                log("ERROR: \(error.userMessage)\n")
                return SimulationOutcome(result: .failed, stage: .compile, top: top)
            }
        }.value
    }
}

final class DemoSimulation: SimulationBackend, Sendable {
    let isDemo = true
    let speed: Double

    init(speed: Double = 1) { self.speed = speed }

    func run(project: Project, directory: URL, stop: Shell.StopFlag, log: @escaping @Sendable (String) -> Void) async -> SimulationOutcome {
        let top = "\(project.top)_tb"
        let steps: [String] = [
            "INFO: compiling \(project.top).v and \(top).v\n",
            "VCD info: dumpfile sim.vcd opened for output.\n",
            "\(top).v:14: $finish called at 2000100000 (1ps)\n",
        ]
        for step in steps {
            if speed > 0 { try? await Task.sleep(nanoseconds: UInt64(0.4 * speed * 1_000_000_000)) }
            if stop.isSet { return SimulationOutcome(result: .stopped, top: top) }
            log(step)
        }
        return SimulationOutcome(result: .finished, top: top, finishedAt: "2.0001 ms")
    }
}

/// Run Simulation: runs the testbench, keeps its log, and remembers where the waveform went.
@MainActor
final class SimulationManager: ObservableObject {
    enum State: Equatable {
        case idle
        case running(top: String?)
        case done(SimulationOutcome)
    }

    let backend: SimulationBackend

    @Published private(set) var state = State.idle
    @Published private(set) var lines: [ConsoleLine] = []
    @Published private(set) var started: Date?

    /// Where messages go (the Tcl console). Set by `AppModel`.
    var console: (String, ConsoleLine.Kind) -> Void = { _, _ in }

    private var buffer = LineBuffer()
    private var stopFlag = Shell.StopFlag()
    /// Bumped when a run starts and when the last one is forgotten. A run from an earlier generation may still be
    /// finishing; its output and result must not land in the one that replaced it.
    private var generation = 0

    init(backend: SimulationBackend) { self.backend = backend }

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Runs the project's testbench. Returns the outcome, or nil if a simulation was already running.
    @discardableResult
    func run(project: Project, directory: URL) async -> SimulationOutcome? {
        guard !isRunning else { return nil }
        generation += 1
        let mine = generation
        stopFlag = Shell.StopFlag()
        lines = []
        buffer = LineBuffer()
        started = Date()
        state = .running(top: nil)
        console("launch_simulation", .command)

        let flag = stopFlag
        // The simulator writes from its own thread. Hopping through the main queue keeps chunks in order.
        let outcome = await backend.run(project: project, directory: directory, stop: flag) { chunk in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.generation == mine { self.ingest(chunk) } } }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        guard generation == mine else { return outcome }
        for line in buffer.flush() { append(line) }

        state = .done(outcome)
        let summary: (String, ConsoleLine.Kind)
        switch outcome.result {
        case .finished: summary = ("INFO: simulation of \(outcome.top) finished" + (outcome.finishedAt.map { " at \($0)" } ?? ""), .info)
        case .stopped: summary = ("INFO: simulation stopped", .info)
        case .timedOut: summary = ("ERROR: simulation timed out. Does the testbench call $finish?", .error)
        case .failed:
            summary = (outcome.stage == .compile ? "ERROR: simulation failed to compile" : "ERROR: simulation failed", .error)
        }
        lines.append(ConsoleLine(text: summary.0, kind: summary.1))
        console(summary.0, summary.1)
        return outcome
    }

    func stop() {
        guard isRunning else { return }
        stopFlag.set()
    }

    /// Forgets the last run, e.g. when another project opens.
    func reset() {
        stopFlag.set()
        generation += 1
        state = .idle
        lines = []
    }

    private func ingest(_ chunk: String) {
        for line in buffer.append(chunk) { append(line) }
    }

    private func append(_ line: String) {
        let entry = ConsoleLine(text: line, kind: ConsoleLine.classify(line))
        lines.append(entry)
        console(line, entry.kind)
    }
}
