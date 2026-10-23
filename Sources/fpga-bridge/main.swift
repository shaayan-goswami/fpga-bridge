import ArgumentParser
import FPGABridgeCore
import Foundation

extension BuildOS: ExpressibleByArgument {}

struct FPGABridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fpga-bridge",
        abstract: "Run Vivado on a remote Windows or Linux machine from your Mac, over Tailscale and SSH.",
        subcommands: [Init.self, Doctor.self, Tcl.self, New.self, Build.self, Fetch.self, Lint.self, Script.self, IPCommand.self, PartCommand.self, Sim.self, Flash.self, Boards.self, Report.self, Unlock.self]
    )
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save the build machine's details. The setup script on that machine (windows\\setup.ps1 or linux/setup.sh) prints this command for you.")

    @Option(help: "Tailscale name or IP of the build machine.") var host: String
    @Option(help: "Username on the build machine.") var user: String
    @Option(help: "Full path to Vivado on the build machine: vivado.bat on Windows, the vivado script on Linux.") var vivado: String
    @Option(help: "SSH private key to use (default: ssh's usual keys).") var key: String?
    @Option(help: "Build machine's operating system: windows or linux. Default: worked out from the Vivado path.") var os: BuildOS?

    func run() throws {
        let config = BridgeConfig(host: host, user: user, vivadoPath: vivado, sshKeyPath: key, os: os)
        try config.save()
        print("Saved \(BridgeConfig.defaultURL.path) (build machine: \(config.buildOS.displayName))")
        print("Next: fpga-bridge doctor")
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Tailscale, SSH and Vivado end to end.")

    func run() throws {
        let config = try BridgeConfig.load()
        let checks = FPGABridgeCore.Doctor.run(config: config) + [Programmer.check(), Simulator.check(), WaveformViewer.check()]
        for check in checks {
            let mark = check.level == .ok ? "ok  " : check.level == .warn ? "warn" : "FAIL"
            print("[\(mark)] \(check.name): \(check.detail)")
        }
        if checks.contains(where: { $0.level == .fail }) { throw ExitCode.failure }
    }
}

struct Tcl: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a Tcl script in Vivado batch mode on the build machine.")

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
        abstract: "Copy the project to the build machine, run Vivado, and fetch the results into build/.",
        discussion: """
            Runs synthesis, implementation and the bitstream in one Vivado session. Each run leaves its checkpoint on the \
            build machine, which the app's separate runs start from.

            Exit status: 0 when the bitstream was built; Vivado's own status (usually 1) when a step failed, which is \
            named; 2 with --strict when the design doesn't meet timing; 130 when cancelled with Ctrl-C.
            """)

    @Flag(help: "Exit with status 2 when the design doesn't meet timing (or no timing report came back).") var strict = false
    @Flag(help: "When another build holds the build machine, wait for it to finish instead of failing.") var wait = false

    func run() throws {
        let config = try BridgeConfig.load()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try Project.load(from: root)
        let result = try Build.runWaiting(wait) { try Remote(config: config).run(RunKind.flow, project: project, root: root) }
        if result.status == Shell.interruptedStatus { throw ExitCode(result.status) }
        guard result.status == 0 else {
            let step = result.failed ?? .synthesis
            printError("\n\(step == .bitstream ? "Bitstream generation" : step.title) failed (\(step.stepName)): Vivado stopped with an error. Its messages are above.")
            throw ExitCode(result.status)
        }
        print("")
        let out = root.appendingPathComponent(Remote.localOutputDir)
        let summary = BuildSummary.load(from: out)
        print(summary.render())
        if let manifest = BuildManifest.load(from: out) {
            let changes = manifest.changes(project: project, root: root)
            print("Sources    \(manifest.sourceID)" + (manifest.git.map { "   git \($0.commit.prefix(8))\($0.uncommittedChanges ? " + uncommitted changes" : "")" } ?? ""))
            if !changes.isEmpty {
                print("Warning: changed while building, so not in this bitstream: \(changes.joined(separator: ", ")). Build again to include them.")
            }
        }
        if strict, summary.timing?.constraintsMet != true {
            printError(summary.timing == nil ? "No timing report came back (--strict)." : "Timing is not met (--strict).")
            throw ExitCode(2)
        }
    }

    /// Runs `body`, and with `wait`, retries every 20 seconds while another build holds the build machine.
    static func runWaiting<T>(_ wait: Bool, _ body: () throws -> T) throws -> T {
        var announced = false
        while true {
            do {
                return try body()
            } catch RemoteError.busy(let owner) where wait {
                if !announced {
                    print("The build machine is busy (\(owner ?? "an unknown build")). Waiting for it to finish... (Ctrl-C gives up)")
                    announced = true
                }
                Thread.sleep(forTimeInterval: 20)
            }
        }
    }
}

func printError(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

struct Fetch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Collect the results of the last build on the build machine, after its connection was lost.",
        discussion: """
            Vivado keeps running when the connection to it drops. Once it has finished, this merges the results into \
            build/ as the build would have. If it didn't finish, the end of Vivado's log on the build machine is shown.
            """)

    @Flag(help: "When a build still holds the build machine, wait for it to finish.") var wait = false

    func run() throws {
        let config = try BridgeConfig.load()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try Project.load(from: root)
        let result: Remote.FetchResult
        do {
            result = try Build.runWaiting(wait) { try Remote(config: config).fetch(project: project, root: root) }
        } catch RemoteError.busy(let owner) {
            printError("A build is still running on \(config.host) (\(owner ?? "unknown")). Try again when it has finished, or use --wait.")
            throw ExitCode.failure
        }
        switch result {
        case .fetched:
            print("")
            print(BuildSummary.load(from: root.appendingPathComponent(Remote.localOutputDir)).render())
        case .notFinished(let log):
            printError("The last build of \(project.name) on \(config.host) didn't finish: it failed or was stopped.")
            if let log { printError("The end of its log:\n\(log)") }
            throw ExitCode.failure
        }
    }
}

struct Lint: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run Vivado's RTL linter on the project and list what it finds (Run Linter).")

    func run() throws {
        let config = try BridgeConfig.load()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try Project.load(from: root)
        let (status, report, log) = try Remote(config: config).lint(project: project, root: root) { _ in }
        if status != 0 || !report.finished {
            print(log)
            throw ValidationError("The linter didn't finish. Vivado's output is above.")
        }
        if report.messages.isEmpty {
            print("No linter messages.")
            return
        }
        for m in report.messages {
            let place = [m.file, m.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
            print("\(m.severity)  \(m.rule)  \(m.text)\(place.isEmpty ? "" : "  (\(place))")")
        }
        print("\n\(report.messages.count) linter message\(report.messages.count == 1 ? "" : "s").")
    }
}

struct IPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ip",
        abstract: "Browse Vivado's IP catalog and add IP to the project.",
        discussion: """
            IP is recreated by every build from what the project file records (its type and the settings that differ from \
            the defaults), so there is no .xci file to manage. Each build regenerates and synthesizes it, which takes a \
            minute or so per IP.
            """,
        subcommands: [List.self, Config.self, Add.self, Remove.self, Show.self])

    static func service() throws -> IPService { IPService(remote: Remote(config: try BridgeConfig.load())) }

    static func project() throws -> (Project, URL) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return (try Project.load(from: root), root)
    }

    /// Finds an IP by exact VLNV, or by name (the newest version if there are several).
    static func find(_ query: String, in catalog: IPCatalog) throws -> IPDefinition {
        if let exact = catalog.definitions.first(where: { $0.vlnv == query }) { return exact }
        let named = catalog.definitions.filter { $0.name == query }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        if let newest = named.first { return newest }
        throw ValidationError("No IP named '\(query)'. Try: fpga-bridge ip list \(query)")
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the IP in the catalog, optionally matching words.")
        @Argument(help: "Words to look for in the name and description.") var query: [String] = []
        @Flag(help: "Include IP that doesn't support the project's device.") var all = false
        @Flag(help: "Ask the build machine again instead of using the saved catalog.") var refresh = false

        func run() throws {
            let (project, _) = try IPCommand.project()
            let catalog = try IPCommand.service().catalog(part: project.part, refresh: refresh)
            let found = catalog.search(query.joined(separator: " "), onlySupported: !all)
            for ip in found { print("\(ip.displayName)  (\(ip.name) \(ip.version))  \(ip.categories.joined(separator: "/"))") }
            print("\n\(found.count) of \(catalog.definitions.count) IP" + (all ? "" : " for \(project.part). Use --all to include the rest."))
        }
    }

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show an IP's settings and their default values.")
        @Argument(help: "The IP's name or full vendor:library:name:version.") var ip: String
        @Flag(name: .customLong("tcl"), help: "Print the Tcl that would be run on the build machine, without running it.") var printScript = false

        func run() throws {
            let (project, _) = try IPCommand.project()
            let service = try IPCommand.service()
            let definition = try IPCommand.find(ip, in: try service.catalog(part: project.part))
            if printScript { print(IPScripts.propertiesScript(vlnv: definition.vlnv, part: project.part)); return }
            print("\(definition.displayName)  \(definition.vlnv)\n")
            for p in try service.properties(of: definition, part: project.part) { print("\(p.name) = \(p.value)") }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an IP to the project and print its instantiation template.")
        @Argument(help: "The IP's name or full vendor:library:name:version.") var ip: String
        @Option(help: "What to call it in the design (the module name to instantiate).") var name: String
        @Option(name: .customLong("set"), parsing: .upToNextOption, help: "Settings that differ from the defaults, e.g. CONFIG.Output_Width=8.") var settings: [String] = []

        func run() throws {
            var (project, root) = try IPCommand.project()
            let service = try IPCommand.service()
            let definition = try IPCommand.find(ip, in: try service.catalog(part: project.part))
            var config: [String: String] = [:]
            for pair in settings {
                guard let eq = pair.firstIndex(of: "=") else { throw ValidationError("'\(pair)' should look like CONFIG.Name=value") }
                config[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            }
            let new = ProjectIP(name: name, vlnv: definition.vlnv, config: config)
            try new.validate()
            guard !(project.ips ?? []).contains(where: { $0.name == name }) else { throw ValidationError("The project already has an IP called '\(name)'.") }
            // Generate its template first: Vivado checks the settings there, so a bad value is caught before anything is saved.
            let template = try service.template(for: new, part: project.part)
            project.ips = (project.ips ?? []) + [new]
            try project.validate()
            try project.save(to: root)
            print("Added \(definition.displayName) as '\(name)'.\n")
            print(IPScripts.cutSection(of: project.targetLanguage == "VHDL" ? template.vhdlTemplate : template.verilogTemplate))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an IP from the project.")
        @Argument(help: "The IP's instance name.") var name: String

        func run() throws {
            var (project, root) = try IPCommand.project()
            guard (project.ips ?? []).contains(where: { $0.name == name }) else { throw ValidationError("The project has no IP called '\(name)'.") }
            project.ips = (project.ips ?? []).filter { $0.name != name }
            if project.ips?.isEmpty == true { project.ips = nil }
            try project.save(to: root)
            print("Removed '\(name)'. Take its instantiation out of your HDL too.")
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print an IP's instantiation template and settings.")
        @Argument(help: "The IP's instance name.") var name: String
        @Flag(name: .customLong("tcl"), help: "Print the Tcl that would be run on the build machine, without running it.") var printScript = false

        func run() throws {
            let (project, _) = try IPCommand.project()
            guard let ip = (project.ips ?? []).first(where: { $0.name == name }) else { throw ValidationError("The project has no IP called '\(name)'.") }
            if printScript { print(IPScripts.templateScript(ip: ip, part: project.part)); return }
            print("\(ip.vlnv)")
            for key in ip.config.keys.sorted() { print("  \(key) = \(ip.config[key] ?? "")") }
            let template = try IPCommand.service().template(for: ip, part: project.part)
            print("\n" + IPScripts.cutSection(of: project.targetLanguage == "VHDL" ? template.vhdlTemplate : template.verilogTemplate))
        }
    }
}

struct PartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "part",
        abstract: "Fetch and show a part's package pins, I/O banks and die layout (what the Package and Device views draw).",
        discussion: """
            The data comes from Vivado on the build machine once per part (about a minute) and is kept in \
            ~/Library/Application Support/fpga-bridge/parts, so the views work offline afterwards.
            """)

    @Argument(help: "The part, e.g. xc7a35tcpg236-1. Default: the project's part.") var part: String?
    @Flag(help: "Ask the build machine again instead of using the saved copy.") var refresh = false
    @Flag(help: "List every package pin.") var pins = false
    @Flag(name: .customLong("tcl"), help: "Print the Tcl that would be run on the build machine, without running it.") var printScript = false

    func run() throws {
        let part = try part ?? Project.load(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).part
        if printScript {
            print(PartData.dumpScript(part: part))
            return
        }
        let data: PartData
        if !refresh, let cached = PartData.cached(part: part) {
            data = cached
        } else {
            print("Asking Vivado on the build machine about \(part)...")
            data = try PartDataService(remote: Remote(config: try BridgeConfig.load())).partData(part: part, refresh: true)
        }
        print("\(data.part): \(data.family) \(data.device), package \(data.package), speed \(data.speed) (Vivado \(data.vivado))")
        let user = data.pins.filter { $0.kind == .userIO }
        print("\(data.pins.count) package pins, \(user.count) user I/O; die \(data.gridWidth) × \(data.gridHeight) tiles, "
              + "\(data.tiles.reduce(0) { $0 + $1.sites.count }) sites, \(data.regions.count) clock regions")
        for bank in data.banks {
            let count = data.pins.filter { $0.bank == bank.name && $0.kind == .userIO }.count
            print("  Bank \(bank.name.padding(toLength: 4, withPad: " ", startingAt: 0)) \(bank.type.title.padding(toLength: 17, withPad: " ", startingAt: 0)) \(count) user I/O")
        }
        if pins {
            for pin in data.pins.sorted(by: { ($0.row.count, $0.row, $0.column) < ($1.row.count, $1.row, $1.column) }) {
                let extras = [pin.isClockCapable ? "clock-capable" : nil, pin.diffPair.isEmpty ? nil : (pin.isPositive ? "P of " : "N of ") + pin.diffPair,
                              pin.isVREF ? "VREF" : nil].compactMap { $0 }
                print("  \(pin.name.padding(toLength: 5, withPad: " ", startingAt: 0)) \(pin.bank.padding(toLength: 4, withPad: " ", startingAt: 0)) "
                      + "\(pin.function.padding(toLength: 28, withPad: " ", startingAt: 0)) \(extras.joined(separator: ", "))")
            }
        }
    }
}

extension RunKind: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument {
        case "synth", "synth_1", "synthesis": self = .synthesis
        case "impl", "impl_1", "implementation": self = .implementation
        case "bitstream", "write_bitstream": self = .bitstream
        default: return nil
        }
    }
}

struct Script: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the Vivado Tcl script that `build` would run, including the project's settings.")

    @Option(help: "Print the script for one step on its own instead: synth, impl or bitstream.") var step: RunKind?

    func run() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try Project.load(from: root)
        print(project.flowScript(steps: step.map { [$0] } ?? RunKind.flow, sources: try project.resolveSources(in: root),
                                 constraints: try project.resolveConstraints(in: root)), terminator: "")
    }
}

struct Sim: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Simulate the project's testbench on this Mac with Icarus Verilog.",
        discussion: """
            Runs the project's design and simulation sources (Verilog and SystemVerilog) and leaves a waveform in \
            <project>.sim/sim_1/behav/sim.vcd, which Surfer can open (--open does it). Needs: brew install icarus-verilog
            """)

    @Option(help: "Testbench module to simulate. Default: the project's simulationTop, or the one nothing instantiates.") var top: String?
    @Option(help: "Stop a simulation that hasn't finished after this many seconds. Default: the project's simulation time limit (120 s).") var timeout: Double?
    @Flag(name: .customLong("open"), help: "Open the waveform in Surfer (or GTKWave) when the simulation finishes.") var openWaveform = false

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
        let limit = timeout ?? plan.timeLimit
        let result = try simulator.simulate(plan, stop: stop, timeout: limit) { chunk in
            FileHandle.standardOutput.write(Data(chunk.utf8))
        }
        print("")
        if result.succeeded {
            print("Simulation finished" + (result.finishedAt.map { " at \($0) of simulated time" } ?? ""))
            if let waveform = result.waveform { print("Waveform: \(waveform.path)") }
            if openWaveform, let waveform = result.waveform {
                guard let viewer = WaveformViewer.locate() else { throw WaveformViewerError.notInstalled }
                try viewer.open(waveform)
            }
            return
        }
        if result.wasStopped { print("Stopped.") }
        else if result.timedOut { print("Timed out after \(Int(limit)) seconds. Does the testbench call $finish?") }
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

        // What the bitstream was built from, and anything that no longer matches, before it goes on the board.
        let buildFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        if let manifest = BuildManifest.load(from: buildFolder) {
            let changes = project.map { manifest.changes(project: $0, root: root) } ?? []
            let summary = manifest.summary(changes: changes, project: project, devicePart: nil)
            for line in summary.lines { print(line) }
            for warning in summary.warnings { print("Warning: \(warning)") }
        } else {
            print("No build record next to this bitstream, so what it was built from is unknown.")
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
        abstract: "Release the build lock on the build machine.",
        discussion: "Only one build runs on the build machine at a time. Use this if a build was lost (crash, dropped connection) and left the lock behind.")

    func run() throws {
        try Remote(config: try BridgeConfig.load()).unlock()
        print("Build lock released.")
    }
}

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the timing and utilization summary from the last build, with the worst failing paths when timing isn't met.")

    @Option(help: "How many failing setup and hold paths to list when timing isn't met.")
    var paths = BuildSummary.failingPathsShown

    func run() throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(Remote.localOutputDir)
        let summary = BuildSummary.load(from: dir)
        print(summary.render(maxPaths: paths))
        if summary.timing == nil && summary.utilization == nil { throw ExitCode.failure }
    }
}

FPGABridge.main()
