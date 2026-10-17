import FPGABridgeCore
import Foundation

struct RunOutcome {
    /// Steps that are now complete. A live run currently completes all of them at once.
    var completed: Set<RunKind> = []
    var failed = false
    var cancelled = false
    var reports: [ReportFile] = []
    /// What the build wrote about the design at each stage, for the design views.
    var designs: [DesignStage: DesignSnapshot] = [:]
}

/// Where runs and Tcl commands go: a real build machine, or a simulation when none is configured.
protocol Backend: AnyObject, Sendable {
    var isDemo: Bool { get }
    var hostName: String { get }
    var vivadoPath: String? { get }
    /// Whether a running step can be stopped from the app.
    var canStop: Bool { get }
    func checkConnection() async -> ConnectionState
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome
    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async
    /// Run Linter: Vivado's RTL linter on the project's sources.
    func lint(project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> Result<LintReport, LintFailure>
}

/// Why a linter run produced no report, with Vivado's output to show.
struct LintFailure: Error, Equatable {
    let message: String
    var log = ""
}

extension Backend {
    func lint(project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> Result<LintReport, LintFailure> {
        .failure(LintFailure(message: "This build machine can't run the linter."))
    }
}

// MARK: Demo

final class DemoBackend: Backend, Sendable {
    let isDemo = true
    let hostName = "buildbox"
    let vivadoPath: String? = #"C:\Xilinx\Vivado\2023.2\bin\vivado.bat"#
    let canStop = true
    /// Multiplies the simulated delays (0 = instant).
    let speed: Double

    init(speed: Double = 1) { self.speed = speed }

    func checkConnection() async -> ConnectionState { .demo }

    /// Sample findings, so Run Linter can be tried without a build machine.
    func lint(project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> Result<LintReport, LintFailure> {
        if speed > 0 { try? await Task.sleep(nanoseconds: UInt64(1.5 * speed * 1_000_000_000)) }
        let top = ((try? project.resolveSources(in: directory)) ?? []).first.map { ($0 as NSString).lastPathComponent } ?? "top.v"
        let text = """
            | Rule ID   | Severity | # Violations | # Waived |
            +-----------+----------+--------------+----------+
            | ASSIGN-10 | WARNING  | 1            | 0        |
            +-----------+----------+--------------+----------+
            WARNING: [Synth 37-125] [ASSIGN-10]Some bits in IO 'sw' are not read. First unread bit index is 2.
            RTL Name 'sw', Hierarchy '\(project.top)', File '\(top)', Line 1.
            INFO: [Synth 37-45] Linter Run Finished!
            """
        return .success(LintReport.parse(log: text))
    }

    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
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
        var outcome = RunOutcome(completed: [step], reports: DemoData.reports(for: step))
        if step != .bitstream {
            let stages: [DesignStage] = step == .synthesis ? [.rtl, .synth] : [.rtl, .synth, .impl]
            outcome.designs = Dictionary(uniqueKeysWithValues: stages.map { ($0, DemoData.design(stage: $0, project: project, sources: sources, directory: directory)) })
        }
        return outcome
    }

    /// A handful of commands, enough to show how the console behaves.
    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {
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

// MARK: No build machine

/// Why a Vivado command can't run when no build machine is set up.
struct NoBuildMachine: DescribedError {
    static let message = "No build machine is set up, so Vivado's steps can't run. Writing code, simulating and "
        + "programming a board work on this Mac. To build, run `fpga-bridge init` and reopen the app."
    var description: String { Self.message }
}

/// Used when no build machine is configured: the app is still a Verilog editor and simulator, and still programs a
/// board with a bitstream from elsewhere. Anything that needs Vivado says why it can't run.
final class LocalBackend: Backend, Sendable {
    let isDemo = false
    let hostName = "No build machine"
    let vivadoPath: String? = nil
    let canStop = false
    /// Why the config on this Mac couldn't be used, when there is one.
    let configProblem: String?

    init(configProblem: String? = nil) { self.configProblem = configProblem }

    func checkConnection() async -> ConnectionState { configProblem.map { .offline($0) } ?? .notConfigured }

    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        log("ERROR: \(NoBuildMachine.message)\n")
        return RunOutcome(failed: true)
    }

    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {
        log("ERROR: \(NoBuildMachine.message)\n")
    }

    func lint(project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> Result<LintReport, LintFailure> {
        .failure(LintFailure(message: NoBuildMachine.message))
    }
}

// MARK: Live

final class LiveBackend: Backend, Sendable {
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
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        let config = config
        return await Task.detached {
            do {
                let status = try Remote(config: config).build(project: project, root: directory, log: log)
                if status == Shell.interruptedStatus { return RunOutcome(cancelled: true) }
                guard status == 0 else { return RunOutcome(failed: true) }
                let out = directory.appendingPathComponent(Remote.localOutputDir)
                var outcome = RunOutcome(completed: [.synthesis, .implementation, .bitstream], reports: LiveBackend.reports(in: out))
                for stage in DesignStage.allCases {
                    if let snapshot = try? DesignSnapshot.load(stage: stage, from: out) { outcome.designs[stage] = snapshot }
                }
                return outcome
            } catch {
                log("ERROR: \(error.userMessage)\n")
                return RunOutcome(failed: true)
            }
        }.value
    }

    func lint(project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> Result<LintReport, LintFailure> {
        let config = config
        return await Task.detached {
            do {
                let (status, report, output) = try Remote(config: config).lint(project: project, root: directory, log: log)
                if status == Shell.interruptedStatus { return .failure(LintFailure(message: "The linter was stopped.")) }
                guard status == 0, report.finished else {
                    return .failure(LintFailure(message: "The linter didn't finish (Vivado exited with status \(status)).", log: output))
                }
                return .success(report)
            } catch {
                return .failure(LintFailure(message: error.userMessage))
            }
        }.value
    }

    /// Every report the build fetched. Synthesis reports start with `synth_`; the rest are from implementation.
    static func reports(in directory: URL) -> [ReportFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".rpt") }.sorted().compactMap { name in
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
                .map { ReportFile(run: DesignReportKind.stage(ofFile: name) == .impl ? .implementation : .synthesis, name: name, text: $0) }
        }
    }

    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {
        let config = config
        await Task.detached {
            do { _ = try Remote(config: config).runTcl(script: command, log: log) } catch { log("ERROR: \(error.userMessage)\n") }
        }.value
    }
}
