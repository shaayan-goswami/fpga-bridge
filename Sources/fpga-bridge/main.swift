import ArgumentParser
import FPGABridgeCore
import Foundation

struct FPGABridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fpga-bridge",
        abstract: "Run Vivado on a remote Windows machine from your Mac, over Tailscale and SSH.",
        subcommands: [Init.self, Doctor.self, Tcl.self, New.self, Build.self, Report.self, Unlock.self]
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
        let checks = FPGABridgeCore.Doctor.run(config: config)
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
