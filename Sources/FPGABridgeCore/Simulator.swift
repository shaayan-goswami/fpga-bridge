import Foundation

/// Behavioral simulation on this Mac with Icarus Verilog. Compiles the design and testbench sources with `iverilog`,
/// runs the result with `vvp`, and leaves a waveform (`.vcd`) in `<project>.sim/sim_1/behav/`, as Vivado lays it out. Verilog and SystemVerilog only.
public struct Simulator: Sendable {
    public static let compilerName = "iverilog"
    public static let runnerName = "vvp"

    /// `<project>.sim/sim_1/behav`: where Vivado keeps behavioral simulation output. Not under `build/`, which a build
    /// replaces wholesale when it fetches results.
    public static func outputDirectory(projectName: String, root: URL) -> URL {
        root.appendingPathComponent("\(projectName).sim").appendingPathComponent("sim_1").appendingPathComponent("behav")
    }

    public let iverilog: String
    public let vvp: String

    public init(iverilog: String, vvp: String) {
        self.iverilog = iverilog
        self.vvp = vvp
    }

    /// The installed simulator, or nil. Looks on `PATH`, then the usual Homebrew locations.
    public static func locate(
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        searchPaths: [String] = Programmer.defaultSearchPaths
    ) -> Simulator? {
        func find(_ name: String) -> String? {
            for directory in path.split(separator: ":").map(String.init) + searchPaths {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }
        guard let compiler = find(compilerName), let runner = find(runnerName) else { return nil }
        return Simulator(iverilog: compiler, vvp: runner)
    }

    public static func require() throws -> Simulator {
        guard let simulator = locate() else { throw SimulatorError.notInstalled }
        return simulator
    }

    /// First line of `iverilog -V`, e.g. "Icarus Verilog version 13.0 (stable) (v13_0)".
    public func version() -> String? {
        guard let result = try? Shell.run(iverilog, ["-V"]), result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Doctor line. Only a warning when missing: building and flashing work without it.
    public static func check(locate: () -> Simulator? = { Simulator.locate() }) -> Check {
        guard let simulator = locate() else {
            return Check(name: "Simulator", level: .warn, detail: "Icarus Verilog isn't installed. Run Simulation needs it: brew install icarus-verilog")
        }
        return Check(name: "Simulator", level: .ok, detail: simulator.version() ?? simulator.iverilog)
    }

    // MARK: Plan

    /// Everything needed to simulate a project, worked out before anything runs.
    public struct Plan: Equatable, Sendable {
        public let top: String
        /// Absolute paths: design sources, then simulation sources.
        public let sources: [String]
        /// Where the compiled image and waveforms go. Simulation runs with this as its working directory.
        public let directory: URL
        /// Whether we write a small module that dumps the waveform. Skipped when the testbench dumps its own, or when
        /// the project turns waveforms off.
        public let dumpsWaveform: Bool
        /// The project's simulation and language settings, resolved: absolute include folders, flags ready to use.
        public var settings = ProjectSettings()
        public var includeDirectories: [String] = []

        public var imagePath: String { directory.appendingPathComponent("\(top).vvp").path }
        public var dumpModulePath: String { directory.appendingPathComponent("__fpgabridge_dump.v").path }
        public static let dumpModuleName = "__fpgabridge_dump"
        public static let waveformName = "sim.vcd"

        /// Stop the run after this many seconds.
        public var timeLimit: TimeInterval { TimeInterval(settings.simulation.timeLimit) }

        /// Plusargs for `vvp`, after the image name.
        public var runArguments: [String] { [imagePath] + settings.simulation.runtimeArguments.split(separator: " ").map(String.init) }

        public var compileArguments: [String] {
            var args = ["-g\(settings.simulation.standard.rawValue)", "-s", top]
            if settings.simulation.allWarnings { args.append("-Wall") }
            if dumpsWaveform { args += ["-s", Plan.dumpModuleName] }
            for define in settings.language.defines { args.append("-D\(define)") }
            // The folders the sources are in, then the ones the project names for `include files.
            let sourceFolders = Set(sources.map { ($0 as NSString).deletingLastPathComponent })
            for include in (sourceFolders.sorted() + includeDirectories.filter { !sourceFolders.contains($0) }) { args += ["-I", include] }
            args += ["-o", imagePath]
            args += sources
            if dumpsWaveform { args.append(dumpModulePath) }
            return args
        }

        /// The Verilog that records every signal under the testbench.
        public var dumpModule: String {
            """
            // Generated by fpga-bridge. Records every signal under \(top) so the waveform can be viewed.
            module \(Plan.dumpModuleName);
                initial begin
                    $dumpfile("\(Plan.waveformName)");
                    $dumpvars(\(settings.simulation.waveformDepth), \(top));
                end
            endmodule

            """
        }
    }

    /// Chooses the files and the testbench top. `top` overrides the project's `simulationTop` and automatic detection.
    public static func plan(project: Project, root: URL, top requested: String? = nil) throws -> Plan {
        let simulationFiles = try project.resolveSimulationSources(in: root)
        guard !simulationFiles.isEmpty else { throw SimulatorError.noTestbench }
        let designFiles = try project.resolveSources(in: root)

        var seen = Set<String>()
        let files = (designFiles + simulationFiles).filter { seen.insert($0).inserted }
        let vhdl = files.filter { ["vhd", "vhdl"].contains(($0 as NSString).pathExtension.lowercased()) }
        guard vhdl.isEmpty else { throw SimulatorError.vhdlUnsupported(vhdl) }
        let compilable = files.filter { ["v", "sv"].contains(($0 as NSString).pathExtension.lowercased()) }

        func text(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        let top: String
        if let name = requested ?? project.simulationTop {
            guard Project.isPlain(name) else { throw SimulatorError.invalidTop(name) }
            top = name
        } else {
            let testbenchTexts = simulationFiles.filter { ["v", "sv"].contains(($0 as NSString).pathExtension.lowercased()) }.map(text)
            guard let picked = try? ProjectCreator.pickTop(from: testbenchTexts) else { throw SimulatorError.noTestbench }
            top = picked
        }

        let own = compilable.contains { text($0).contains("$dumpfile") }
        let settings = project.settings ?? ProjectSettings()
        var plan = Plan(top: top, sources: compilable.map { root.appendingPathComponent($0).path },
                        directory: outputDirectory(projectName: project.name, root: root),
                        dumpsWaveform: !own && settings.simulation.recordWaveform)
        plan.settings = settings
        plan.includeDirectories = settings.language.includeDirectories.map { root.appendingPathComponent($0).path }
        return plan
    }

    // MARK: Run

    public struct Result: Equatable, Sendable {
        public enum Stage: Equatable, Sendable { case compile, run }
        public let status: Int32
        public let stage: Stage
        /// The newest waveform written by this run, if any.
        public let waveform: URL?
        /// Simulated time at `$finish`, e.g. "2.0001 ms". Nil if the testbench never finished.
        public let finishedAt: String?

        public var succeeded: Bool { status == 0 }
        public var wasStopped: Bool { status == Shell.interruptedStatus }
        public var timedOut: Bool { status == Shell.timedOutStatus }
    }

    /// Compiles and runs. Output arrives through `output`. `timeout` bounds the run itself (a testbench with no `$finish`);
    /// without one, the project's simulation time limit applies.
    public func simulate(_ plan: Plan, stop: Shell.StopFlag, timeout: TimeInterval? = nil,
                         output: @escaping @Sendable (String) -> Void) throws -> Result {
        try FileManager.default.createDirectory(at: plan.directory, withIntermediateDirectories: true)
        // A stale waveform from an earlier run must not be mistaken for this one's.
        for old in (try? FileManager.default.contentsOfDirectory(at: plan.directory, includingPropertiesForKeys: nil)) ?? []
        where old.pathExtension == "vcd" { try? FileManager.default.removeItem(at: old) }
        if plan.dumpsWaveform { try plan.dumpModule.write(toFile: plan.dumpModulePath, atomically: true, encoding: .utf8) }

        let compile = try Shell.stream(iverilog, plan.compileArguments, in: plan.directory, stop: stop, timeout: 60, output: output)
        guard compile == 0 else { return Result(status: compile, stage: .compile, waveform: nil, finishedAt: nil) }

        let collected = Collected()
        let status = try Shell.stream(vvp, plan.runArguments, in: plan.directory, stop: stop, timeout: timeout ?? plan.timeLimit) { chunk in
            collected.append(chunk)
            output(chunk)
        }
        return Result(status: status, stage: .run, waveform: Simulator.newestWaveform(in: plan.directory),
                      finishedAt: Simulator.finishTime(in: collected.text))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ""
        func append(_ chunk: String) { lock.withLock { stored += chunk } }
        var text: String { lock.withLock { stored } }
    }

    static func newestWaveform(in directory: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "vcd" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Reads "$finish called at 2000100000 (1ps)" and says how long that is: "2.0001 ms".
    static func finishTime(in output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\$finish called at (\d+) \((\d+)(s|ms|us|ns|ps|fs)\)"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let tick = Range(match.range(at: 1), in: output).flatMap({ Double(output[$0]) }),
              let step = Range(match.range(at: 2), in: output).flatMap({ Double(output[$0]) }),
              let unit = Range(match.range(at: 3), in: output).map({ String(output[$0]) })
        else { return nil }
        let seconds: [String: Double] = ["s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15]
        let total = tick * step * (seconds[unit] ?? 1)
        for (name, scale) in [("s", 1.0), ("ms", 1e-3), ("µs", 1e-6), ("ns", 1e-9), ("ps", 1e-12), ("fs", 1e-15)] where total >= scale || name == "fs" {
            let value = total / scale
            let text = String(format: "%.4f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return "\(text) \(name)"
        }
        return nil
    }
}

public enum SimulatorError: DescribedError {
    case notInstalled
    case noTestbench
    case vhdlUnsupported([String])
    case invalidTop(String)

    public var description: String {
        switch self {
        case .notInstalled:
            return "Icarus Verilog isn't installed. Install it with: brew install icarus-verilog"
        case .noTestbench:
            return "This project has no simulation sources. Add a testbench with Add Sources (Add or create simulation sources)."
        case .vhdlUnsupported(let files):
            return "Simulation supports Verilog and SystemVerilog only. VHDL files in the project: \(files.joined(separator: ", "))"
        case .invalidTop(let name):
            return "'\(name)' isn't a valid module name (letters, digits, '_' and '-' only)."
        }
    }
}
