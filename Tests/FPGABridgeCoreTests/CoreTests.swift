import XCTest
@testable import FPGABridgeCore

final class CoreTests: XCTestCase {
    func testTailscaleParseAndPeerMatching() throws {
        let json = """
        {
          "BackendState": "Running",
          "Peer": {
            "nodekey:abc": {
              "HostName": "DESKTOP-VIV",
              "DNSName": "desktop-viv.tail1234.ts.net.",
              "TailscaleIPs": ["100.64.0.7", "fd7a::7"],
              "Online": true
            }
          }
        }
        """
        let status = try TailscaleStatus.parse(json: Data(json.utf8))
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.peer(matching: "desktop-viv")?.online, true)
        XCTAssertEqual(status.peer(matching: "desktop-viv.tail1234.ts.net")?.hostName, "DESKTOP-VIV")
        XCTAssertEqual(status.peer(matching: "100.64.0.7")?.hostName, "DESKTOP-VIV")
        XCTAssertNil(status.peer(matching: "other"))
    }

    /// A stand-in Tailscale that, like the real app binary, only works as a CLI when TERM is "dumb"-or-set and
    /// otherwise tries to start its GUI.
    func fakeTailscale(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Tailscale")
        try "#!/bin/sh\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    func testTailscaleIsCalledWithATermSoTheAppBinaryActsAsACLI() throws {
        // Passes only if our override is applied, whatever TERM this test process happens to have.
        let cli = try fakeTailscale(#"""
        [ "$TERM" = "dumb" ] || { echo "The Tailscale GUI failed to start"; exit 1; }
        echo '{"BackendState":"Running"}'
        """#)
        XCTAssertTrue(try Tailscale.status(cli: cli).isRunning)
    }

    func testAFailureSaysWhatTailscalePrintedEvenOnStdout() throws {
        let onStdout = try fakeTailscale(#"echo "The Tailscale GUI failed to start"; exit 1"#)
        XCTAssertThrowsError(try Tailscale.status(cli: onStdout)) {
            XCTAssertTrue($0.userMessage.contains("The Tailscale GUI failed to start"), $0.userMessage)
        }
        let silent = try fakeTailscale("exit 3")
        XCTAssertThrowsError(try Tailscale.status(cli: silent)) {
            XCTAssertTrue($0.userMessage.contains("exit status 3"), $0.userMessage)
        }
    }

    func testShellRunAddsEnvironmentVariables() throws {
        let result = try Shell.run("/usr/bin/env", [], environment: ["FPGA_BRIDGE_TEST_VAR": "hello"])
        XCTAssertTrue(result.stdout.contains("FPGA_BRIDGE_TEST_VAR=hello"))
        XCTAssertTrue(result.stdout.contains("PATH="), "the rest of the environment is kept")
    }

    func testTailscaleStoppedState() throws {
        let status = try TailscaleStatus.parse(json: Data(#"{"BackendState":"Stopped"}"#.utf8))
        XCTAssertFalse(status.isRunning)
        XCTAssertTrue(status.peers.isEmpty)
    }

    func testConfigRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        let config = BridgeConfig(host: "desktop-viv", user: "me",
                                  vivadoPath: #"C:\Xilinx\Vivado\2023.2\bin\vivado.bat"#)
        try config.save(to: url)
        XCTAssertEqual(try BridgeConfig.load(from: url), config)
    }

    private func makeProjectDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for dir in ["src/sub", "constraints"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["src/top.v", "src/sub/alu.sv", "src/sub/ram.vhd", "src/notes.txt", "constraints/pins.xdc"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return root
    }

    func testProjectResolvesFilesByExtension() throws {
        let root = try makeProjectDir()
        let project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1",
                              sources: ["src"], constraints: ["constraints"])
        XCTAssertEqual(try project.resolveSources(in: root), ["src/sub/alu.sv", "src/sub/ram.vhd", "src/top.v"])
        XCTAssertEqual(try project.resolveConstraints(in: root), ["constraints/pins.xdc"])
    }

    func testProjectRejectsEscapingAndMissingPaths() throws {
        let root = try makeProjectDir()
        for bad in ["../outside", "/etc", "nope"] {
            let project = Project(name: "demo", top: "top", part: "p", sources: [bad], constraints: [])
            XCTAssertThrowsError(try project.resolveSources(in: root), bad)
        }
    }

    func testProjectValidationRejectsUnsafeNames() {
        XCTAssertThrowsError(try Project(name: "a b", top: "top", part: "p", sources: ["s"], constraints: []).validate())
        XCTAssertThrowsError(try Project(name: "ok", top: "t; exec rm", part: "p", sources: ["s"], constraints: []).validate())
        XCTAssertNoThrow(try Project(name: "ok-1", top: "top_mod", part: "xc7a35tcpg236-1", sources: ["s"], constraints: []).validate())
    }

    func testBuildScriptOrderAndReaders() {
        let project = Project(name: "demo", top: "top", part: "xc7a35tcpg236-1", sources: ["src"], constraints: ["c"])
        let tcl = project.buildScript(sources: ["src/top.v", "src/alu.sv", "src/ram.vhd"], constraints: ["c/pins.xdc"])
        let lines = tcl.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("read_verilog {src/top.v}"))
        XCTAssertTrue(lines.contains("read_verilog -sv {src/alu.sv}"))
        XCTAssertTrue(lines.contains("read_vhdl {src/ram.vhd}"))
        XCTAssertTrue(lines.contains("read_xdc {c/pins.xdc}"))
        XCTAssertTrue(lines.contains("synth_design -top top -part xc7a35tcpg236-1"))
        let order = ["synth_design", "opt_design", "place_design", "route_design", "write_bitstream"]
            .map { step in lines.firstIndex { $0.hasPrefix(step) }! }
        XCTAssertEqual(order, order.sorted())
    }

    func testVivadoCommandQuotesPathWithSpaces() {
        let cmd = Remote.vivadoCommand(vivadoPath: #"C:\Program Files\Xilinx\Vivado\2023.2\bin\vivado.bat"#,
                                       tclFile: #".fpga-bridge\job.tcl"#)
        XCTAssertTrue(cmd.hasPrefix("call \""))
        XCTAssertTrue(cmd.contains("-mode batch"))
        XCTAssertTrue(cmd.hasSuffix(#"-source .fpga-bridge\job.tcl"#))
    }
}
