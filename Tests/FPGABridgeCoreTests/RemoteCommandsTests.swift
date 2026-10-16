import XCTest
@testable import FPGABridgeCore

/// The Linux command lines, run for real in a POSIX shell in a temp directory that stands in for the build machine's
/// home. (`bash -lc` is bypassed here with `sh -c` so a developer's own login files can't change the result; the
/// wrapper itself is checked separately.)
final class RemoteCommandsTests: XCTestCase {
    let linux = RemoteCommands(.linux)
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    /// Runs the script inside a Linux line (`bash -lc '<script>'`) with `sh`, in the fake home.
    @discardableResult
    func run(_ line: String, file: StaticString = #filePath, lineNumber: UInt = #line) throws -> CommandResult {
        let prefix = "bash -lc "
        XCTAssertTrue(line.hasPrefix(prefix), "Linux lines are wrapped for bash -lc: \(line)", file: file, line: lineNumber)
        let script = unquote(String(line.dropFirst(prefix.count)))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = home
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                             stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// Undoes `quote`: reads one sh single-quoted word using sh itself.
    func unquote(_ word: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(word)"]
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }

    // MARK: Shape

    func testPathsUseTheMachinesSeparator() {
        XCTAssertEqual(linux.path(".fpga-bridge", "demo"), ".fpga-bridge/demo")
        XCTAssertEqual(RemoteCommands(.windows).path(".fpga-bridge", "demo"), #".fpga-bridge\demo"#)
        XCTAssertEqual(linux.lockOwnerFile, ".fpga-bridge/lock/owner.txt")
    }

    func testWindowsLinesAreUnchanged() {
        let windows = RemoteCommands(.windows)
        XCTAssertEqual(windows.prep(jobDir: #".fpga-bridge\demo"#), Remote.prepCommand(jobDir: #".fpga-bridge\demo"#))
        XCTAssertEqual(windows.acquireLock(owner: "a b"), Remote.acquireLockCommand(owner: "a b"))
        XCTAssertEqual(windows.cancel(token: "a1b2c3d4"), Remote.cancelCommand(token: "a1b2c3d4"))
        XCTAssertEqual(windows.build(vivadoPath: #"C:\v\vivado.bat"#, jobDir: "j", token: "a1b2c3d4"),
                       Remote.buildCommand(vivadoPath: #"C:\v\vivado.bat"#, jobDir: "j", token: "a1b2c3d4"))
        XCTAssertEqual(windows.wrap("dir"), "dir", "cmd.exe lines aren't wrapped")
    }

    func testQuotingSurvivesSpacesAndSingleQuotes() throws {
        XCTAssertEqual(linux.quote("a b"), "'a b'")
        XCTAssertEqual(linux.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(unquote(linux.quote("it's a $HOME `x` \"y\"")), "it's a $HOME `x` \"y\"", "nothing inside is interpreted")
    }

    func testEveryLinuxLineGoesThroughBashLoginShell() {
        let lines = [linux.ensureScratch(), linux.prep(jobDir: "j"), linux.deleteFile("f"), linux.acquireLock(owner: "o"),
                     linux.readOwner, linux.releaseLock, linux.unlock, linux.vivadoExists("/v"),
                     linux.vivado(vivadoPath: "/v", tclFile: "t.tcl"), linux.build(vivadoPath: "/v", jobDir: "j", token: "a1b2c3d4"),
                     linux.cancel(token: "a1b2c3d4")]
        for line in lines { XCTAssertTrue(line.hasPrefix("bash -lc '"), line) }
    }

    // MARK: Running them

    func testTheLockIsTakenOnceAndReadable() throws {
        XCTAssertEqual(try run(linux.acquireLock(owner: "me@mac building demo since now")).status, 0)
        XCTAssertTrue(exists(".fpga-bridge/lock/owner.txt"))
        let second = try run(linux.acquireLock(owner: "someone@else building other since later"))
        XCTAssertNotEqual(second.status, 0, "a second build can't take it")
        XCTAssertNotEqual(second.status, 255, "and the failure isn't mistaken for an ssh failure")
        let owner = try run(linux.readOwner)
        XCTAssertEqual(owner.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "me@mac building demo since now",
                       "the loser didn't overwrite the owner")
        XCTAssertEqual(try run(linux.releaseLock).status, 0)
        XCTAssertFalse(exists(".fpga-bridge/lock"))
        XCTAssertEqual(try run(linux.acquireLock(owner: "again")).status, 0, "free again after release")
    }

    func testUnlockIsHarmlessWhenThereIsNoLock() throws {
        XCTAssertEqual(try run(linux.unlock).status, 0)
        try run(linux.acquireLock(owner: "x"))
        XCTAssertEqual(try run(linux.unlock).status, 0)
        XCTAssertFalse(exists(".fpga-bridge/lock"))
    }

    func testPrepClearsAStaleJobDirectoryAndKeepsTheLock() throws {
        try run(linux.acquireLock(owner: "x"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".fpga-bridge/demo/out"), withIntermediateDirectories: true)
        try "old".write(to: home.appendingPathComponent(".fpga-bridge/demo/out/old.bit"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(linux.prep(jobDir: linux.path(".fpga-bridge", "demo"))).status, 0)
        XCTAssertFalse(exists(".fpga-bridge/demo"))
        XCTAssertTrue(exists(".fpga-bridge/lock"), "clearing the job doesn't touch the lock")
    }

    func testVivadoExistsFindsAnExecutableAndRefusesOtherThings() throws {
        let launcher = home.appendingPathComponent("my tools/vivado")           // a path with a space
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: launcher, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(linux.vivadoExists(launcher.path)).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "missing",
                       "present but not executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        XCTAssertEqual(try run(linux.vivadoExists(launcher.path)).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "found")
        XCTAssertEqual(try run(linux.vivadoExists("/no/such/vivado")).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "missing")
    }

    func testTheBuildCommandRunsTheLauncherInTheJobDirectoryWithTheMarker() throws {
        let launcher = home.appendingPathComponent("it's here/vivado")           // space AND a single quote
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\npwd > args.txt\necho \"$@\" >> args.txt\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".fpga-bridge/demo"), withIntermediateDirectories: true)

        let result = try run(linux.build(vivadoPath: launcher.path, jobDir: ".fpga-bridge/demo", token: "a1b2c3d4"))
        XCTAssertEqual(result.status, 0, result.stderr)
        let recorded = try String(contentsOf: home.appendingPathComponent(".fpga-bridge/demo/args.txt"), encoding: .utf8)
        XCTAssertTrue(recorded.contains(".fpga-bridge/demo"), "ran inside the job directory: \(recorded)")
        XCTAssertTrue(recorded.contains("-mode batch -nojournal -nolog -source build.tcl -tclargs fpgabridge-a1b2c3d4"), recorded)
    }

    func testCancelKillsTheMarkedProcessAndNothingElse() throws {
        func spawn(_ extra: String) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "exec -a '\(extra)' sleep 60"]
            try p.run()
            return p
        }
        let marked = try spawn("fake-vivado -tclargs fpgabridge-c0ffee11")
        let other = try spawn("fake-vivado -tclargs fpgabridge-deadbeef")
        let unrelated = try spawn("something else entirely")
        defer { [marked, other, unrelated].forEach { $0.terminate() } }
        Thread.sleep(forTimeInterval: 0.3)

        let cancel = linux.cancel(token: "c0ffee11")
        XCTAssertFalse(cancel.contains("fpgabridge-c0ffee11"), "the command's own text must not match itself")
        let result = try run(cancel)
        XCTAssertEqual(result.status, 0, result.stderr)
        marked.waitUntilExit()
        XCTAssertFalse(marked.isRunning, "the job with the marker was killed")
        XCTAssertTrue(other.isRunning, "another job on the machine was left alone")
        XCTAssertTrue(unrelated.isRunning)
    }

    func testDeleteFileIsQuietWhenTheFileIsAlreadyGone() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".fpga-bridge"), withIntermediateDirectories: true)
        try "x".write(to: home.appendingPathComponent(".fpga-bridge/job.tcl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(linux.deleteFile(".fpga-bridge/job.tcl")).status, 0)
        XCTAssertFalse(exists(".fpga-bridge/job.tcl"))
        XCTAssertEqual(try run(linux.deleteFile(".fpga-bridge/job.tcl")).status, 0)
    }

    /// A path with shell syntax in it is quoted, not run. (`validate()` also refuses most of these characters; this
    /// checks that the quoting alone would hold.)
    func testShellSyntaxInAPathIsNeverExecuted() throws {
        let nasty = "/tools/x; touch pwned1; $(touch pwned2) `touch pwned3` | touch pwned4 > pwned5 #"
        for line in [linux.vivadoExists(nasty),
                     linux.build(vivadoPath: nasty, jobDir: ".fpga-bridge/demo", token: "a1b2c3d4"),
                     linux.vivado(vivadoPath: nasty, tclFile: "x.tcl")] {
            try run(line)
        }
        for name in ["pwned1", "pwned2", "pwned3", "pwned4", "pwned5"] { XCTAssertFalse(exists(name), name) }
    }

    // MARK: Config

    func testTheBuildOSIsWorkedOutFromTheVivadoPath() {
        XCTAssertEqual(BuildOS.guess(fromVivadoPath: #"C:\Xilinx\Vivado\2023.2\bin\vivado.bat"#), .windows)
        XCTAssertEqual(BuildOS.guess(fromVivadoPath: "D:/Xilinx/vivado.bat"), .windows)
        XCTAssertEqual(BuildOS.guess(fromVivadoPath: "/tools/Xilinx/2025.2/Vivado/bin/vivado"), .linux)
        XCTAssertEqual(BuildOS.guess(fromVivadoPath: "vivado"), .windows, "unknown means the old default")
    }

    func testConfigsWithoutAnOSKeepWorkingAndAnExplicitOSWins() throws {
        let old = #"{"host":"h","user":"u","vivadoPath":"C:\\v\\vivado.bat"}"#
        let decoded = try JSONDecoder().decode(BridgeConfig.self, from: Data(old.utf8))
        XCTAssertNil(decoded.os)
        XCTAssertEqual(decoded.buildOS, .windows)

        let explicit = BridgeConfig(host: "h", user: "u", vivadoPath: "/opt/vivado", os: .linux)
        XCTAssertEqual(explicit.buildOS, .linux)
        let roundTrip = try JSONDecoder().decode(BridgeConfig.self, from: JSONEncoder().encode(explicit))
        XCTAssertEqual(roundTrip, explicit)
        XCTAssertEqual(BridgeConfig(host: "h", user: "u", vivadoPath: "/opt/vivado", os: .windows).buildOS, .windows)
    }

    func testALinuxVivadoPathMustBeAbsoluteAndStillPlain() {
        XCTAssertNoThrow(try BridgeConfig(host: "h", user: "u", vivadoPath: "/tools/Xilinx/2025.2/Vivado/bin/vivado").validate())
        XCTAssertNoThrow(try BridgeConfig(host: "h", user: "u", vivadoPath: "/home/me/my tools/vivado").validate(), "spaces are fine")
        XCTAssertThrowsError(try BridgeConfig(host: "h", user: "u", vivadoPath: "~/Xilinx/bin/vivado", os: .linux).validate())
        XCTAssertThrowsError(try BridgeConfig(host: "h", user: "u", vivadoPath: "bin/vivado", os: .linux).validate())
        XCTAssertThrowsError(try BridgeConfig(host: "h", user: "u", vivadoPath: "/tools/$(x)/vivado&", os: .linux).validate())
    }

    func testVersionsAreReadFromLinuxPathsToo() {
        XCTAssertEqual(Project.version(in: "/tools/Xilinx/Vivado/2023.2/bin/vivado"), "2023.2")
        XCTAssertEqual(Project.version(in: "/tools/Xilinx/2025.2/Vivado/bin/vivado"), "2025.2")
        XCTAssertEqual(Project.version(in: "/opt/Xilinx/Vivado/2019.1/bin/vivado"), "2019.1")
        XCTAssertNil(Project.version(in: "/usr/local/bin/vivado"))
    }
}
