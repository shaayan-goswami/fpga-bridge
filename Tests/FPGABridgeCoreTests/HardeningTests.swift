import XCTest
@testable import FPGABridgeCore

/// Input checks: names that would generate invalid HDL, config values that would change a command line, and paths
/// that leave the project.
final class HardeningTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: Reserved words

    func testReservedWordsAreRefusedAsModulePortAndArchitectureNames() {
        for word in ["module", "input", "end", "wire", "entity", "ENTITY", "Begin", "signal", "always"] {
            XCTAssertTrue(HDLTemplate.isReservedWord(word), word)
            XCTAssertThrowsError(try ModuleDefinition(name: word).validate(), "module \(word)") {
                XCTAssertEqual($0 as? ModuleDefinitionError, .reservedWord(word))
            }
            XCTAssertThrowsError(try ModuleDefinition(name: "top", ports: [PortDefinition(name: word)]).validate(), "port \(word)")
            XCTAssertThrowsError(try ModuleDefinition(name: "top", architecture: word).validate(), "architecture \(word)")
        }
    }

    func testOrdinaryNamesAreNotReserved() {
        for name in ["top", "blinky", "clk", "rst", "led", "count", "data", "start", "busy", "tx", "debounce", "wire1", "input_a"] {
            XCTAssertFalse(HDLTemplate.isReservedWord(name), name)
        }
    }

    func testAFileNamedAfterAKeywordIsRefusedWhenNoModuleIsDefined() throws {
        var request = NewProjectRequest(name: "p", location: tmp, part: "x")
        request.newFiles = [NewFile(set: .design, name: "wire")]
        XCTAssertThrowsError(try ProjectCreator.create(request)) { XCTAssertEqual($0 as? ModuleDefinitionError, .reservedWord("wire")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("p").path), "nothing may be left behind")

        request.newFiles = [NewFile(set: .constraints, name: "module")]
        XCTAssertNoThrow(try ProjectCreator.create(request), "a constraints file is not a module, so any name is fine")
    }

    // MARK: Error messages

    func testUserMessageUsesOurDescriptionsAndLocalizedTextForSystemErrors() {
        XCTAssertEqual(ModuleDefinitionError.duplicatePort("a").userMessage, ModuleDefinitionError.duplicatePort("a").description)
        let system = CocoaError(.fileWriteNoPermission)
        XCTAssertEqual(system.userMessage, system.localizedDescription)
        XCTAssertFalse(system.userMessage.contains("Domain="), "a raw error dump isn't a message for people")
    }

    // MARK: Config

    func testConfigRejectsValuesThatCouldChangeACommand() throws {
        let good = BridgeConfig(host: "buildbox.tail1234.ts.net", user: "me", vivadoPath: #"C:\Program Files\Xilinx\Vivado\2023.2\bin\vivado.bat"#)
        XCTAssertNoThrow(try good.validate())
        XCTAssertNoThrow(try BridgeConfig(host: "100.64.0.7", user: "me.smith", vivadoPath: "x").validate())
        XCTAssertNoThrow(try BridgeConfig(host: "fd7a::7", user: "me", vivadoPath: "x").validate())

        func rejects(_ config: BridgeConfig, _ why: String) {
            XCTAssertThrowsError(try config.validate(), why) {
                guard case .invalid = $0 as? ConfigError else { return XCTFail("\($0)") }
            }
        }
        rejects(BridgeConfig(host: "-oProxyCommand=x", user: "me", vivadoPath: "x"), "host starting with -")
        rejects(BridgeConfig(host: "a b", user: "me", vivadoPath: "x"), "host with a space")
        rejects(BridgeConfig(host: "", user: "me", vivadoPath: "x"), "empty host")
        rejects(BridgeConfig(host: "h", user: "-oProxyCommand=x", vivadoPath: "x"), "user starting with -")
        rejects(BridgeConfig(host: "h", user: "me; rm", vivadoPath: "x"), "user with a semicolon")
        for bad in [#"C:\v.bat" & calc"#, "C:\\v|x.bat", "C:\\v>x.bat", "C:\\%PATH%\\v.bat", "C:\\v^.bat", "C:\\v\n.bat", ""] {
            rejects(BridgeConfig(host: "h", user: "u", vivadoPath: bad), "vivado path \(bad.debugDescription)")
        }
        rejects(BridgeConfig(host: "h", user: "u", vivadoPath: "x", sshKeyPath: "a\nb"), "key path with a newline")
    }

    func testSaveAndLoadRefuseInvalidConfigs() throws {
        let url = tmp.appendingPathComponent("config.json")
        XCTAssertThrowsError(try BridgeConfig(host: "-x", user: "u", vivadoPath: "v").save(to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an invalid config must not be written")

        try #"{"host":"-x","user":"u","vivadoPath":"v"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BridgeConfig.load(from: url), "a hand-edited bad file is refused too")
    }

    // MARK: Paths

    func makeProject() throws -> (Project, URL) {
        let root = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "module a; endmodule".write(to: root.appendingPathComponent("src/a.v"), atomically: true, encoding: .utf8)
        return (Project(name: "p", top: "a", part: "x", sources: ["src"], constraints: []), root)
    }

    func testASymlinkLeavingTheProjectIsRefused() throws {
        let (project, root) = try makeProject()
        let outside = tmp.appendingPathComponent("secret.v")
        try "module secret; endmodule".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/link.v"), withDestinationURL: outside)

        XCTAssertThrowsError(try project.resolveSources(in: root)) {
            XCTAssertTrue("\($0)".contains("outside the project"), "\($0)")
        }
        // Naming the link directly is refused as well.
        let direct = Project(name: "p", top: "a", part: "x", sources: ["src/link.v"], constraints: [])
        XCTAssertThrowsError(try direct.resolveSources(in: root))
    }

    func testASymlinkStayingInsideTheProjectIsFine() throws {
        let (project, root) = try makeProject()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/alias.v"),
                                                   withDestinationURL: root.appendingPathComponent("src/a.v"))
        XCTAssertNoThrow(try project.resolveSources(in: root))
    }

    /// `fpga-bridge new` writes "." as the source and constraint folder, so a project's own directory must be accepted.
    /// (Found by the first real build: the symlink check refused ".".)
    func testTheProjectDirectoryItselfIsAValidEntry() throws {
        let (_, root) = try makeProject()
        let project = Project(name: "p", top: "a", part: "x", sources: ["."], constraints: ["."])
        XCTAssertEqual(try project.resolveSources(in: root), ["src/a.v"])
        XCTAssertNoThrow(try project.resolveConstraints(in: root))
    }

    func testTheVivadoVersionIsReadFromBothInstallLayouts() {
        XCTAssertEqual(Project.version(in: #"C:\Xilinx\Vivado\2023.2\bin\vivado.bat"#), "2023.2")
        XCTAssertEqual(Project.version(in: #"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"#), "2025.2")
        XCTAssertEqual(Project.version(in: "/opt/Xilinx/Vivado/2022.1/bin/vivado"), "2022.1")
        XCTAssertNil(Project.version(in: #"C:\tools\vivado.bat"#))
        XCTAssertNil(Project.version(in: #"C:\2025.2\other\vivado.bat"#))
    }

    func testEquivalentPathSpellingsCountOnce() throws {
        let (_, root) = try makeProject()
        let project = Project(name: "p", top: "a", part: "x", sources: ["src/a.v", "./src/a.v", "src/../src/a.v"], constraints: [])
        XCTAssertThrowsError(try project.resolveSources(in: root), "'..' is still not allowed")
        let dotted = Project(name: "p", top: "a", part: "x", sources: ["src/a.v", "./src/a.v", "src//a.v"], constraints: [])
        XCTAssertEqual(try dotted.resolveSources(in: root), ["src/a.v"])
    }
}
