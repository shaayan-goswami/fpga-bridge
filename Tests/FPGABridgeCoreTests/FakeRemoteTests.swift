import XCTest
@testable import FPGABridgeCore

/// Runs the real `Remote` and `Doctor` code against stub `ssh`/`scp` scripts (see FakeRemote/) that act as a Windows
/// build machine. The stubs only accept the exact command lines fpga-bridge should send.
/// `LinuxFakeRemoteTests` below runs every one of these tests again against a Linux build machine, whose stub runs the
/// commands in a real shell.
/// Collects text from a callback that runs on another thread.
final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

class FakeRemoteTests: XCTestCase {
    class var vivadoPath: String { #"C:\Program Files\Xilinx\Vivado\2023.2\bin\vivado.bat"# }
    /// A Vivado path that doesn't exist on the fake machine.
    class var otherVivadoPath: String { #"C:\somewhere\else\vivado.bat"# }
    class var os: BuildOS { .windows }
    var commands: RemoteCommands { RemoteCommands(Self.os) }

    var tmp: URL!
    var remoteHome: URL!
    var log: URL!
    var originalPath: String!
    let envKeys = ["FAKE_HOME", "FAKE_LOG", "FAKE_REPORT_DIR", "FAKE_VIVADO_PATH", "FAKE_VIVADO_BIN",
                   "FAKE_SSH_FAIL", "FAKE_VIVADO_MODE", "FAKE_SCP_FAIL", "FAKE_FLOW"]

    override func setUpWithError() throws {
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.appendingPathComponent("fpga-bridge-test-\(UUID().uuidString)")
        let bin = tmp.appendingPathComponent("bin")
        remoteHome = tmp.appendingPathComponent("remote")
        log = tmp.appendingPathComponent("calls.log")
        let reports = tmp.appendingPathComponent("reports")
        for dir in [bin, remoteHome!, reports] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        // The Linux stub for `ssh` is installed under the name `ssh`; Fpga-bridge never knows the difference.
        for (tool, installedAs) in [(Self.os == .linux ? "ssh-linux" : "ssh", "ssh"), ("scp", "scp")] {
            let source = try XCTUnwrap(Bundle.module.url(forResource: tool, withExtension: nil, subdirectory: "FakeRemote"))
            let dest = bin.appendingPathComponent(installedAs)
            try fm.copyItem(at: source, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        if Self.os == .linux {
            let launcher = tmp.appendingPathComponent("tools/Xilinx/Vivado/2023.2/bin/vivado")
            try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: try XCTUnwrap(Bundle.module.url(forResource: "vivado-linux", withExtension: nil, subdirectory: "FakeRemote")),
                            to: launcher)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            setenv("FAKE_VIVADO_BIN", launcher.path, 1)
        }
        // The fake Vivado both stubs run for a build.tcl.
        let flow = tmp.appendingPathComponent("fake-flow")
        try fm.copyItem(at: try XCTUnwrap(Bundle.module.url(forResource: "fake-flow", withExtension: nil, subdirectory: "FakeRemote")), to: flow)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flow.path)
        setenv("FAKE_FLOW", flow.path, 1)
        for (fixture, name) in [("timing_pass", "timing_summary.rpt"), ("utilization_7series", "utilization.rpt")] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "rpt", subdirectory: "Fixtures"))
            try fm.copyItem(at: url, to: reports.appendingPathComponent(name))
        }

        originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(bin.path):\(originalPath!)", 1)
        setenv("FAKE_HOME", remoteHome.path, 1)
        setenv("FAKE_LOG", log.path, 1)
        setenv("FAKE_REPORT_DIR", reports.path, 1)
        setenv("FAKE_VIVADO_PATH", Self.vivadoPath, 1)
    }

    override func tearDownWithError() throws {
        setenv("PATH", originalPath, 1)
        for key in envKeys { unsetenv(key) }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Helpers

    var config: BridgeConfig { BridgeConfig(host: "buildbox", user: "me", vivadoPath: Self.vivadoPath) }

    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func makeProject() throws -> (Project, URL) {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("project")
        for dir in ["src/sub", "constraints"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "module top(); endmodule".write(to: root.appendingPathComponent("src/top.v"), atomically: true, encoding: .utf8)
        try "module alu(); endmodule".write(to: root.appendingPathComponent("src/sub/alu.sv"), atomically: true, encoding: .utf8)
        try "# pins".write(to: root.appendingPathComponent("constraints/pins.xdc"), atomically: true, encoding: .utf8)
        let project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1",
                              sources: ["src"], constraints: ["constraints"])
        return (project, root)
    }

    func tailscale(online: Bool = true, state: String = "Running") -> () throws -> TailscaleStatus {
        {
            TailscaleStatus(backendState: state, peers: [
                .init(hostName: "buildbox", dnsName: "buildbox.tail1234.ts.net", ips: ["100.64.0.7"], online: online),
            ])
        }
    }

    func remoteFile(_ path: String) -> URL { remoteHome.appendingPathComponent(path) }

    // MARK: Doctor

    func testDoctorAllChecksPass() {
        let checks = Doctor.run(config: config, tailscale: tailscale())
        XCTAssertEqual(checks.map(\.name), ["Tailscale", "SSH", "Vivado"])
        XCTAssertEqual(checks.map(\.level), [.ok, .ok, .ok], "\(checks)")
    }

    func testDoctorReportsRejectedKey() {
        setenv("FAKE_SSH_FAIL", "permission", 1)
        let checks = Doctor.run(config: config, tailscale: tailscale())
        XCTAssertEqual(checks.map(\.name), ["Tailscale", "SSH"], "Vivado check must not run after SSH fails")
        XCTAssertEqual(checks.last?.level, .fail)
        XCTAssertTrue(checks.last?.detail.contains("Key rejected") == true, "\(checks)")
    }

    func testDoctorReportsUnreachableSSH() {
        setenv("FAKE_SSH_FAIL", "refused", 1)
        let checks = Doctor.run(config: config, tailscale: tailscale())
        XCTAssertEqual(checks.last?.level, .fail)
        XCTAssertTrue(checks.last?.detail.contains("Can't reach sshd") == true, "\(checks)")
    }

    func testDoctorReportsMissingVivado() {
        setenv("FAKE_VIVADO_PATH", Self.otherVivadoPath, 1)
        let checks = Doctor.run(config: config, tailscale: tailscale())
        XCTAssertEqual(checks.map(\.level), [.ok, .ok, .fail], "\(checks)")
        XCTAssertTrue(checks.last?.detail.contains("not found on \(Self.os.displayName)") == true, checks.last?.detail ?? "")
        XCTAssertTrue(checks.last?.detail.contains(Self.os == .windows ? "windows\\setup.ps1" : "linux/setup.sh") == true,
                      "it names the setup script for this OS")
    }

    func testDoctorStopsBeforeSSHWhenTailscaleIsStopped() {
        let checks = Doctor.run(config: config, tailscale: tailscale(state: "Stopped"))
        XCTAssertEqual(checks.map(\.name), ["Tailscale"])
        XCTAssertEqual(checks.first?.level, .fail)
        XCTAssertTrue(calls.isEmpty, "SSH must not be attempted: \(calls)")
    }

    func testDoctorStopsBeforeSSHWhenPeerIsOffline() {
        let checks = Doctor.run(config: config, tailscale: tailscale(online: false))
        XCTAssertEqual(checks.map(\.name), ["Tailscale"])
        XCTAssertTrue(checks.first?.detail.contains("offline") == true)
        XCTAssertTrue(calls.isEmpty)
    }

    func testDoctorWarnsButContinuesForNonTailnetHost() {
        let lan = BridgeConfig(host: "192.168.1.20", user: "me", vivadoPath: Self.vivadoPath)
        let checks = Doctor.run(config: lan, tailscale: tailscale())
        XCTAssertEqual(checks.map(\.level), [.warn, .ok, .ok], "\(checks)")
    }

    func testDoctorFailsForATailnetNameWhenTheTailscaleCLIIsMissing() {
        let tailnet = BridgeConfig(host: "pc.example.ts.net", user: "me", vivadoPath: Self.vivadoPath)
        let checks = Doctor.run(config: tailnet, tailscale: { throw TailscaleError.notInstalled })
        XCTAssertEqual(checks.map(\.name), ["Tailscale"])
        XCTAssertEqual(checks.first?.level, .fail)
        XCTAssertTrue(calls.isEmpty)
    }

    func testDoctorOnlyWarnsAboutMissingTailscaleForALocalAddress() {
        let lan = BridgeConfig(host: "100.100.51.9", user: "me", vivadoPath: Self.vivadoPath)
        let checks = Doctor.run(config: lan, tailscale: { throw TailscaleError.notInstalled })
        XCTAssertEqual(checks.map(\.level), [.warn, .ok, .ok], "\(checks)")
    }

    // MARK: Build

    func testBuildStagesRunsAndFetches() throws {
        let (project, root) = try makeProject()
        let status = try Remote(config: config).build(project: project, root: root)
        XCTAssertEqual(status, 0)

        // Staged on the "Windows" side with relative layout preserved, plus the generated script.
        for file in ["src/top.v", "src/sub/alu.sv", "constraints/pins.xdc", "build.tcl"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: remoteFile(".fpga-bridge/demo/\(file)").path), file)
        }
        let tcl = try String(contentsOf: remoteFile(".fpga-bridge/demo/build.tcl"), encoding: .utf8)
        XCTAssertTrue(tcl.contains("read_verilog {src/top.v}"))
        XCTAssertTrue(tcl.contains("read_verilog -sv {src/sub/alu.sv}"))
        XCTAssertTrue(tcl.contains("read_xdc {constraints/pins.xdc}"))

        // Results came back, and the summary can be read from them.
        let build = root.appendingPathComponent(Remote.localOutputDir)
        for file in ["top.bit", "timing_summary.rpt", "utilization.rpt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: build.appendingPathComponent(file).path), file)
        }
        let summary = BuildSummary.load(from: build)
        XCTAssertTrue(summary.notes.isEmpty, "\(summary.notes)")
        XCTAssertEqual(summary.timing?.constraintsMet, true)
        XCTAssertEqual(summary.utilization?.usage(.lut)?.used, 12)

        // And a record of what it was built from, next to the bitstream.
        let manifest = try XCTUnwrap(BuildManifest.load(from: build))
        XCTAssertEqual(Set(manifest.files.keys), ["src/top.v", "src/sub/alu.sv", "constraints/pins.xdc"])
        XCTAssertEqual(manifest.vivadoVersion, "2023.2", "from the install path when the build wrote no design data")
        XCTAssertEqual(manifest.buildMachine, "buildbox")
        XCTAssertEqual(manifest.top, "top")
        XCTAssertEqual(manifest.changes(project: project, root: root), [])
    }

    func testBuildCallOrderAndCommands() throws {
        let (project, root) = try makeProject()
        _ = try Remote(config: config).build(project: project, root: root)

        XCTAssertEqual(calls.map { String($0.prefix(3)) }, ["ssh", "ssh", "scp", "ssh", "scp", "ssh"], "\(calls)")
        // Indexing below would crash the whole test run if the sequence is wrong, hiding every other failure.
        guard calls.count == 6 else { return }
        XCTAssertTrue(calls[0].contains("mkdir \(commands.lockDir)"), "lock is taken first")
        XCTAssertTrue(calls[1].contains(commands.removeDirectory(commands.path(".fpga-bridge", "demo"))), "stale remote job dir must be cleared")
        XCTAssertTrue(calls[2].contains("-r") && calls[2].contains("me@buildbox:.fpga-bridge/"), "directory upload needs -r")
        XCTAssertTrue(calls[3].contains(" -mode batch -nojournal -nolog -source build.tcl -tclargs fpgabridge-"))
        XCTAssertTrue(calls[3].contains(Self.vivadoPath), "the configured Vivado path is used")
        if Self.os == .windows {
            XCTAssertTrue(calls[3].contains(#"call "\#(Self.vivadoPath)" -mode batch"#), "the Vivado path has spaces and must stay quoted")
        } else {
            XCTAssertTrue(calls[3].hasPrefix("ssh") && calls[3].contains("bash -lc"), "Linux lines go through bash -lc")
        }
        XCTAssertTrue(calls[4].contains("-r") && calls[4].contains("me@buildbox:.fpga-bridge/demo/out"))
        XCTAssertTrue(calls[5].contains(commands.removeDirectory(commands.lockDir)), "lock is released last")
    }

    func testBuildFailureReturnsExitStatusAndFetchesNothing() throws {
        setenv("FAKE_VIVADO_MODE", "fail", 1)
        let (project, root) = try makeProject()
        let status = try Remote(config: config).build(project: project, root: root)

        XCTAssertEqual(status, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(Remote.localOutputDir).path))
        XCTAssertEqual(calls.filter { $0.hasPrefix("scp") }.count, 1, "only the upload, no fetch: \(calls)")
    }

    func testBuildReplacesStaleRemoteAndLocalOutput() throws {
        let (project, root) = try makeProject()
        let fm = FileManager.default

        try fm.createDirectory(at: remoteFile(".fpga-bridge/demo"), withIntermediateDirectories: true)
        try "old".write(to: remoteFile(".fpga-bridge/demo/old.v"), atomically: true, encoding: .utf8)
        let staleBuild = root.appendingPathComponent(Remote.localOutputDir)
        try fm.createDirectory(at: staleBuild, withIntermediateDirectories: true)
        try "old".write(to: staleBuild.appendingPathComponent("stale.rpt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try Remote(config: config).build(project: project, root: root), 0)

        XCTAssertFalse(fm.fileExists(atPath: remoteFile(".fpga-bridge/demo/old.v").path), "old remote file survived")
        XCTAssertFalse(fm.fileExists(atPath: staleBuild.appendingPathComponent("stale.rpt").path), "old local file survived")
        XCTAssertTrue(fm.fileExists(atPath: staleBuild.appendingPathComponent("timing_summary.rpt").path))
        XCTAssertFalse(fm.fileExists(atPath: staleBuild.appendingPathComponent("out").path),
                       "results must land in build/, not build/out/")
    }

    func testBuildThrowsWhenCopyFails() throws {
        setenv("FAKE_SCP_FAIL", "1", 1)
        let (project, root) = try makeProject()
        XCTAssertThrowsError(try Remote(config: config).build(project: project, root: root)) { error in
            XCTAssertTrue("\(error)".contains("SSH failed"), "\(error)")
        }
        XCTAssertFalse(calls.contains { $0.contains("-source build.tcl") }, "Vivado must not run after a failed copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteFile(".fpga-bridge/lock").path), "lock must be released")
    }

    func testBuildThrowsWhenSSHIsRejected() throws {
        setenv("FAKE_SSH_FAIL", "permission", 1)
        let (project, root) = try makeProject()
        XCTAssertThrowsError(try Remote(config: config).build(project: project, root: root))
        XCTAssertTrue(calls.allSatisfy { $0.hasPrefix("ssh") }, "nothing should be copied: \(calls)")
    }

    func testSSHKeyOptionIsPassedToSSHAndSCP() throws {
        let keyed = BridgeConfig(host: "buildbox", user: "me", vivadoPath: Self.vivadoPath, sshKeyPath: "/keys/id_test")
        let (project, root) = try makeProject()
        _ = try Remote(config: keyed).build(project: project, root: root)
        XCTAssertEqual(calls.count, 6)
        XCTAssertTrue(calls.allSatisfy { $0.contains("-i /keys/id_test") }, "\(calls)")
    }

    // MARK: Separate runs

    func buildFile(_ name: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("build/\(name)").path)
    }

    var runsFolder: String { ".fpga-bridge/demo.runs" }

    func checkpointManifest(_ run: String) -> BuildManifest? {
        (try? String(contentsOf: remoteFile("\(runsFolder)/\(run)/manifest.json"), encoding: .utf8)).flatMap(BuildManifest.parse)
    }

    func testEachStepRunsAloneFromTheCheckpointBeforeIt() throws {
        let (project, root) = try makeProject()
        let remote = Remote(config: config)

        let synth = try remote.run([.synthesis], project: project, root: root, log: { _ in })
        XCTAssertEqual(synth, Remote.StepResult(status: 0, completed: [.synthesis]))
        XCTAssertTrue(buildFile("synth_utilization.rpt", in: root))
        XCTAssertFalse(buildFile("timing_summary.rpt", in: root), "synthesis alone doesn't implement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteFile("\(runsFolder)/synth_1/post_synth.dcp").path))
        XCTAssertNotNil(checkpointManifest("synth_1")?.runs?["synth_1"], "the checkpoint's manifest is kept next to it")

        let impl = try remote.run([.implementation], project: project, root: root, log: { _ in })
        XCTAssertEqual(impl, Remote.StepResult(status: 0, completed: [.implementation]))
        let tcl = try String(contentsOf: remoteFile(".fpga-bridge/demo/build.tcl"), encoding: .utf8)
        XCTAssertTrue(tcl.contains("open_checkpoint ../demo.runs/synth_1/post_synth.dcp"))
        XCTAssertFalse(tcl.contains("synth_design -top"), "implementation doesn't synthesize again")
        XCTAssertTrue(buildFile("synth_utilization.rpt", in: root), "the synthesis results stay")
        XCTAssertTrue(buildFile("timing_summary.rpt", in: root))
        XCTAssertFalse(buildFile("top.bit", in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteFile("\(runsFolder)/impl_1/post_route.dcp").path))

        let bit = try remote.run([.bitstream], project: project, root: root, log: { _ in })
        XCTAssertEqual(bit, Remote.StepResult(status: 0, completed: [.bitstream]))
        for file in ["top.bit", "timing_summary.rpt", "synth_utilization.rpt"] { XCTAssertTrue(buildFile(file, in: root), file) }
        let manifest = try XCTUnwrap(BuildManifest.load(from: root.appendingPathComponent("build")))
        XCTAssertEqual(Set(manifest.runs?.keys ?? [:].keys), ["synth_1", "impl_1", "write_bitstream"])
        XCTAssertEqual(manifest.changes(project: project, root: root), [])
    }

    func testAConstraintChangeRerunsImplementationButNotSynthesis() throws {
        let (project, root) = try makeProject()
        let remote = Remote(config: config)
        XCTAssertEqual(try remote.build(project: project, root: root), 0)
        let synthesized = try XCTUnwrap(checkpointManifest("synth_1"))

        try "# pins, moved".write(to: root.appendingPathComponent("constraints/pins.xdc"), atomically: true, encoding: .utf8)
        let impl = try remote.run([.implementation], project: project, root: root, log: { _ in })
        XCTAssertTrue(impl.succeeded, "the synthesized netlist doesn't depend on the constraints: \(impl)")
        XCTAssertEqual(checkpointManifest("synth_1"), synthesized, "synthesis was not run again")
        let tcl = try String(contentsOf: remoteFile(".fpga-bridge/demo/build.tcl"), encoding: .utf8)
        XCTAssertTrue(tcl.contains("read_xdc {constraints/pins.xdc}"), "the new constraints are read on top of the checkpoint")
    }

    func testASourceChangeMeansSynthesisFirstAndSaysWhy() throws {
        let (project, root) = try makeProject()
        let remote = Remote(config: config)
        XCTAssertEqual(try remote.build(project: project, root: root), 0)
        try "module top(); wire x; endmodule".write(to: root.appendingPathComponent("src/top.v"), atomically: true, encoding: .utf8)
        let before = calls.count

        let impl = try remote.run([.implementation], project: project, root: root, log: { _ in })
        XCTAssertEqual(impl.needs?.run, .synthesis)
        XCTAssertTrue(impl.needs?.reason.contains("src/top.v changed since the synth_1 checkpoint on buildbox was made") == true,
                      impl.needs?.reason ?? "")
        XCTAssertTrue(impl.completed.isEmpty)
        XCTAssertFalse(calls.dropFirst(before).contains { $0.contains("-tclargs") }, "Vivado must not run on a stale checkpoint")
        XCTAssertFalse(lockExists)
    }

    func testAMissingCheckpointMeansTheEarlierRunFirst() throws {
        let (project, root) = try makeProject()
        let remote = Remote(config: config)
        let impl = try remote.run([.implementation], project: project, root: root, log: { _ in })
        XCTAssertEqual(impl.needs, Remote.CheckpointProblem(run: .synthesis, reason: "there is no synth_1 checkpoint on buildbox"))

        XCTAssertTrue(try remote.run([.synthesis], project: project, root: root, log: { _ in }).succeeded)
        let bit = try remote.run([.bitstream], project: project, root: root, log: { _ in })
        XCTAssertEqual(bit.needs?.run, .implementation, "write_bitstream starts from impl_1's checkpoint")
    }

    func testSynthesisClearsTheImplementationResultsItMakesStale() throws {
        let (project, root) = try makeProject()
        let remote = Remote(config: config)
        XCTAssertEqual(try remote.build(project: project, root: root), 0)
        XCTAssertTrue(buildFile("top.bit", in: root))

        XCTAssertTrue(try remote.run([.synthesis], project: project, root: root, log: { _ in }).succeeded)
        XCTAssertTrue(buildFile("synth_utilization.rpt", in: root))
        for file in ["top.bit", "timing_summary.rpt", "utilization.rpt"] { XCTAssertFalse(buildFile(file, in: root), "\(file) is from the old netlist") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteFile("\(runsFolder)/impl_1").path), "nor is its checkpoint kept")
        XCTAssertEqual(BuildManifest.load(from: root.appendingPathComponent("build"))?.runs?.keys.sorted(), ["synth_1"])
    }

    func testAFailedImplementationSaysSoAndKeepsTheSynthesisCheckpoint() throws {
        setenv("FAKE_VIVADO_MODE", "fail-impl", 1)
        let (project, root) = try makeProject()
        let result = try Remote(config: config).run(RunKind.flow, project: project, root: root, log: { _ in })
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.failed, .implementation)
        XCTAssertNotNil(checkpointManifest("synth_1"), "synthesis finished, so implementation can start from it next time")
        XCTAssertFalse(buildFile("synth_utilization.rpt", in: root), "nothing is fetched from a failed run")
        XCTAssertFalse(lockExists)
    }

    func testAFailedSynthesisIsTheStepThatFailed() throws {
        setenv("FAKE_VIVADO_MODE", "fail", 1)
        let (project, root) = try makeProject()
        XCTAssertEqual(try Remote(config: config).run(RunKind.flow, project: project, root: root, log: { _ in }).failed, .synthesis)
    }

    func testTheStagedManifestsGoWithTheScript() throws {
        let (project, root) = try makeProject()
        _ = try Remote(config: config).run([.synthesis, .implementation], project: project, root: root, log: { _ in })
        for run in ["synth_1", "impl_1"] {
            XCTAssertNotNil(checkpointManifest(run), run)
        }
        let synth = try XCTUnwrap(checkpointManifest("synth_1")), impl = try XCTUnwrap(checkpointManifest("impl_1"))
        XCTAssertEqual(impl.runs?["synth_1"], synth.runs?["synth_1"], "impl_1's record names the netlist it started from")
        XCTAssertNil(synth.runs?["impl_1"])
    }

    // MARK: Stop (the app's Stop button)

    func testStopFromAnotherThreadKillsVivadoReleasesTheLockAndFetchesNothing() throws {
        setenv("FAKE_VIVADO_MODE", "hang", 1)
        let (project, root) = try makeProject()
        let running = remoteFile(".running")
        let job = RemoteJob()
        let pressed = expectation(description: "Stop was pressed")
        Thread {
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: running.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            job.cancel()
            pressed.fulfill()
        }.start()
        defer { wait(for: [pressed], timeout: 25) }

        let started = Date()
        let box = LogBox()
        let result = try Remote(config: config).run([.synthesis], project: project, root: root, job: job) { box.append($0) }
        XCTAssertEqual(result.status, Shell.interruptedStatus)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "stopping doesn't wait for Vivado")
        XCTAssertTrue(box.value.contains("Stopping Vivado on buildbox"), box.value)
        XCTAssertTrue(calls.contains { $0.contains(Self.os == .windows ? "taskkill" : "pkill") }, "Vivado is killed by its marker: \(calls)")
        if Self.os == .linux {
            let pid = try XCTUnwrap(Int32(try String(contentsOf: remoteFile(".pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            for _ in 0..<100 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.05) }
            XCTAssertNotEqual(kill(pid, 0), 0, "the fake Vivado is still running")
        }
        XCTAssertFalse(lockExists, "the lock is released")
        XCTAssertEqual(calls.filter { $0.hasPrefix("scp") }.count, 1, "no results fetch after stopping")
        XCTAssertNil(checkpointManifest("synth_1"))
    }

    func testAJobStoppedBeforeItStartsDoesNothingRemote() throws {
        let (project, root) = try makeProject()
        let job = RemoteJob()
        job.cancel()
        let result = try Remote(config: config).run([.synthesis], project: project, root: root, job: job, log: { _ in })
        XCTAssertEqual(result.status, Shell.interruptedStatus)
        XCTAssertTrue(calls.isEmpty, "\(calls)")
    }

    func testLaunchRunsJobsBecomeVivadosThreadLimit() throws {
        let (project, root) = try makeProject()
        _ = try Remote(config: config).run([.synthesis], project: project, root: root, options: Project.FlowOptions(maxThreads: 6), log: { _ in })
        let tcl = try String(contentsOf: remoteFile(".fpga-bridge/demo/build.tcl"), encoding: .utf8)
        XCTAssertTrue(tcl.contains("\nset_param general.maxThreads 6\n"), tcl)
    }

    // MARK: Lock

    private func holdLock(owner: String?) throws {
        let dir = remoteFile(".fpga-bridge/lock")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let owner { try owner.write(to: dir.appendingPathComponent("owner.txt"), atomically: true, encoding: .utf8) }
    }

    var lockExists: Bool { FileManager.default.fileExists(atPath: remoteFile(".fpga-bridge/lock").path) }

    func testBuildFailsWithOwnerWhenMachineIsBusyAndLeavesTheirLockAlone() throws {
        try holdLock(owner: "alice@laptop building other since 2026-10-15T10:00:00Z")
        let (project, root) = try makeProject()

        XCTAssertThrowsError(try Remote(config: config).build(project: project, root: root)) { error in
            XCTAssertEqual(error as? RemoteError, .busy(owner: "alice@laptop building other since 2026-10-15T10:00:00Z"))
            XCTAssertTrue("\(error)".contains("alice@laptop"))
            XCTAssertTrue("\(error)".contains("fpga-bridge unlock"))
        }
        XCTAssertTrue(lockExists, "must not release a lock we did not take")
        XCTAssertFalse(calls.contains { $0.hasPrefix("scp") }, "nothing may be copied while busy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteFile(".fpga-bridge/demo").path))
    }

    func testBusyWithoutOwnerFile() throws {
        try holdLock(owner: nil)
        let (project, root) = try makeProject()
        XCTAssertThrowsError(try Remote(config: config).build(project: project, root: root)) { error in
            XCTAssertEqual(error as? RemoteError, .busy(owner: nil))
        }
        XCTAssertTrue(lockExists)
    }

    func testLockIsHeldDuringTheBuildAndReleasedAfterwards() throws {
        // The fake Vivado fails the run if the lock directory is missing while it runs.
        let (project, root) = try makeProject()
        XCTAssertEqual(try Remote(config: config).build(project: project, root: root), 0)
        XCTAssertFalse(lockExists)
    }

    func testLockIsReleasedAfterVivadoFails() throws {
        setenv("FAKE_VIVADO_MODE", "fail", 1)
        let (project, root) = try makeProject()
        XCTAssertEqual(try Remote(config: config).build(project: project, root: root), 1)
        XCTAssertFalse(lockExists)
    }

    func testSecondBuildSucceedsAfterTheFirstFinished() throws {
        let (project, root) = try makeProject()
        let remote = Remote(config: config)
        XCTAssertEqual(try remote.build(project: project, root: root), 0)
        XCTAssertEqual(try remote.build(project: project, root: root), 0)
    }

    func testUnlockRemovesStaleLockAndIsHarmlessWhenNoneExists() throws {
        try holdLock(owner: "crashed@laptop building demo since 2026-10-14T09:00:00Z")
        try Remote(config: config).unlock()
        XCTAssertFalse(lockExists)
        XCTAssertNoThrow(try Remote(config: config).unlock())
    }

    func testOwnerLineIsPlainTextEndingInALetter() {
        let line = Remote.ownerLine(project: "demo", date: Date(timeIntervalSince1970: 0),
                                    machine: "Mac Book!?.local", user: "me")
        XCTAssertEqual(line, "me@Mac Book__.local building demo since 1970-01-01T00:00:00Z")
        XCTAssertNil(line.range(of: "[^A-Za-z0-9@._: -]", options: .regularExpression), "cmd.exe metacharacter in \(line)")
        XCTAssertTrue(line.last?.isLetter == true, "a trailing digit before > would redirect a file handle")
    }

    // MARK: Cancel and connection loss

    func testCtrlCStopsRemoteVivadoReleasesLockAndSkipsFetch() throws {
        setenv("FAKE_VIVADO_MODE", "hang", 1)
        let (project, root) = try makeProject()
        let running = remoteFile(".running")

        // Press "Ctrl-C" once the fake Vivado reports that it is running. The signal handler is installed before the
        // remote command starts, so there is no fixed delay to get wrong. Give up after 20 s rather than hang.
        let pressed = expectation(description: "the fake Vivado started")
        Thread {
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: running.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if FileManager.default.fileExists(atPath: running.path) { kill(getpid(), SIGINT) }
            pressed.fulfill()
        }.start()
        defer { wait(for: [pressed], timeout: 25) }

        let started = Date()
        let status = try Remote(config: config).build(project: project, root: root)

        XCTAssertEqual(status, Shell.interruptedStatus)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "cancelling should not wait for Vivado to finish")

        let run = try XCTUnwrap(calls.first { $0.contains("-tclargs") })
        let token = try XCTUnwrap(run.range(of: "fpgabridge-[a-f0-9]{8}", options: .regularExpression)
            .map { String(run[$0].dropFirst("fpgabridge-".count)) })
        let cancel = try XCTUnwrap(calls.first { $0.contains(Self.os == .windows ? "taskkill" : "pkill") }, "no cancel command was sent: \(calls)")
        XCTAssertFalse(cancel.contains("fpgabridge-\(token)"), "the cancel command must not match itself")
        if Self.os == .windows {
            XCTAssertTrue(cancel.contains("'\(token)*'"), "cancel must target this job: \(cancel)")
            XCTAssertEqual(try String(contentsOf: remoteFile(".cancelled"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), token)
        } else {
            // The Linux stub really ran `pkill`: the fake Vivado must be gone.
            let pid = try XCTUnwrap(Int32(try String(contentsOf: remoteFile(".pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            for _ in 0..<100 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.05) }
            XCTAssertNotEqual(kill(pid, 0), 0, "pkill left the fake Vivado (pid \(pid)) running")
        }

        XCTAssertFalse(lockExists, "lock must be released after cancelling")
        XCTAssertEqual(calls.filter { $0.hasPrefix("scp") }.count, 1, "no results fetch after cancelling")
    }

    func testSignalHandlersAreRestoredAfterStream() throws {
        _ = try Shell.stream("true", [], onInterrupt: {})
        var action = sigaction()
        sigaction(SIGINT, nil, &action)
        // SIG_DFL is the null handler.
        XCTAssertEqual(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self), 0, "SIGINT must go back to its default behavior")
    }

    func testDroppedConnectionIsReportedWithTheJobDirectory() throws {
        setenv("FAKE_VIVADO_MODE", "lost", 1)
        let (project, root) = try makeProject()
        XCTAssertThrowsError(try Remote(config: config).build(project: project, root: root)) { error in
            XCTAssertEqual(error as? RemoteError, .connectionLost(jobDir: commands.path(".fpga-bridge", "demo")))
            XCTAssertTrue("\(error)".contains("fpga-bridge unlock"))
        }
        XCTAssertFalse(calls.filter { $0.hasPrefix("scp") }.count > 1, "no fetch after a lost connection")
    }

    func testKeepaliveOptionsAreSetOnEveryConnection() throws {
        let (project, root) = try makeProject()
        _ = try Remote(config: config).build(project: project, root: root)
        XCTAssertTrue(calls.allSatisfy { $0.contains("ServerAliveInterval=15") && $0.contains("ServerAliveCountMax=4") }, "\(calls)")
    }

    func testJobCommandsCarryTheMarkerOnlyWhereIntended() throws {
        try XCTSkipUnless(Self.os == .windows, "the Linux command lines are checked in RemoteCommandsTests")
        let build = Remote.buildCommand(vivadoPath: Self.vivadoPath, jobDir: #".fpga-bridge\demo"#, token: "a1b2c3d4")
        XCTAssertTrue(build.hasSuffix("-tclargs fpgabridge-a1b2c3d4"))
        let cancel = Remote.cancelCommand(token: "a1b2c3d4")
        XCTAssertTrue(cancel.contains("taskkill /F /T"))
        XCTAssertTrue(cancel.contains("$_.ProcessId -ne $PID"))
        XCTAssertFalse(cancel.contains("fpgabridge-a1b2c3d4"))
    }

    // MARK: Vivado version pin

    func testVersionPinWarnings() {
        func project(_ version: String?) -> Project {
            Project(name: "p", top: "t", part: "x", sources: ["s"], constraints: [], vivadoVersion: version)
        }
        let path = #"C:\Program Files\Xilinx\Vivado\2023.2\bin\vivado.bat"#
        XCTAssertNil(project(nil).versionWarning(vivadoPath: path))
        XCTAssertNil(project("2023.2").versionWarning(vivadoPath: path))
        XCTAssertNil(project("2023.2").versionWarning(vivadoPath: "/opt/Xilinx/Vivado/2023.2/bin/vivado"))

        let mismatch = project("2024.1").versionWarning(vivadoPath: path)
        XCTAssertTrue(mismatch?.contains("pinned to Vivado 2024.1") == true && mismatch?.contains("2023.2") == true, "\(String(describing: mismatch))")
        XCTAssertTrue(project("2023.2").versionWarning(vivadoPath: #"C:\tools\vivado.bat"#)?.contains("can't be read") == true)
    }

    func testVersionPinValidation() {
        func validate(_ v: String) throws {
            try Project(name: "p", top: "t", part: "x", sources: ["s"], constraints: [], vivadoVersion: v).validate()
        }
        XCTAssertNoThrow(try validate("2023.2"))
        XCTAssertNoThrow(try validate("2024.1"))
        XCTAssertThrowsError(try validate("23.2"))
        XCTAssertThrowsError(try validate("latest"))
        XCTAssertThrowsError(try validate("2023.2; calc"))
    }

    // MARK: Output capture (used by the app)

    func testBuildSendsProgressAndVivadoOutputToTheLogCallback() throws {
        let (project, root) = try makeProject()
        let box = LogBox()
        let status = try Remote(config: config).build(project: project, root: root) { box.append($0) }
        XCTAssertEqual(status, 0)
        let captured = box.value
        XCTAssertTrue(captured.contains("Copying 3 files to buildbox"), captured)
        XCTAssertTrue(captured.contains("fake-vivado: done"), "Vivado's output must be captured, not printed:\n\(captured)")
        XCTAssertTrue(captured.contains("Results in build/"), captured)
    }

    func testBuildFailureOutputIsCapturedToo() throws {
        setenv("FAKE_VIVADO_MODE", "fail", 1)
        let (project, root) = try makeProject()
        let box = LogBox()
        let status = try Remote(config: config).build(project: project, root: root) { box.append($0) }
        XCTAssertEqual(status, 1)
        let captured = box.value
        XCTAssertTrue(captured.contains("ERROR: [Synth 8-439]"), captured)
    }

    func testRunTclSendsOutputToTheLogCallback() throws {
        let box = LogBox()
        let status = try Remote(config: config).runTcl(script: "puts hello-from-tcl") { box.append($0) }
        XCTAssertEqual(status, 0)
        let captured = box.value
        XCTAssertTrue(captured.contains("puts hello-from-tcl"), captured)
    }

    // MARK: Tcl

    func testRunTclCopiesRunsAndCleansUp() throws {
        let status = try Remote(config: config).runTcl(script: "puts hello-from-tcl")
        XCTAssertEqual(status, 0)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: remoteFile(".fpga-bridge").path)
        XCTAssertTrue(leftovers.isEmpty, "job file was not deleted: \(leftovers)")
        let run = try XCTUnwrap(calls.first { $0.contains("-source " + commands.path(".fpga-bridge", "job-")) })
        XCTAssertTrue(run.contains(Self.vivadoPath))
        if Self.os == .windows { XCTAssertTrue(run.contains(#"call "\#(Self.vivadoPath)""#)) }
    }

    // MARK: The harness itself

    func testFakeSSHRejectsCommandsItDoesNotKnow() throws {
        try XCTSkipUnless(Self.os == .windows, "the Linux stub runs real shell commands")
        let result = try Remote(config: config).exec("format c:")
        XCTAssertEqual(result.status, 127)
        XCTAssertTrue(result.stderr.contains("unhandled command"))
    }

    func testFakeSCPRefusesDirectoriesWithoutRecursiveFlag() throws {
        let dir = tmp.appendingPathComponent("somedir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = try Shell.run("scp", [dir.path, "me@buildbox:thing"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not a regular file"))
    }
}

/// The same tests against a Linux build machine. The stub `ssh` runs each command in a real shell, with a fake
/// Vivado launcher, so these check the Linux command lines by running them.
final class LinuxFakeRemoteTests: FakeRemoteTests {
    override class var vivadoPath: String { "/tools/Xilinx/Vivado/2023.2/bin/vivado" }
    override class var otherVivadoPath: String { "/somewhere/else/vivado" }
    override class var os: BuildOS { .linux }
}
