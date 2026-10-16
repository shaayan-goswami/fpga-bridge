import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// A test case whose `openExampleProject()` writes into a folder of its own, deleted afterwards. Without this the
/// example went into the real Documents folder, and one test's saved settings leaked into the next.
@MainActor
class ExampleSandboxTestCase: XCTestCase {
    private(set) var examplesDirectory: URL!

    override func setUp() async throws {
        examplesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("examples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: examplesDirectory, withIntermediateDirectories: true)
        setenv("FPGA_BRIDGE_EXAMPLES_DIR", examplesDirectory.path, 1)
    }

    override func tearDown() async throws {
        unsetenv("FPGA_BRIDGE_EXAMPLES_DIR")
        try? FileManager.default.removeItem(at: examplesDirectory)
    }
}

@MainActor
final class ExampleSandboxTests: ExampleSandboxTestCase {
    func testTheExampleGoesIntoTheSandboxNotTheRealDocumentsFolder() throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        let project = try XCTUnwrap(model.projectURL)
        XCTAssertTrue(project.resolvingSymlinksInPath().path.hasPrefix(examplesDirectory.resolvingSymlinksInPath().path), project.path)
        XCTAssertFalse(project.path.contains("/Documents/"))
    }

    func testEachTestStartsFromAFreshExample() throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        XCTAssertNil(model.project?.settings, "nothing left over from another test")
        var changed = try XCTUnwrap(model.project)
        changed.settings = { var s = ProjectSettings(); s.bitstream.compress = true; return s }()
        try changed.save(to: XCTUnwrap(model.projectURL))
    }

    func testAndTheNextOneDoesNotSeeIt() throws {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        XCTAssertNil(model.project?.settings)
    }
}
