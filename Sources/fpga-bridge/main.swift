import ArgumentParser
import FPGABridgeCore
import Foundation

struct FPGABridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fpga-bridge",
        abstract: "Run Vivado on a remote Windows machine from your Mac, over Tailscale and SSH.",
        subcommands: [Init.self, Doctor.self, Tcl.self, New.self, Build.self]
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

    @Option(help: "Top module name.") var top: String
    @Option(help: "Vivado part, e.g. xc7a35tcpg236-1 (Basys 3).") var part: String
    @Option(parsing: .upToNextOption, help: "Source files or directories.") var sources: [String] = ["."]
    @Option(parsing: .upToNextOption, help: "Constraint (.xdc) files or directories.") var constraints: [String] = ["."]
    @Option(help: "Project name (default: directory name).") var name: String?

    func run() throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let derived = dir.lastPathComponent.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let project = Project(name: name ?? String(derived), top: top, part: part, sources: sources, constraints: constraints)
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
    }
}

FPGABridge.main()
