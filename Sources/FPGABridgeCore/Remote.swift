import Foundation

/// Talks to the build machine over SSH. On Windows the remote shell is `cmd.exe`; on Linux commands go through
/// `bash -lc`. `RemoteCommands` writes the lines for each.
public struct Remote: Sendable {
    public let config: BridgeConfig

    /// Scratch directory on the build machine, relative to the user's home (the SSH session's working directory).
    static let remoteDir = ".fpga-bridge"

    public init(config: BridgeConfig) { self.config = config }

    var commands: RemoteCommands { RemoteCommands(config.buildOS) }

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

    /// Builds the cmd.exe line that runs Vivado in batch mode on Windows.
    /// `call` keeps cmd from stripping the quotes around a path that contains spaces.
    static func vivadoCommand(vivadoPath: String, tclFile: String) -> String {
        "call \"\(vivadoPath)\" -mode batch -nojournal -nolog -source \(tclFile)"
    }

    /// Copies a Tcl script to the build machine, runs it with Vivado in batch mode, and streams the output.
    /// Returns Vivado's exit status.
    public func runTcl(script: String, log: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        let name = "job-\(UUID().uuidString.prefix(8)).tcl"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try script.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }

        let mkdir = try exec(commands.ensureScratch())
        guard mkdir.succeeded else { throw RemoteError.ssh(mkdir.stderr) }

        let remoteRelative = "\(Remote.remoteDir)/\(name)"
        let scp = try Shell.run(
            "scp", ["-o", "BatchMode=yes"] + sshOptions + [local.path, "\(target):\(remoteRelative)"], timeout: 30)
        guard scp.succeeded else { throw RemoteError.ssh(scp.stderr) }

        let remotePath = commands.path(Remote.remoteDir, name)
        let status = try Shell.stream(
            "ssh", sshOptions + [target, commands.vivado(vivadoPath: config.vivadoPath, tclFile: remotePath)],
            output: log)
        _ = try? exec(commands.deleteFile(remotePath))
        return status
    }
}

extension Remote {
    /// Where the build's reports and bitstream land locally, relative to the project directory.
    public static let localOutputDir = "build"

    /// Only one build runs on a build machine at a time; the lock is this directory (`mkdir` is atomic).
    static let lockDir = "\(remoteDir)\\lock"
    static let lockOwnerFile = "\(lockDir)\\owner.txt"

    /// The whole flow, synthesis to bitstream, in one Vivado session (`fpga-bridge build`): copies the project to the
    /// build machine, runs Vivado, and (on success) fetches the results into `build/`.
    ///
    /// Returns Vivado's exit status, or `Shell.interruptedStatus` if cancelled with Ctrl-C (the remote Vivado is
    /// killed first). Throws `RemoteError.busy` if another build holds the machine and `.connectionLost` if SSH
    /// drops mid-build. The live log streams to the terminal.
    ///
    /// With `log`, the progress messages and Vivado's live output go to it in chunks (for a UI). Without it they go
    /// straight to the terminal, which keeps ssh's own prompts working.
    public func build(project: Project, root: URL, log captured: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        try run(RunKind.flow, project: project, root: root, log: captured).status
    }

    /// Runs Vivado's RTL linter on the project (Run Linter). It stages the sources like a build, in a job folder of
    /// its own so a build's results on the build machine are left alone, and fetches nothing: the findings are in
    /// the log.
    /// Returns Vivado's exit status, what the linter found, and the whole log (to show when it didn't finish).
    public func lint(project: Project, root: URL, log captured: (@Sendable (String) -> Void)? = nil) throws -> (status: Int32, report: LintReport, log: String) {
        let output = OutputBox()
        let log: @Sendable (String) -> Void = { chunk in
            output.append(chunk)
            captured?(chunk)
        }
        let staged = try stage(project: project, root: root, jobName: project.name + "_lint", log: log)
        defer { staged.remove() }
        try project.lintScript(sources: staged.sources, constraints: staged.constraints)
            .write(to: staged.dir.appendingPathComponent("build.tcl"), atomically: true, encoding: .utf8)
        try acquireLock(project: project.name)
        defer { releaseLock() }
        let status = try runJob(staged, job: nil, log: log, captured: log)
        return (status, LintReport.parse(log: output.value), output.value)
    }

    /// What running steps of the flow came to.
    public struct StepResult: Equatable, Sendable {
        /// 0 when every step finished, `Shell.interruptedStatus` when stopped, otherwise Vivado's exit status.
        public var status: Int32
        /// The steps whose results are now in `build/`.
        public var completed: [RunKind] = []
        /// The step that stopped with an error.
        public var failed: RunKind?
        /// Set, and nothing run, when the first step starts from an earlier run's checkpoint and the one on the build
        /// machine is missing or was made from other files: that run has to go first.
        public var needs: CheckpointProblem?

        public var succeeded: Bool { status == 0 && needs == nil }
    }

    /// Why a step can't start from the checkpoint on the build machine.
    public struct CheckpointProblem: Equatable, Sendable {
        /// The run whose checkpoint is missing or out of date, which has to run again.
        public var run: RunKind
        public var reason: String
    }

    /// Runs consecutive steps of the flow (`[.implementation]`, or all three) in one Vivado session on the build
    /// machine, and merges their results into `build/` (see `BuildFolder.merge`). Each run's checkpoint stays on the
    /// build machine, in a folder of its own that survives between builds.
    ///
    /// When the first step starts from an earlier run's checkpoint, that checkpoint's manifest is checked first: if
    /// it is missing or was made from other files, nothing runs and the result says which run has to go first, and
    /// why. `job` lets another thread stop the run (`RemoteJob.cancel`); without it, Ctrl-C does.
    public func run(_ steps: [RunKind], project: Project, root: URL, options: Project.FlowOptions = Project.FlowOptions(),
                    job: RemoteJob? = nil, log captured: (@Sendable (String) -> Void)? = nil) throws -> StepResult {
        let log: @Sendable (String) -> Void = captured ?? { print($0, terminator: "") }
        guard let first = steps.first, let last = steps.last else { return StepResult(status: 0) }
        let staged = try stage(project: project, root: root, jobName: project.name, log: log)
        defer { staged.remove() }
        let keys = RunKeys(project: project, design: BuildManifest.fingerprint(staged.design, root: staged.dir),
                           constraints: BuildManifest.fingerprint(staged.constraints, root: staged.dir), vivadoPath: config.vivadoPath)
        let git = BuildManifest.gitState(of: root)
        func manifest(through step: RunKind) -> BuildManifest {
            BuildManifest(project: project.name, top: project.top, part: project.part, board: project.board,
                          vivadoVersion: Project.version(in: config.vivadoPath), buildMachine: config.host, builtAt: Date(),
                          files: staged.sent, git: git, runs: keys.recorded(through: step))
        }
        let runs = staged.dir.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        for step in steps where step.checkpoint != nil {
            try manifest(through: step).save(as: staged.dir.appendingPathComponent(Project.stagedManifest(step)))
        }
        try project.flowScript(steps: steps, sources: staged.sources, constraints: staged.constraints, options: options)
            .write(to: staged.dir.appendingPathComponent("build.tcl"), atomically: true, encoding: .utf8)

        if job?.isCancelled == true { return StepResult(status: Shell.interruptedStatus) }
        // Take the lock before touching anything remote. The release is registered only after acquiring, so a
        // failed acquire never releases someone else's lock.
        try acquireLock(project: project.name)
        defer { releaseLock() }

        if let earlier = first.startsFrom, let problem = try checkpointProblem(earlier, project: project, keys: keys, staged: staged) {
            return StepResult(status: 0, needs: problem)
        }
        let status = try runJob(staged, job: job, log: log, captured: captured)
        if status == Shell.interruptedStatus { return StepResult(status: status) }
        guard status == 0 else { return StepResult(status: status, failed: failedStep(steps, project: project, keys: keys, staged: staged)) }

        // Fetch next to the staged copy first, so a failed download leaves `build/` as it was.
        let incoming = staged.base.appendingPathComponent("out")
        let down = try Shell.run(
            "scp", ["-r", "-o", "BatchMode=yes"] + sshOptions + ["\(target):\(Remote.remoteDir)/\(project.name)/out", incoming.path],
            timeout: 300)
        guard down.succeeded else { throw RemoteError.ssh(down.stderr) }
        let local = root.appendingPathComponent(Remote.localOutputDir)
        try BuildFolder.merge(incoming, into: local, startingWith: first)
        var record = manifest(through: last)
        record.vivadoVersion = BuildManifest.vivadoVersion(out: local, vivadoPath: config.vivadoPath)
        try record.save(to: local)
        log("Results in \(Remote.localOutputDir)/\n")
        return StepResult(status: 0, completed: steps)
    }

    /// The project's files, copied into a temporary folder named after the job so `scp -r` creates the right remote
    /// directory, with a fingerprint of what is sent (an edit made from now on isn't in it).
    struct Staged {
        /// The temporary folder; `dir` is inside it.
        let base: URL
        let dir: URL
        let jobName: String
        let sources: [String]
        let constraints: [String]
        let includes: [String]
        /// Each file sent, with its SHA-256, and the project file.
        let sent: [String: String]

        /// What synthesis reads: the sources and the include files.
        var design: [String] { sources + includes }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    func stage(project: Project, root: URL, jobName: String, log: @Sendable (String) -> Void) throws -> Staged {
        let sources = try project.resolveSources(in: root)
        let constraints = try project.resolveConstraints(in: root)
        let includes = try project.resolveIncludeFiles(in: root).filter { !sources.contains($0) }
        guard !sources.isEmpty else {
            throw ProjectError.invalid("no design source files found. Add at least one .v, .sv or .vhd file")
        }
        if let warning = project.versionWarning(vivadoPath: config.vivadoPath) { log("Warning: \(warning)\n") }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-bridge-\(UUID().uuidString.prefix(8))")
        let dir = base.appendingPathComponent(jobName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in sources + constraints + includes {
                let dest = dir.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root.appendingPathComponent(file), to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        let sent = BuildManifest.fingerprint(sources + constraints + includes, root: dir)
            .merging(BuildManifest.fingerprint([Project.fileName], root: root)) { a, _ in a }
        return Staged(base: base, dir: dir, jobName: jobName, sources: sources, constraints: constraints, includes: includes, sent: sent)
    }

    /// Clears the job folder on the build machine, uploads the staged copy, and runs its `build.tcl` in Vivado.
    /// Returns Vivado's exit status, or `Shell.interruptedStatus` when stopped (the remote Vivado is killed first).
    func runJob(_ staged: Staged, job: RemoteJob?, log: @escaping @Sendable (String) -> Void,
                captured: (@Sendable (String) -> Void)?) throws -> Int32 {
        let remoteProject = commands.path(Remote.remoteDir, staged.jobName)
        let prep = try exec(commands.prep(jobDir: remoteProject))
        guard prep.succeeded else { throw RemoteError.ssh(prep.stderr) }

        let count = staged.sources.count + staged.constraints.count + staged.includes.count
        log("Copying \(count) files to \(config.host)...\n")
        let up = try Shell.run(
            "scp", ["-r", "-o", "BatchMode=yes"] + sshOptions + [staged.dir.path, "\(target):\(Remote.remoteDir)/"],
            timeout: 120)
        guard up.succeeded else { throw RemoteError.ssh(up.stderr) }
        if job?.isCancelled == true { return Shell.interruptedStatus }

        let token = Remote.makeJobToken()
        let run = commands.build(vivadoPath: config.vivadoPath, jobDir: remoteProject, token: token)
        let status: Int32
        if let job {
            log("Running Vivado...\n")
            status = try Shell.stream("ssh", sshOptions + [target, run], stop: job.stop, output: captured ?? log)
            if status == Shell.interruptedStatus {
                log("\nStopping Vivado on \(config.host)...\n")
                cancelRemoteJob(token: token)
            }
        } else {
            log("Running Vivado... (Ctrl-C cancels)\n")
            status = try Shell.stream("ssh", sshOptions + [target, run], onInterrupt: {
                log("\nCancelling: stopping Vivado on \(config.host)...\n")
                cancelRemoteJob(token: token)
            }, output: captured)
        }
        // ssh itself exits 255 when the connection fails; Vivado's own failures use other statuses.
        if status == 255 { throw RemoteError.connectionLost(jobDir: remoteProject) }
        return status
    }

    // MARK: Checkpoints

    /// Where a run's manifest is kept on the build machine, next to its checkpoint.
    func checkpointManifestPath(_ run: RunKind, project: Project) -> String {
        commands.path(Remote.remoteDir, "\(project.name).runs", run.runName, "manifest.json")
    }

    /// The manifest of the run's checkpoint on the build machine, or nil when there is none (never run there, failed
    /// or stopped since, or cleaned away). Throws only when SSH itself fails.
    func checkpointManifest(_ run: RunKind, project: Project) throws -> BuildManifest? {
        let result = try exec(commands.readFile(checkpointManifestPath(run, project: project)))
        if result.status == 255 { throw RemoteError.ssh(result.stderr) }
        return result.succeeded ? BuildManifest.parse(result.stdout) : nil
    }

    /// Why the run's checkpoint on the build machine can't be used for the files being sent now, or nil if it can.
    func checkpointProblem(_ run: RunKind, project: Project, keys: RunKeys, staged: Staged) throws -> CheckpointProblem? {
        guard let built = try checkpointManifest(run, project: project) else {
            return CheckpointProblem(run: run, reason: "there is no \(run.runName) checkpoint on \(config.host)")
        }
        if built.runs?[run.stepName] == keys.key(run) { return nil }
        // The files the run depends on, then and now: synthesis doesn't depend on the constraints.
        func input(_ path: String) -> Bool { path != Project.fileName && (run != .synthesis || !path.lowercased().hasSuffix(".xdc")) }
        let changed = Set(built.files.keys).union(staged.sent.keys).filter { input($0) && built.files[$0] != staged.sent[$0] }.sorted()
        let what = changed.isEmpty ? "the settings changed"
            : (changed.prefix(3).joined(separator: ", ") + (changed.count > 3 ? " and \(changed.count - 3) more" : "")) + " changed"
        return CheckpointProblem(run: run, reason: "\(what) since the \(run.runName) checkpoint on \(config.host) was made")
    }

    /// Which of several steps run in one session stopped with an error: the first whose checkpoint isn't there.
    func failedStep(_ steps: [RunKind], project: Project, keys: RunKeys, staged: Staged) -> RunKind? {
        guard steps.count > 1 else { return steps.first }
        for step in steps where step.checkpoint != nil {
            let built = (try? checkpointManifest(step, project: project)) ?? nil
            if built?.runs?[step.stepName] != keys.key(step) { return step }
        }
        return steps.last
    }

    // MARK: cmd.exe command lines (Windows)
    //
    // These run on Windows through cmd.exe. The Linux equivalents are in `RemoteCommands`. CI runs them through a real cmd.exe (see .github/workflows/ci.yml), and a
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
    /// Prints a file, failing if it doesn't exist.
    static func readFileCommand(_ file: String) -> String { "type \(file)" }
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
        _ = try? exec(commands.cancel(token: token), timeout: 30)
    }

    // MARK: Lock

    /// Who holds the lock, for the "machine is busy" message. Only plain characters, because it is echoed through
    /// cmd.exe or sh, and always ends in a letter (a digit before `>` would be read as a file handle in cmd.exe).
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
        let result = try exec(commands.acquireLock(owner: owner))
        if result.succeeded { return }
        // 255 means SSH itself failed (bad key, host down), not that the lock exists.
        if result.status == 255 { throw RemoteError.ssh(result.stderr) }
        guard let holder = try? exec(commands.readOwner), holder.succeeded else {
            // The lock directory exists but has no owner file (just created, or left by hand).
            throw RemoteError.busy(owner: nil)
        }
        throw RemoteError.busy(owner: holder.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func releaseLock() {
        _ = try? exec(commands.releaseLock)
    }

    /// Removes the lock regardless of who holds it. For a lock left behind by a crashed build or lost connection.
    public func unlock() throws {
        let result = try exec(commands.unlock)
        guard result.succeeded else { throw RemoteError.ssh(result.stderr) }
    }
}

/// A handle on steps running on the build machine, so another thread can stop them (the app's Stop button). Stopping
/// ends the local SSH session and kills the remote Vivado by its job marker, as Ctrl-C does on the command line.
public final class RemoteJob: Sendable {
    let stop = Shell.StopFlag()
    public init() {}
    public func cancel() { stop.set() }
    public var isCancelled: Bool { stop.isSet }
}

public enum RemoteError: DescribedError, Equatable {
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
