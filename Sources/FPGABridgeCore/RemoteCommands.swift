import Foundation

/// The operating system of the machine that runs Vivado.
public enum BuildOS: String, Codable, CaseIterable, Sendable {
    case windows
    case linux

    /// Guesses from a Vivado path: a drive letter or backslashes mean Windows, a leading slash means Linux. Anything
    /// else is taken to be Windows, which is what configs written before Linux support mean.
    public static func guess(fromVivadoPath path: String) -> BuildOS {
        if path.contains("\\") || path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil { return .windows }
        return path.hasPrefix("/") ? .linux : .windows
    }

    public var displayName: String { self == .windows ? "Windows" : "Linux" }
}

/// The command lines fpga-bridge sends to the build machine over SSH. Windows lines run through `cmd.exe`; Linux
/// lines are POSIX `sh`, handed to `bash -lc` so Vivado's environment (license server, settings) loads the way it does
/// when you log in by hand. Each OS is written out in full rather than built from shared pieces: the quoting rules
/// differ too much for that to stay readable.
struct RemoteCommands: Sendable {
    let os: BuildOS

    init(_ os: BuildOS) { self.os = os }

    /// Scratch directory on the build machine, relative to the SSH session's starting directory (the user's home).
    var scratch: String { Remote.remoteDir }

    var separator: String { os == .windows ? "\\" : "/" }

    /// Joins path parts the way the build machine writes them: `.fpga-bridge\demo` or `.fpga-bridge/demo`.
    func path(_ parts: String...) -> String { parts.joined(separator: separator) }

    var lockDir: String { path(scratch, "lock") }
    var lockOwnerFile: String { path(lockDir, "owner.txt") }

    // MARK: Files and directories

    func ensureScratch() -> String {
        switch os {
        case .windows: return "if not exist \(scratch) mkdir \(scratch)"
        case .linux: return wrap("mkdir -p \(scratch)")
        }
    }

    /// Creates the scratch directory if needed, then clears a previous copy of the job directory.
    func prep(jobDir: String) -> String {
        switch os {
        case .windows: return Remote.prepCommand(jobDir: jobDir)
        case .linux: return wrap("mkdir -p \(scratch) && rm -rf \(jobDir)")
        }
    }

    /// Deletes one file, quietly if it is already gone.
    func deleteFile(_ file: String) -> String {
        switch os {
        case .windows: return "del \(file)"
        case .linux: return wrap("rm -f \(file)")
        }
    }

    /// Prints a file, failing if it doesn't exist. Used for a checkpoint's manifest.
    func readFile(_ file: String) -> String {
        switch os {
        case .windows: return Remote.readFileCommand(file)
        case .linux: return wrap("cat \(file)")
        }
    }

    /// The text of a command that removes a directory tree. For tests that look for it in the SSH calls.
    func removeDirectory(_ dir: String) -> String {
        os == .windows ? "rmdir /s /q \(dir)" : "rm -rf \(dir)"
    }

    // MARK: Lock

    /// `mkdir` fails if the lock exists (and is atomic), so the owner file is only written by whoever took it.
    func acquireLock(owner: String) -> String {
        switch os {
        case .windows: return Remote.acquireLockCommand(owner: owner)
        case .linux: return wrap("mkdir -p \(scratch) && mkdir \(lockDir) && echo '\(owner)' > \(lockOwnerFile)")
        }
    }

    /// Writes the owner file again, which marks the lock as in use: done when Vivado finishes, so a lock that
    /// nobody has touched for a while (and that no Vivado is running under) can be told apart from one in use.
    func refreshLock(owner: String) -> String {
        switch os {
        case .windows: return Remote.refreshLockCommand(owner: owner)
        case .linux: return wrap("echo '\(owner)' > \(lockOwnerFile)")
        }
    }

    /// Prints `free` when there is no lock, `stale` when one is there but no fpga-bridge Vivado is running and the
    /// lock hasn't been touched for `Remote.staleLockMinutes` (left by a build that crashed or lost its
    /// connection), otherwise `held`. Any job marker counts, written as a pattern that doesn't match its own text.
    var lockState: String {
        switch os {
        case .windows: return Remote.lockStateCommand
        case .linux:
            return wrap("if [ ! -d \(lockDir) ]; then echo free; elif pgrep -f \"fpgabridge-[0-9a-f]{8}\" >/dev/null; then echo held; "
                        + "elif [ -n \"$(find \(lockDir) -maxdepth 1 -mmin -\(Remote.staleLockMinutes))\" ]; then echo held; else echo stale; fi")
        }
    }

    var readOwner: String { os == .windows ? Remote.readOwnerCommand : wrap("cat \(lockOwnerFile)") }
    var releaseLock: String { os == .windows ? Remote.releaseLockCommand : wrap("rm -rf \(lockDir)") }
    var unlock: String { os == .windows ? Remote.unlockCommand : wrap("rm -rf \(lockDir)") }

    // MARK: Vivado

    /// Does the Vivado launcher exist at this path? Prints `found` or `missing`.
    func vivadoExists(_ vivadoPath: String) -> String {
        switch os {
        case .windows: return "if exist \"\(vivadoPath)\" (echo found) else (echo missing)"
        case .linux: return wrap("[ -x \(quote(vivadoPath)) ] && echo found || echo missing")
        }
    }

    /// Prints what `vivado -version` says ("vivado v2025.2 (64-bit)" first).
    func vivadoVersion(_ vivadoPath: String) -> String {
        switch os {
        case .windows: return "call \"\(vivadoPath)\" -version"
        case .linux: return wrap("\(quote(vivadoPath)) -version")
        }
    }

    /// Runs one Tcl script in Vivado batch mode.
    func vivado(vivadoPath: String, tclFile: String) -> String {
        switch os {
        case .windows: return Remote.vivadoCommand(vivadoPath: vivadoPath, tclFile: tclFile)
        case .linux: return wrap("\(quote(vivadoPath)) -mode batch -nojournal -nolog -source \(tclFile)")
        }
    }

    /// Runs the project's `build.tcl` inside its job directory, with the job's marker on Vivado's command line.
    func build(vivadoPath: String, jobDir: String, token: String) -> String {
        switch os {
        case .windows: return Remote.buildCommand(vivadoPath: vivadoPath, jobDir: jobDir, token: token)
        case .linux:
            return wrap("cd \(jobDir) && \(quote(vivadoPath)) -mode batch -nojournal -log vivado.log -source build.tcl"
                        + " -tclargs \(Remote.jobMarker(token))")
        }
    }

    /// Stops the job whose marker is `token`, with everything it started. On Linux the marker is written as a
    /// character class (`[f]pgabridge-…`), which matches the real text but not this command's own text, so `pkill -f`
    /// can't kill the shell that is running it.
    func cancel(token: String) -> String {
        switch os {
        case .windows: return Remote.cancelCommand(token: token)
        case .linux:
            let marker = Remote.jobMarker(token)
            return wrap("pkill -9 -f '[\(marker.prefix(1))]\(marker.dropFirst())'")
        }
    }

    // MARK: Shell

    /// Single-quotes a string for POSIX sh.
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Hands a Linux script to `bash -lc`, whatever the login shell is (fish and csh don't read sh syntax). Windows
    /// lines go to `cmd.exe` as they are.
    func wrap(_ script: String) -> String {
        os == .windows ? script : "bash -lc " + quote(script)
    }
}
