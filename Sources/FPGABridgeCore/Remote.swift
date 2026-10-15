import Foundation

/// Talks to the Windows machine over SSH. The remote shell is Windows' default `cmd.exe`.
public struct Remote {
    public let config: BridgeConfig

    /// Scratch directory on the Windows side, relative to the user's profile (the SSH session's working directory).
    static let remoteDir = ".fpga-bridge"

    public init(config: BridgeConfig) { self.config = config }

    var target: String { "\(config.user)@\(config.host)" }

    var sshOptions: [String] {
        var opts = ["-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new"]
        if let key = config.sshKeyPath { opts += ["-i", key] }
        return opts
    }

    /// Runs a command without prompting (key auth only), capturing output. Used for health checks.
    public func exec(_ command: String, timeout: TimeInterval = 20) throws -> CommandResult {
        try Shell.run("ssh", ["-o", "BatchMode=yes"] + sshOptions + [target, command], timeout: timeout)
    }

    /// Builds the cmd.exe line that runs Vivado in batch mode.
    /// `call` keeps cmd from stripping the quotes around a path that contains spaces.
    static func vivadoCommand(vivadoPath: String, tclFile: String) -> String {
        "call \"\(vivadoPath)\" -mode batch -nojournal -nolog -source \(tclFile)"
    }

    /// Copies a Tcl script to the Windows machine, runs it with Vivado in batch mode, and streams the output.
    /// Returns Vivado's exit status.
    public func runTcl(script: String) throws -> Int32 {
        let name = "job-\(UUID().uuidString.prefix(8)).tcl"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try script.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }

        let mkdir = try exec("if not exist \(Remote.remoteDir) mkdir \(Remote.remoteDir)")
        guard mkdir.succeeded else { throw RemoteError.ssh(mkdir.stderr) }

        let remoteRelative = "\(Remote.remoteDir)/\(name)"
        let scp = try Shell.run(
            "scp", ["-o", "BatchMode=yes"] + sshOptions + [local.path, "\(target):\(remoteRelative)"], timeout: 30)
        guard scp.succeeded else { throw RemoteError.ssh(scp.stderr) }

        let windowsPath = "\(Remote.remoteDir)\\\(name)"
        let status = try Shell.stream(
            "ssh", sshOptions + [target, Remote.vivadoCommand(vivadoPath: config.vivadoPath, tclFile: windowsPath)])
        _ = try? exec("del \(windowsPath)")
        return status
    }
}

extension Remote {
    /// Where the build's reports and bitstream land locally, relative to the project directory.
    public static let localOutputDir = "build"

    /// Copies the project to the build machine, runs Vivado, and (on success) fetches `out/` into `build/`.
    /// Returns Vivado's exit status. The live log streams to the terminal.
    public func build(project: Project, root: URL) throws -> Int32 {
        let sources = try project.resolveSources(in: root)
        let constraints = try project.resolveConstraints(in: root)

        // Stage everything in a temp dir named after the project so `scp -r` creates the right remote directory.
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("fpga-bridge-\(UUID().uuidString.prefix(8))")
        let stagedProject = stage.appendingPathComponent(project.name)
        try FileManager.default.createDirectory(at: stagedProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        for file in sources + constraints {
            let dest = stagedProject.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent(file), to: dest)
        }
        try project.buildScript(sources: sources, constraints: constraints)
            .write(to: stagedProject.appendingPathComponent("build.tcl"), atomically: true, encoding: .utf8)

        let remoteProject = "\(Remote.remoteDir)\\\(project.name)"
        let prep = try exec("if not exist \(Remote.remoteDir) mkdir \(Remote.remoteDir) & if exist \(remoteProject) rmdir /s /q \(remoteProject)")
        guard prep.succeeded else { throw RemoteError.ssh(prep.stderr) }

        print("Copying \(sources.count + constraints.count) files to \(config.host)...")
        let up = try Shell.run(
            "scp", ["-r", "-o", "BatchMode=yes"] + sshOptions + [stagedProject.path, "\(target):\(Remote.remoteDir)/"],
            timeout: 120)
        guard up.succeeded else { throw RemoteError.ssh(up.stderr) }

        print("Running Vivado...")
        let run = "cd \(remoteProject) && call \"\(config.vivadoPath)\" -mode batch -nojournal -nolog -source build.tcl"
        let status = try Shell.stream("ssh", sshOptions + [target, run])
        guard status == 0 else { return status }

        let local = root.appendingPathComponent(Remote.localOutputDir)
        try? FileManager.default.removeItem(at: local)
        let down = try Shell.run(
            "scp", ["-r", "-o", "BatchMode=yes"] + sshOptions + ["\(target):\(Remote.remoteDir)/\(project.name)/out", local.path],
            timeout: 300)
        guard down.succeeded else { throw RemoteError.ssh(down.stderr) }
        print("Results in \(Remote.localOutputDir)/")
        return 0
    }
}

public enum RemoteError: Error, CustomStringConvertible {
    case ssh(String)

    public var description: String {
        switch self {
        case .ssh(let detail): return "SSH failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
