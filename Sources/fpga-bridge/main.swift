import ArgumentParser
import FPGABridgeCore
import Foundation

struct FPGABridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fpga-bridge",
        abstract: "Run Vivado on a remote Windows machine from your Mac, over Tailscale and SSH.",
        subcommands: [Init.self, Doctor.self, Tcl.self, New.self, Build.self, Sim.self, Flash.self, Boards.self, Report.self, Unlock.self]
    )
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save the Windows machine's details. windows\\setup.ps1 prints this command for you.")

    @Option(help: "Tailscale name or IP of the Windows machine.") var host: String
    @Option(help: "Windows username.") var user: String
    @Option(help: "Full path to vivado.bat on Windows.") var vivado: String
    @Option(help: "SSH private key to use (default: ssh's usual keys).") var key: String?

    func run() throws {
        let config = BridgeConfig(host: host, user: user, vivadoPath: vivado, sshKeyPath: key)
        try config.save()
        print("Saved \(BridgeConfig.defaultURL.path)")
        print("Next: fpga-bridge doctor")
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Tailscale, SSH and Vivado end to end.")

    func run() throws {
        let config = try BridgeConfig.load()
        let checks = FPGABridgeCore.Doctor.run(config: config) + [Programmer.check(), Simulator.check()]
        for check in checks {
            let mark = check.level == .ok ? "ok  " : check.level == .warn ? "warn" : "FAIL"
            print("[\(mark)] \(check.name): \(check.detail)")
        }
        if checks.contains(where: { $0.level == .fail }) { throw ExitCode.failure }
    }
}

struct Tcl: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a Tcl script in Vivado batch mode on the Windows machine.")

    @Argument(help: "Path to a local .tcl file.") var file: String?
    @Option(name: .shortAndLong, help: "Inline Tcl to run instead of a file.") var command: String?

    func validate() throws {
        if (file == nil) == (command == nil) {
            throw ValidationError("Provide either a .tcl file or -c '<tcl>'.")
        }
    }

    func run() throws {
        let config = try BridgeConfig.load()
        let script: String
        if let command {
            script = command
        } else if let file {
            script = try String(contentsOfFile: file, encoding: .utf8)
        } else {
            return
        }
        let status = try Remote(config: config).runTcl(script: script)
        if status != 0 { throw ExitCode(status) }
    }
}

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create fpga-bridge.json in the current directory.")

    @Option(help: "Top module name.") var top: String?
    @Option(help: "Board id, e.g. basys3. See --list-boards.") var board: String?
    @Option(help: "Vivado part, e.g. xc7a35tcpg236-1. Use instead of --board for other hardware.") var part: String?
    @Flag(help: "Print the supported boards and exit.") var listBoards = false
    @Option(parsing: .upToNextOption, help: "Source files or directories.") var sources: [String] = ["."]
    @Option(parsing: .upToNextOption, help: "Constraint (.xdc) files or directories.") var constraints: [String] = ["."]
    @Option(help: "Project name (default: directory name).") var name: String?
    @Option(help: "Pin the Vivado version this project builds with, e.g. 2023.2. Builds warn if the build machine differs.")
    var vivadoVersion: String?

    func validate() throws {
        if listBoards { return }
        if top == nil { throw ValidationError("--top is required.") }
        if (board == nil) == (part == nil) { throw ValidationError("Provide exactly one of --board or --part.") }
    }

    func run() throws {
        if listBoards {
            print(BoardCatalog.table())
            return
        }
        let resolvedBoard: Board?
        if let board {
            guard let found = BoardCatalog.lookup(board) else {
                let hints = BoardCatalog.suggestions(for: board).map(\.id)
                let tip = hints.isEmpty ? "Run `fpga-bridge new --list-boards`." : "Did you mean: \(hints.joined(separator: ", "))?"
                throw ValidationError("Unknown board '\(board)'. \(tip)")
            }
            resolvedBoard = found
        } else {
            resolvedBoard = nil
        }
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let derived = dir.lastPathComponent.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let project = Project(name: name ?? String(derived), top: top ?? "", part: resolvedBoard?.part ?? part ?? "",
                              sources: sources, constraints: constraints, board: resolvedBoard?.id,
                              vivadoVersion: vivadoVersion)
        try project.validate()
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(Project.fileName).path) {
            throw ValidationError("\(Project.fileName) already exists here.")
        }
        try project.save(to: dir)
        print("Wrote \(Project.fileName). Next: fpga-bridge build")
    }
}

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy the project to the build machine, run Vivado, and fetch the results into build/.")

    func run() throws {
        let config = try BridgeConfig.load()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try Project.load(from: root)
        let status = try Remote(config: config).build(project: project, root: root)
        if status != 0 { throw ExitCode(status) }
        print("")
        print(BuildSummary.load(from: root.appendingPathComponent(Remote.localOutputDir)).render())
    }
}

struct Sim: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Simulate the project's testbench on this Mac with Icarus Verilog.",
        discussion: """
            Runs the project's design and simulation sources (Verilog and SystemVerilog) and leaves a waveform in \
            build/sim/sim.vcd, which Surfer or GTKWave can open. Needs: brew install icarus-verilog
            """)

    @Option(help: "Testbench module to simulate. Default: the project's simulationTop, or the one nothing instantiates.") var top: String?
    @Option(help: "Stop a simulation that hasn't finished after this many seconds.") var timeout: Double = 120

    func run() throws {
        let simulator = try Simulator.require()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let plan = try Simulator.plan(project: try Project.load(from: root), root: root, top: top)

        // Ctrl-C stops the simulation instead of leaving it running.
        let stop = Shell.StopFlag()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { stop.set() }
        source.resume()
        defer { source.cancel() }

        print("Simulating \(plan.top) (\(plan.sources.count) files)")
        fflush(stdout)
        let result = try simulator.simulate(plan, stop: stop, timeout: timeout) { chunk in
            FileHandle.standardOutput.write(Data(chunk.utf8))
        }
        print("")
        if result.succeeded {
            print("Simulation finished" + (result.finishedAt.map { " at \($0) of simulated time" } ?? ""))
            if let waveform = result.waveform { print("Waveform: \(waveform.path)") }
            return
        }
        if result.wasStopped { print("Stopped.") }
        else if result.timedOut { print("Timed out after \(Int(timeout)) seconds. Does the testbench call $finish?") }
        else { print(result.stage == .compile ? "Compile failed." : "Simulation failed (exit status \(result.status)).") }
        throw ExitCode(result.status == 0 ? 1 : result.status)
    }
}

struct Flash: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Program the board plugged into this Mac with the last built bitstream.",
        discussion: """
            Uses openFPGALoader (brew install openfpgaloader). By default the design is loaded into the FPGA and is \
            lost at power-off; --persist writes the board's flash so it loads at every power-on.
            """)

    @Argument(help: "A .bit file. Default: build/<top>.bit from the last build.") var bitstream: String?
    @Option(help: "Board id (see `fpga-bridge boards --list`). Default: the board the project was created for.") var board: String?
    @Flag(help: "Write the board's flash instead of loading the FPGA directly.") var persist = false

    func run() throws {
        let programmer = try Programmer.require()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try? Project.load(from: root)

        let boardID = board ?? project?.board
        var selected: Board?
        if let boardID {
            guard let found = BoardCatalog.lookup(boardID) else {
                throw ValidationError("Unknown board '\(boardID)'. See `fpga-bridge boards --list`.")
            }
            selected = found
        }

        let path: String
        if let bitstream {
            guard FileManager.default.fileExists(atPath: bitstream) else { throw ProgrammerError.noBitstream(bitstream) }
            path = bitstream
        } else {
            guard let project else { throw ProjectError.missing(root.appendingPathComponent(Project.fileName).path) }
            path = try Programmer.bitstreamPath(for: project, root: root)
        }

        print("Programming \(selected?.displayName ?? "the connected board") with \(path)" + (persist ? " (flash)" : ""))
        fflush(stdout)  // so this line comes before the loader's output when piped
        let status = try programmer.program(bitstream: path, board: selected, target: persist ? .flash : .sram)
        if status != 0 { throw ExitCode(status) }
    }
}

struct Boards: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the boards plugged into this Mac, or list the boards this tool knows.")

    @Flag(help: "List the supported boards instead of probing USB.") var list = false

    func run() throws {
        if list {
            print(BoardCatalog.table())
            return
        }
        let programmer = try Programmer.require()
        let devices = try programmer.detect()
        guard !devices.isEmpty else {
            print("No board found. Check the USB cable (use a data cable) and that the board's power switch is on.")
            throw ExitCode.failure
        }
        for device in devices {
            print("Found \(device.family) (\(device.model)), idcode \(device.idcode)")
            let matches = Programmer.boards(matching: device).map(\.displayName)
            if !matches.isEmpty { print("  Could be: \(matches.joined(separator: ", "))") }
        }
    }
}

struct Unlock: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Release the build lock on the Windows machine.",
        discussion: "Only one build runs on the build machine at a time. Use this if a build was lost (crash, dropped connection) and left the lock behind.")

    func run() throws {
        try Remote(config: try BridgeConfig.load()).unlock()
        print("Build lock released.")
    }
}

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the timing and utilization summary from the last build.")

    func run() throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(Remote.localOutputDir)
        let summary = BuildSummary.load(from: dir)
        print(summary.render())
        if summary.timing == nil && summary.utilization == nil { throw ExitCode.failure }
    }
}

FPGABridge.main()
