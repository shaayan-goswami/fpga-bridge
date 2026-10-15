import Foundation

/// Talks to the Windows machine over SSH. The remote shell is Windows' default `cmd.exe`.
public struct Remote {
    public let config: BridgeConfig

    /// Scratch directory on the Windows side, relative to the user's profile (the SSH session's working directory).
    static let remoteDir = ".fpga-bridge"

    public init(config: BridgeConfig) { self.config = config }

    var target: String { "\(config.user)@\(config.host)" }

    var sshOptions: [String] {
        // Keepalives make a dead connection fail in about a minute instead of hanging forever mid-build.
        var opts = ["-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
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

    /// Only one build runs on a build machine at a time; the lock is this directory (`mkdir` is atomic).
    static let lockDir = "\(remoteDir)\\lock"
    static let lockOwnerFile = "\(lockDir)\\owner.txt"

    /// Copies the project to the build machine, runs Vivado, and (on success) fetches `out/` into `build/`.
    ///
    /// Returns Vivado's exit status, or `Shell.interruptedStatus` if cancelled with Ctrl-C (the remote Vivado is
    /// killed first). Throws `RemoteError.busy` if another build holds the machine and `.connectionLost` if SSH
    /// drops mid-build. The live log streams to the terminal.
    public func build(project: Project, root: URL) throws -> Int32 {
        let sources = try project.resolveSources(in: root)
        let constraints = try project.resolveConstraints(in: root)
        if let warning = project.versionWarning(vivadoPath: config.vivadoPath) { print("Warning: \(warning)") }

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

        // Take the lock before touching anything remote. The release is registered only after acquiring, so a
        // failed acquire never releases someone else's lock.
        try acquireLock(project: project.name)
        defer { releaseLock() }

        let remoteProject = "\(Remote.remoteDir)\\\(project.name)"
        let prep = try exec(Remote.prepCommand(jobDir: remoteProject))
        guard prep.succeeded else { throw RemoteError.ssh(prep.stderr) }

        print("Copying \(sources.count + constraints.count) files to \(config.host)...")
        let up = try Shell.run(
            "scp", ["-r", "-o", "BatchMode=yes"] + sshOptions + [stagedProject.path, "\(target):\(Remote.remoteDir)/"],
            timeout: 120)
        guard up.succeeded else { throw RemoteError.ssh(up.stderr) }

        print("Running Vivado... (Ctrl-C cancels)")
        let token = Remote.makeJobToken()
        let run = Remote.buildCommand(vivadoPath: config.vivadoPath, jobDir: remoteProject, token: token)
        let status = try Shell.stream("ssh", sshOptions + [target, run], onInterrupt: {
            print("\nCancelling: stopping Vivado on \(config.host)...")
            cancelRemoteJob(token: token)
        })
        if status == Shell.interruptedStatus { return status }
        // ssh itself exits 255 when the connection fails; Vivado's own failures use other statuses.
        if status == 255 { throw RemoteError.connectionLost(jobDir: remoteProject) }
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

    // MARK: cmd.exe command lines
    //
    // These run on Windows through cmd.exe. CI runs them through a real cmd.exe (see .github/workflows/ci.yml), and a
    // test checks that the workflow contains exactly these strings.

    /// Creates the scratch directory if needed, then clears a previous copy of the job directory.
    /// Parentheses matter: in cmd.exe, text after `&` on an `if` line belongs to that `if`.
    static func prepCommand(jobDir: String) -> String {
        "(if not exist \(remoteDir) mkdir \(remoteDir)) & (if exist \(jobDir) rmdir /s /q \(jobDir))"
    }

    /// `mkdir` fails if the lock exists, so the owner file is only written by whoever took it.
    static func acquireLockCommand(owner: String) -> String {
        "(if not exist \(remoteDir) mkdir \(remoteDir)) & mkdir \(lockDir) && echo \(owner)> \(lockOwnerFile)"
    }

    static var readOwnerCommand: String { "type \(lockOwnerFile)" }
    static var releaseLockCommand: String { "rmdir /s /q \(lockDir)" }
    static var unlockCommand: String { "(if exist \(lockDir) rmdir /s /q \(lockDir))" }

    // MARK: Job commands

    /// A short random id that marks one Vivado run so it can be found (and killed) by command line later.
    static func makeJobToken() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    static func jobMarker(_ token: String) -> String { "fpgabridge-\(token)" }

    /// `-tclargs` puts the marker on Vivado's command line without affecting the script.
    static func buildCommand(vivadoPath: String, jobDir: String, token: String) -> String {
        "cd \(jobDir) && call \"\(vivadoPath)\" -mode batch -nojournal -nolog -source build.tcl -tclargs \(jobMarker(token))"
    }

    /// Kills every process whose command line carries the job marker, with its children (vivado.bat starts the
    /// real Vivado as a child). The marker is written as two joined strings so this command's own command line
    /// does not contain it and PowerShell doesn't kill itself or its parent first.
    static func cancelCommand(token: String) -> String {
        let marker = jobMarker(token)
        let head = String(marker.dropLast(token.count)) // "fpgabridge-"
        return "powershell -NoProfile -NonInteractive -Command \"Get-CimInstance Win32_Process"
            + " | Where-Object { $_.CommandLine -like ('*\(head)' + '\(token)*') -and $_.ProcessId -ne $PID }"
            + " | ForEach-Object { taskkill /F /T /PID $_.ProcessId }\""
    }

    func cancelRemoteJob(token: String) {
        _ = try? exec(Remote.cancelCommand(token: token), timeout: 30)
    }

    // MARK: Lock

    /// Who holds the lock, for the "machine is busy" message. Only plain characters, because it is echoed through
    /// cmd.exe, and always ends in a letter (a digit before `>` would be read as a file handle).
    static func ownerLine(project: String, date: Date = Date(),
                          machine: String = ProcessInfo.processInfo.hostName, user: String = NSUserName()) -> String {
        let formatter = ISO8601DateFormatter()
        let raw = "\(user)@\(machine) building \(project) since \(formatter.string(from: date))"
        return String(raw.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) || " @._:-".unicodeScalars.contains(scalar)
                ? Character(scalar) : "_"
        })
    }

    func acquireLock(project: String) throws {
        let owner = Remote.ownerLine(project: project)
        let result = try exec(Remote.acquireLockCommand(owner: owner))
        if result.succeeded { return }
        // 255 means SSH itself failed (bad key, host down), not that the lock exists.
        if result.status == 255 { throw RemoteError.ssh(result.stderr) }
        guard let holder = try? exec(Remote.readOwnerCommand), holder.succeeded else {
            // The lock directory exists but has no owner file (just created, or left by hand).
            throw RemoteError.busy(owner: nil)
        }
        throw RemoteError.busy(owner: holder.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func releaseLock() {
        _ = try? exec(Remote.releaseLockCommand)
    }

    /// Removes the lock regardless of who holds it. For a lock left behind by a crashed build or lost connection.
    public func unlock() throws {
        let result = try exec(Remote.unlockCommand)
        guard result.succeeded else { throw RemoteError.ssh(result.stderr) }
    }
}

public enum RemoteError: Error, CustomStringConvertible, Equatable {
    case ssh(String)
    case busy(owner: String?)
    case connectionLost(jobDir: String)

    public var description: String {
        switch self {
        case .ssh(let detail):
            return "SSH failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .busy(let owner):
            let who = owner.map { "\($0)" } ?? "an unknown build"
            return "The build machine is busy: \(who). Wait for it to finish, or run `fpga-bridge unlock` if that build is gone."
        case .connectionLost(let jobDir):
            return "Lost the connection to the build machine. Vivado may still be running there (job directory: \(jobDir)) "
                + "and the build lock may still be held; run `fpga-bridge unlock` once it is finished or stopped."
        }
    }
}
