import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// A backend that holds every step until the test releases it, so a test decides exactly when each one finishes.
final class GatedBackend: Backend, @unchecked Sendable {
    let isDemo = true
    let hostName = "gated"
    let vivadoPath: String? = nil
    let canStop = true

    private let lock = NSLock()
    private var waiting: [(step: RunKind, resume: CheckedContinuation<RunOutcome, Never>)] = []

    func checkConnection() async -> ConnectionState { .demo }
    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {}

    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        await withCheckedContinuation { continuation in
            lock.lock(); waiting.append((step, continuation)); lock.unlock()
        }
    }

    var waitingCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }

    /// Finishes the oldest waiting step with `outcome`.
    func releaseOldest(_ outcome: RunOutcome) {
        lock.lock()
        let first = waiting.isEmpty ? nil : waiting.removeFirst()
        lock.unlock()
        first?.resume.resume(returning: outcome)
    }
}

/// A backend that completes every step except the bitstream, which it reports as cancelled.
final class CancelBitstreamBackend: Backend, @unchecked Sendable {
    let isDemo = true
    let hostName = "x"
    let vivadoPath: String? = nil
    let canStop = true
    func checkConnection() async -> ConnectionState { .demo }
    func runTcl(_ command: String, project: Project?, log: @escaping @Sendable (String) -> Void) async {}
    func run(_ step: RunKind, project: Project, directory: URL, log: @escaping @Sendable (String) -> Void) async -> RunOutcome {
        step == .bitstream ? RunOutcome(cancelled: true) : RunOutcome(completed: [step])
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    var tmp: URL!

    // The async variants run on the main actor, which `tmp` needs; the synchronous ones are nonisolated.
    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("appmodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    /// Makes a small project on disk and returns its directory.
    func makeProject(_ name: String = "demo") throws -> URL {
        let inputs = tmp.appendingPathComponent("inputs-\(name)")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let top = inputs.appendingPathComponent("top.v")
        try "module top(input clk); endmodule\n".write(to: top, atomically: true, encoding: .utf8)
        let tb = inputs.appendingPathComponent("tb.v")
        try "module tb; endmodule\n".write(to: tb, atomically: true, encoding: .utf8)
        var request = NewProjectRequest(name: name, location: tmp, part: "xc7a35tcpg236-1")
        request.designSources = [top]
        request.simulationSources = [tb]
        return try ProjectCreator.create(request)
    }

    func makeModel(_ backend: Backend) -> AppModel { AppModel(backend: backend, persist: false) }

    /// Waits (up to a few seconds) for a condition that depends on the model's async work.
    func until(_ description: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    // MARK: Runs

    func testRunImplementationRunsSynthesisFirstThenImplementation() async throws {
        let model = makeModel(DemoBackend(speed: 0))
        model.openProject(at: try makeProject())
        model.run(.implementation)
        try await until("the runs to finish") { !model.isRunning && model.runs[.implementation]?.status == .complete }
        XCTAssertEqual(model.runs[.synthesis]?.status, .complete)
        XCTAssertFalse(model.bitstreamReady)
    }

    func testCancelledRunCannotCorruptTheRunThatReplacesIt() async throws {
        let backend = GatedBackend()
        let model = makeModel(backend)
        let project = try makeProject()
        model.openProject(at: project)

        model.run(.synthesis)
        try await until("the first run to start") { backend.waitingCount == 1 }

        // Opening a project abandons the run. Its backend call is still outstanding.
        model.openProject(at: project)
        XCTAssertFalse(model.isRunning)
        model.run(.synthesis)
        try await until("the second run to start") { backend.waitingCount == 2 }
        XCTAssertEqual(model.runs[.synthesis]?.status, .running)

        // The abandoned run finishes first, as a success. That must not complete, or stop, the new run.
        backend.releaseOldest(RunOutcome(completed: [.synthesis]))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.isRunning, "the abandoned run's result must not end the new run")
        XCTAssertEqual(model.runs[.synthesis]?.status, .running)

        backend.releaseOldest(RunOutcome(completed: [.synthesis]))
        try await until("the new run to finish") { !model.isRunning }
        XCTAssertEqual(model.runs[.synthesis]?.status, .complete)
    }

    func testCancellingOnlyTheBitstreamStepLeavesImplementationComplete() async throws {
        let model = makeModel(CancelBitstreamBackend())
        model.openProject(at: try makeProject())
        model.run(.bitstream)
        try await until("the run to stop") { !model.isRunning }
        XCTAssertEqual(model.runs[.synthesis]?.status, .complete)
        XCTAssertEqual(model.runs[.implementation]?.status, .complete, "implementation finished; only write_bitstream was cancelled")
        XCTAssertFalse(model.bitstreamReady)
        XCTAssertEqual(model.lastOutcome, .cancelled)
    }

    // MARK: Errors are shown

    func testASourceThatCannotBeReadIsReportedInsteadOfShowingAnEmptyTree() throws {
        let model = makeModel(DemoBackend(speed: 0))
        let dir = try makeProject()
        let outside = tmp.appendingPathComponent("outside.v")
        try "module outside; endmodule".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("demo.srcs/sources_1/imports/link.v"), withDestinationURL: outside)

        model.openProject(at: dir)
        XCTAssertTrue(model.sourceTree.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("outside the project") == true, "\(String(describing: model.errorMessage))")
    }

    func testASystemErrorIsShownAsAReadableMessage() throws {
        let model = makeModel(DemoBackend(speed: 0))
        let dir = try makeProject()
        model.openProject(at: dir)
        let path = "demo.srcs/sources_1/imports/top.v"
        model.updateDraft("changed\n", for: path)
        // Make the target a directory so the write fails with a system error.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(path))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true)

        XCTAssertFalse(model.saveFile(path))
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.hasPrefix("Couldn't save top.v"), message)
        XCTAssertFalse(message.contains("Domain="), "a raw error dump isn't a message for people: \(message)")
        XCTAssertTrue(model.isDirty(path), "a failed save must keep the edit")
    }

    // MARK: Editing and saving

    func testSavingADesignFileWritesItAndMarksFinishedRunsOutOfDate() async throws {
        let model = makeModel(DemoBackend(speed: 0))
        let dir = try makeProject()
        model.openProject(at: dir)
        model.run(.implementation)
        try await until("the runs to finish") { !model.isRunning && model.runs[.implementation]?.status == .complete }

        let path = "demo.srcs/sources_1/imports/top.v"
        model.updateDraft("module top(input clk); // edited\nendmodule\n", for: path)
        XCTAssertTrue(model.isDirty(path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(path)), "module top(input clk); endmodule\n", "not on disk yet")

        XCTAssertTrue(model.saveFile(path))
        XCTAssertFalse(model.isDirty(path))
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent(path)).contains("// edited"))
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, true)
        XCTAssertEqual(model.runs[.implementation]?.outOfDate, true)
    }

    func testSavingATestbenchDoesNotMarkRunsOutOfDate() async throws {
        let model = makeModel(DemoBackend(speed: 0))
        model.openProject(at: try makeProject())
        model.run(.synthesis)
        try await until("synthesis to finish") { !model.isRunning && model.runs[.synthesis]?.status == .complete }

        let path = "demo.srcs/sim_1/imports/tb.v"
        model.updateDraft("module tb; // edited\nendmodule\n", for: path)
        XCTAssertTrue(model.saveFile(path))
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, false)
    }

    func testEditingBackToTheSavedTextIsNotAnEdit() throws {
        let model = makeModel(DemoBackend(speed: 0))
        model.openProject(at: try makeProject())
        let path = "demo.srcs/sources_1/imports/top.v"
        let original = model.contents(of: path)
        model.updateDraft(original + "x", for: path)
        XCTAssertTrue(model.isDirty(path))
        model.updateDraft(original, for: path)
        XCTAssertFalse(model.isDirty(path), "undoing the change must clear the edited marker")
    }

    // MARK: Unsaved changes

    func testSwitchingProjectsAsksFirstAndDiscardingProceeds() throws {
        let model = makeModel(DemoBackend(speed: 0))
        let first = try makeProject("first")
        let second = try makeProject("second")
        model.openProject(at: first)
        model.updateDraft("changed\n", for: "first.srcs/sources_1/imports/top.v")

        model.openProject(at: second)
        XCTAssertNotNil(model.unsavedPrompt, "unsaved edits must be asked about")
        XCTAssertEqual(model.project?.name, "first", "nothing may switch before the user answers")

        model.resolveUnsaved(.cancel)
        XCTAssertEqual(model.project?.name, "first")
        XCTAssertTrue(model.hasUnsavedChanges, "cancel keeps the edit")

        model.openProject(at: second)
        model.resolveUnsaved(.discard)
        XCTAssertEqual(model.project?.name, "second")
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("first.srcs/sources_1/imports/top.v")),
                       "module top(input clk); endmodule\n", "discarded edits never reach the disk")
    }

    func testSaveThenProceedWritesTheFileAndSwitches() throws {
        let model = makeModel(DemoBackend(speed: 0))
        let first = try makeProject("first")
        let second = try makeProject("second")
        model.openProject(at: first)
        let path = "first.srcs/sources_1/imports/top.v"
        model.updateDraft("saved before switching\n", for: path)

        model.openProject(at: second)
        model.resolveUnsaved(.save)
        XCTAssertEqual(model.project?.name, "second")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent(path)), "saved before switching\n")
    }

    func testClosingAnEditedTabAsksAndKeepsItOpenOnCancel() throws {
        let model = makeModel(DemoBackend(speed: 0))
        model.openProject(at: try makeProject())
        let path = "demo.srcs/sources_1/imports/top.v"
        model.openFile(path)
        model.updateDraft("edit\n", for: path)

        model.requestClose(.file(path))
        XCTAssertNotNil(model.unsavedPrompt)
        XCTAssertTrue(model.openTabs.contains(.file(path)))
        model.resolveUnsaved(.cancel)
        XCTAssertTrue(model.openTabs.contains(.file(path)))

        model.requestClose(.file(path))
        model.resolveUnsaved(.discard)
        XCTAssertFalse(model.openTabs.contains(.file(path)))
    }

    func testCleanTabsCloseWithoutAsking() throws {
        let model = makeModel(DemoBackend(speed: 0))
        model.openProject(at: try makeProject())
        let path = "demo.srcs/sources_1/imports/top.v"
        model.openFile(path)
        model.requestClose(.file(path))
        XCTAssertNil(model.unsavedPrompt)
        XCTAssertFalse(model.openTabs.contains(.file(path)))
    }
}
