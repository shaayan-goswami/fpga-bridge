import FPGABridgeCore
import Foundation

struct RunOutcome {
    /// Steps that are now complete. A live run currently completes all of them at once.
    var completed: Set<RunKind> = []
    var failed = false
    var cancelled = false
    var reports: [ReportFile] = []
}

/// Where runs and Tcl commands go: a real build machine, or a simulation when none is configured.
protocol Backend: AnyObject {
    var isDemo: Bool { get }
    var hostName: String { get }
    var vivadoPath: String? { get }
    /// Whether a running step can be stopped from the app.
    var canStop: Bool { get }
    func checkConnection() async -> ConnectionState
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping (String) -> Void) async -> RunOutcome
    func runTcl(_ command: String, project: Project?, log: @escaping (String) -> Void) async
}

// MARK: Demo

final class DemoBackend: Backend {
    let isDemo = true
    let hostName = "buildbox"
    let vivadoPath: String? = #"C:\Xilinx\Vivado\2023.2\bin\vivado.bat"#
    let canStop = true
    /// Multiplies the simulated delays (0 = instant).
    let speed: Double

    init(speed: Double = 1) { self.speed = speed }

    func checkConnection() async -> ConnectionState { .demo }

    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping (String) -> Void) async -> RunOutcome {
        let sources = (try? project.resolveSources(in: directory)) ?? []
        let constraints = (try? project.resolveConstraints(in: directory)) ?? []
        if step == .synthesis && sources.isEmpty {
            log("ERROR: [Synth 8-439] no design sources in the project. Use Add Sources to add some.\n")
            return RunOutcome(failed: true)
        }
        let script = DemoData.log(for: step, top: project.top, part: project.part, sources: sources, constraints: constraints)
        for (delay, text) in script {
            if speed > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * speed * 1_000_000_000)) }
            if Task.isCancelled {
                log("INFO: [Common 17-344] 'launch_runs' was cancelled\n")
                return RunOutcome(cancelled: true)
            }
            log(text)
        }
        return RunOutcome(completed: [step], reports: DemoData.reports(for: step))
    }

    /// A handful of commands, enough to show how the console behaves.
    func runTcl(_ command: String, project: Project?, log: @escaping (String) -> Void) async {
        if speed > 0 { try? await Task.sleep(nanoseconds: 150_000_000) }
        let words = command.split(separator: " ").map(String.init)
        switch words.first ?? "" {
        case "version": log("Vivado v2023.2 (64-bit)\n")
        case "puts": log(words.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"{}")) + "\n")
        case "current_project": log((project?.name ?? "") + "\n")
        case "get_property" where command.contains("PART"): log((project?.part ?? "") + "\n")
        case "get_property" where command.contains("TOP"): log((project?.top ?? "") + "\n")
        case "help":
            log("Demo mode understands: version, current_project, get_property PART|TOP [current_project], puts <text>\n")
        default: log("ERROR: [Common 17-48] invalid command name \"\(words.first ?? "")\" (demo mode)\n")
        }
    }
}

// MARK: Live

final class LiveBackend: Backend {
    let config: BridgeConfig
    let isDemo = false
    /// Stopping a live build from the app needs a cancel hook in the core (today it is Ctrl-C in the CLI).
    let canStop = false

    init(config: BridgeConfig) { self.config = config }

    var hostName: String { config.host }
    var vivadoPath: String? { config.vivadoPath }

    func checkConnection() async -> ConnectionState {
        let config = config
        let checks = await Task.detached { Doctor.run(config: config) }.value
        if let failed = checks.first(where: { $0.level == .fail }) {
            return .offline("\(failed.name): \(failed.detail)")
        }
        return .connected(config.host)
    }

    /// The build script still runs synthesis, implementation and the bitstream in one go, so any step completes
    /// all three. Separate runs with checkpoints are in the backlog.
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping (String) -> Void) async -> RunOutcome {
        let config = config
        return await Task.detached {
            do {
                let status = try Remote(config: config).build(project: project, root: directory, log: log)
                if status == Shell.interruptedStatus { return RunOutcome(cancelled: true) }
                guard status == 0 else { return RunOutcome(failed: true) }
                let out = directory.appendingPathComponent(Remote.localOutputDir)
                let reports = [BuildSummary.timingReport, BuildSummary.utilizationReport].compactMap { name in
                    (try? String(contentsOf: out.appendingPathComponent(name), encoding: .utf8))
                        .map { ReportFile(run: .implementation, name: name, text: $0) }
                }
                return RunOutcome(completed: [.synthesis, .implementation, .bitstream], reports: reports)
            } catch {
                log("ERROR: \(error)\n")
                return RunOutcome(failed: true)
            }
        }.value
    }

    func runTcl(_ command: String, project: Project?, log: @escaping (String) -> Void) async {
        let config = config
        await Task.detached {
            do { _ = try Remote(config: config).runTcl(script: command, log: log) } catch { log("ERROR: \(error)\n") }
        }.value
    }
}
