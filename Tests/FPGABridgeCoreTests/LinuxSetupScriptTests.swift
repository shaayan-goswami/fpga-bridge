import XCTest
@testable import FPGABridgeCore

/// Runs `linux/setup.sh` for real, in a temp home, with a fake Tailscale and a fake Vivado. The script is written as
/// functions and only runs `main` when executed, so most tests load it and call one function.
final class LinuxSetupScriptTests: XCTestCase {
    var root: URL!
    var home: URL!
    var bin: URL!

    static let script: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("linux/setup.sh").path

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        bin = root.appendingPathComponent("bin")
        for dir in [home!, bin!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func bash(_ script: String, extra: [String: String] = [:]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        var env = ["HOME": home.path, "USER": "tester", "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        env.merge(extra) { _, new in new }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                             stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// Calls one function from the script.
    func call(_ call: String, extra: [String: String] = [:]) throws -> CommandResult {
        try bash("source '\(Self.script)'; \(call)", extra: extra)
    }

    func executable(_ path: String, _ body: String = "#!/bin/sh\n") throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func lines(_ result: CommandResult) -> [String] {
        result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Vivado

    func testBothInstallLayoutsAreFoundNewestFirst() throws {
        let tools = root.appendingPathComponent("tools").path
        try executable("\(tools)/Vivado/2023.2/bin/vivado")           // up to 2024: <root>/Vivado/<version>
        try executable("\(tools)/Vivado/2024.1/bin/vivado")
        try executable("\(tools)/2025.2/Vivado/bin/vivado")           // 2025 on: <root>/<version>/Vivado
        let found = lines(try call("find_vivado", extra: ["FPGA_BRIDGE_VIVADO_ROOTS": tools]))
        XCTAssertEqual(found, ["\(tools)/2025.2/Vivado/bin/vivado", "\(tools)/Vivado/2024.1/bin/vivado", "\(tools)/Vivado/2023.2/bin/vivado"])
    }

    func testFilesThatArentExecutableAndMissingFoldersAreIgnored() throws {
        let tools = root.appendingPathComponent("tools").path
        try executable("\(tools)/Vivado/2023.2/bin/vivado")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(tools)/Vivado/2023.2/bin/vivado")
        let found = try call("find_vivado", extra: ["FPGA_BRIDGE_VIVADO_ROOTS": "\(tools):/nonexistent/root"])
        XCTAssertEqual(lines(found), [])
    }

    func testVersionsCompareAsVersionsNotAsText() throws {
        let tools = root.appendingPathComponent("tools").path
        try executable("\(tools)/Vivado/2019.2/bin/vivado")
        try executable("\(tools)/Vivado/2019.10/bin/vivado")      // would sort before 2019.2 as text
        XCTAssertEqual(lines(try call("find_vivado", extra: ["FPGA_BRIDGE_VIVADO_ROOTS": tools])).first, "\(tools)/Vivado/2019.10/bin/vivado")
    }

    func testAPathWithASpaceSurvives() throws {
        let tools = root.appendingPathComponent("my tools").path
        try executable("\(tools)/2025.2/Vivado/bin/vivado")
        XCTAssertEqual(lines(try call("find_vivado", extra: ["FPGA_BRIDGE_VIVADO_ROOTS": tools])), ["\(tools)/2025.2/Vivado/bin/vivado"])
    }

    func testTheEnvironmentsVivadoIsFoundOnceEvenIfItIsAlsoInARoot() throws {
        let tools = root.appendingPathComponent("tools").path
        try executable("\(tools)/2025.2/Vivado/bin/vivado")
        let found = lines(try call("find_vivado", extra: ["FPGA_BRIDGE_VIVADO_ROOTS": tools, "XILINX_VIVADO": "\(tools)/2025.2/Vivado"]))
        XCTAssertEqual(found, ["\(tools)/2025.2/Vivado/bin/vivado"], "no duplicates")
    }

    // MARK: Keys

    func testAKeyIsAuthorizedWithThePermissionsSSHDemands() throws {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample fpga-bridge@mac"
        XCTAssertEqual(try call("authorize_key '\(key)'").status, 0)
        let file = home.appendingPathComponent(".ssh/authorized_keys")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), key + "\n")
        let attributes = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        XCTAssertEqual(try attributes(file), 0o600)
        XCTAssertEqual(try attributes(home.appendingPathComponent(".ssh")), 0o700)
    }

    func testAKeyIsNotAddedTwiceAndOtherKeysSurvive() throws {
        let existing = "ssh-rsa AAAAB3Existing someone@else"
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try (existing + "\n").write(to: home.appendingPathComponent(".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        let key = "ssh-ed25519 AAAAC3Example me@mac"
        XCTAssertEqual(try call("authorize_key '\(key)'").status, 0)
        XCTAssertEqual(try call("authorize_key '\(key)'").status, 3, "already there")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8), existing + "\n" + key + "\n")
    }

    func testWhitespaceAndWindowsLineEndingsAroundAKeyAreTrimmed() throws {
        XCTAssertEqual(try call(#"authorize_key "  ssh-ed25519 AAAA me@mac"$'\r\n'"#).status, 0)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8), "ssh-ed25519 AAAA me@mac\n")
    }

    func testSomethingThatIsNotAPublicKeyIsRefused() throws {
        XCTAssertEqual(try call("authorize_key 'hello world'").status, 2)
        XCTAssertEqual(try call("authorize_key ''").status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh/authorized_keys").path))
    }

    // MARK: Tailscale

    func testTheTailscaleNameLosesItsTrailingDot() throws {
        try executable(bin.appendingPathComponent("tailscale").path, """
        #!/bin/sh
        echo '{"Self":{"HostName":"buildbox","DNSName":"buildbox.tail1234.ts.net.","Online":true}}'
        """)
        XCTAssertEqual(lines(try call("tailscale_name")), ["buildbox.tail1234.ts.net"])
    }

    func testWithoutTailscaleThereIsNoName() throws {
        XCTAssertNotEqual(try call("tailscale_name").status, 0)
        try executable(bin.appendingPathComponent("tailscale").path, "#!/bin/sh\nexit 1\n")
        XCTAssertNotEqual(try call("tailscale_name").status, 0, "installed but not running")
    }

    // MARK: Whole script

    func testTheWholeScriptPrintsTheInitCommandForThisMachine() throws {
        let tools = root.appendingPathComponent("tools").path
        try executable("\(tools)/2025.2/Vivado/bin/vivado", "#!/bin/sh\necho 'vivado v2025.2 (64-bit)'\n")
        try executable(bin.appendingPathComponent("tailscale").path,
                       "#!/bin/sh\necho '{\"Self\":{\"DNSName\":\"buildbox.tail1234.ts.net.\"}}'\n")
        let result = try bash("'\(Self.script)' --public-key 'ssh-ed25519 AAAAKey me@mac'",
                              extra: ["FPGA_BRIDGE_VIVADO_ROOTS": tools])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("connected as buildbox.tail1234.ts.net"), result.stdout)
        XCTAssertTrue(result.stdout.contains("it starts: vivado v2025.2"), result.stdout)
        XCTAssertTrue(result.stdout.contains(#"fpga-bridge init --host buildbox.tail1234.ts.net --user tester --vivado "\#(tools)/2025.2/Vivado/bin/vivado" --os linux"#),
                      result.stdout)
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8).contains("AAAAKey"))
    }

    func testWithoutVivadoItSaysSoAndPrintsNoInitCommand() throws {
        let result = try bash("'\(Self.script)'", extra: ["FPGA_BRIDGE_VIVADO_ROOTS": root.appendingPathComponent("empty").path])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("No Vivado install found"), result.stdout)
        XCTAssertFalse(result.stdout.contains("fpga-bridge init --host"), "nothing useful to print yet")
        XCTAssertTrue(result.stdout.contains("No --public-key given"))
    }

    func testAVivadoThatWontStartIsReported() throws {
        let tools = root.appendingPathComponent("tools").path
        try executable("\(tools)/2025.2/Vivado/bin/vivado", "#!/bin/sh\necho 'ERROR: license check failed' >&2\nexit 1\n")
        let result = try bash("'\(Self.script)'", extra: ["FPGA_BRIDGE_VIVADO_ROOTS": tools])
        XCTAssertTrue(result.stdout.contains("didn't start from a login shell"), result.stdout)
    }

    func testUnknownOptionsAreRefused() throws {
        let result = try bash("'\(Self.script)' --bogus")
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("Unknown option"))
    }

    func testHelpPrintsTheUsageAndChangesNothing() throws {
        let result = try bash("'\(Self.script)' --help")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("--public-key"), result.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh").path))
    }
}
