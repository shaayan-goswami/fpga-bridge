import XCTest
@testable import FPGABridgeCore

/// The `windows-cmd-lines` CI job runs the remote command lines through a real cmd.exe. Those lines are written out
/// in the workflow, so this checks they are exactly what the code sends; otherwise CI would test something else.
final class CIWorkflowTests: XCTestCase {
    func testWorkflowRunsTheSameCommandLinesTheCodeSends() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workflow = root.appendingPathComponent(".github/workflows/ci.yml")
        guard let text = try? String(contentsOf: workflow, encoding: .utf8) else {
            throw XCTSkip("workflow not found at \(workflow.path)")
        }

        let commands: [String: String] = [
            "acquire": Remote.acquireLockCommand(owner: "ci@runner building demo since 2026-10-15T10:00:00Z"),
            "acquire (other owner)": Remote.acquireLockCommand(owner: "other@runner building demo since 2026-10-15T11:00:00Z"),
            "read owner": Remote.readOwnerCommand,
            "prep": Remote.prepCommand(jobDir: #".fpga-bridge\demo"#),
            "release": Remote.releaseLockCommand,
            "unlock": Remote.unlockCommand,
            "cancel": Remote.cancelCommand(token: "a1b2c3d4"),
            "read a checkpoint's manifest": RemoteCommands(.windows).readFile(#".fpga-bridge\demo.runs\synth_1\manifest.json"#),
        ]
        for (name, command) in commands {
            XCTAssertTrue(text.contains(command), "ci.yml no longer contains the \(name) command line:\n\(command)")
        }
    }

    /// The `linux-cmd-lines` job does the same for the Linux lines, on a real Linux runner.
    func testWorkflowRunsTheSameLinuxCommandLinesTheCodeSends() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workflow = root.appendingPathComponent(".github/workflows/ci.yml")
        guard let text = try? String(contentsOf: workflow, encoding: .utf8) else {
            throw XCTSkip("workflow not found at \(workflow.path)")
        }
        XCTAssertTrue(text.contains("linux-cmd-lines:"), "the Linux job is missing from ci.yml")

        let linux = RemoteCommands(.linux)
        let vivado = "/tmp/fpga-bridge-ci/vivado"
        let commands: [String: String] = [
            "acquire": linux.acquireLock(owner: "ci@runner building demo since 2026-10-15T10:00:00Z"),
            "acquire (other owner)": linux.acquireLock(owner: "other@runner building demo since 2026-10-15T11:00:00Z"),
            "read owner": linux.readOwner,
            "prep": linux.prep(jobDir: ".fpga-bridge/demo"),
            "release": linux.releaseLock,
            "unlock": linux.unlock,
            "vivado exists": linux.vivadoExists(vivado),
            "build": linux.build(vivadoPath: vivado, jobDir: ".fpga-bridge/demo", token: "a1b2c3d4"),
            "cancel": linux.cancel(token: "a1b2c3d4"),
            "read a checkpoint's manifest": linux.readFile(".fpga-bridge/demo.runs/synth_1/manifest.json"),
        ]
        for (name, command) in commands {
            XCTAssertTrue(text.contains(command), "ci.yml no longer contains the Linux \(name) command line:\n\(command)")
        }
    }
}
