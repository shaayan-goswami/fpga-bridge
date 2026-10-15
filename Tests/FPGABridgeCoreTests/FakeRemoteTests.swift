import XCTest
@testable import FPGABridgeCore

/// Runs the real `Remote` and `Doctor` code against stub `ssh`/`scp` scripts (see FakeRemote/) that act as a Windows
/// build machine. The stubs only accept the exact command lines fpga-bridge should send.
final class FakeRemoteTests: XCTestCase {
    static let vivadoPath = #"C:\Program Files\Xilinx\Vivado\2023.2\bin\vivado.bat"#

    var tmp: URL!
    var remoteHome: URL!
    var log: URL!
    var originalPath: String!
    let envKeys = ["FAKE_HOME", "FAKE_LOG", "FAKE_REPORT_DIR", "FAKE_VIVADO_PATH",
                   "FAKE_SSH_FAIL", "FAKE_VIVADO_MODE", "FAKE_SCP_FAIL"]

    override func setUpWithError() throws {
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.appendingPathComponent("fpga-bridge-test-\(UUID().uuidString)")
        let bin = tmp.appendingPathComponent("bin")
        remoteHome = tmp.appendingPathComponent("remote")
        log = tmp.appendingPathComponent("calls.log")
        let reports = tmp.appendingPathComponent("reports")
        for dir in [bin, remoteHome!, reports] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        for tool in ["ssh", "scp"] {
            let source = try XCTUnwrap(Bundle.module.url(forResource: tool, withExtension: nil, subdirectory: "FakeRemote"))
            let dest = bin.appendingPathComponent(tool)
            try fm.copyItem(at: source, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
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
        setenv("FAKE_VIVADO_PATH", #"C:\somewhere\else\vivado.bat"#, 1)
        let checks = Doctor.run(config: config, tailscale: tailscale())
        XCTAssertEqual(checks.map(\.level), [.ok, .ok, .fail], "\(checks)")
        XCTAssertTrue(checks.last?.detail.contains("not found on Windows") == true)
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

    func testDoctorReportsMissingTailscaleCLI() {
        let checks = Doctor.run(config: config, tailscale: { throw TailscaleError.notInstalled })
        XCTAssertEqual(checks.map(\.name), ["Tailscale"])
        XCTAssertEqual(checks.first?.level, .fail)
        XCTAssertTrue(calls.isEmpty)
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
    }

    func testBuildCallOrderAndCommands() throws {
        let (project, root) = try makeProject()
        _ = try Remote(config: config).build(project: project, root: root)

        XCTAssertEqual(calls.map { String($0.prefix(3)) }, ["ssh", "scp", "ssh", "scp"], "\(calls)")
        XCTAssertTrue(calls[0].contains("rmdir /s /q .fpga-bridge\\demo"), "stale remote job dir must be cleared first")
        XCTAssertTrue(calls[1].contains("-r") && calls[1].contains("me@buildbox:.fpga-bridge/"), "directory upload needs -r")
        XCTAssertTrue(calls[2].contains(#"call "\#(Self.vivadoPath)" -mode batch -nojournal -nolog -source build.tcl"#),
                      "the Vivado path has spaces and must stay quoted")
        XCTAssertTrue(calls[3].contains("-r") && calls[3].contains("me@buildbox:.fpga-bridge/demo/out"))
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
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { $0.contains("-i /keys/id_test") }, "\(calls)")
    }

    // MARK: Tcl

    func testRunTclCopiesRunsAndCleansUp() throws {
        let status = try Remote(config: config).runTcl(script: "puts hello-from-tcl")
        XCTAssertEqual(status, 0)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: remoteFile(".fpga-bridge").path)
        XCTAssertTrue(leftovers.isEmpty, "job file was not deleted: \(leftovers)")
        let run = try XCTUnwrap(calls.first { $0.contains("-source .fpga-bridge\\job-") })
        XCTAssertTrue(run.contains(#"call "\#(Self.vivadoPath)""#))
    }

    // MARK: The harness itself

    func testFakeSSHRejectsCommandsItDoesNotKnow() throws {
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
