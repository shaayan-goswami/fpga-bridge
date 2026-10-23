import XCTest
@testable import FPGABridgeCore

/// The release workflow and the in-app update check have to agree: the app asks GitHub for the latest published
/// release of this repository, and the workflow is what puts the zip on it.
final class ReleaseWorkflowTests: XCTestCase {
    func text(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not found")
        }
        return text
    }

    func testTheReleaseWorkflowBuildsZipsAndAttachesTheApp() throws {
        let workflow = try text(".github/workflows/release.yml")
        for piece in [
            "tags: [\"v*\"]",
            "fetch-depth: 0",
            "scripts/make-app.sh",
            "ditto -c -k --norsrc --keepParent \"dist/FPGA Bridge.app\" FPGA-Bridge.zip",
            "gh release create \"$tag\" FPGA-Bridge.zip --draft",
            "gh release upload \"$tag\" FPGA-Bridge.zip --clobber",
            "GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}",
            "contents: write",
        ] {
            XCTAssertTrue(workflow.contains(piece), "release.yml no longer contains: \(piece)")
        }
    }

    func testTheUpdateCheckAsksThisRepository() {
        XCTAssertEqual(GitHubReleaseFetcher.latestReleaseURL.absoluteString,
                       "https://api.github.com/repos/shaayan-goswami/fpga-bridge/releases/latest")
    }

    func testIssueTemplatesAskForWhatTriageNeeds() throws {
        let board = try text(".github/ISSUE_TEMPLATE/board-test.yml")
        for piece in ["label: Board", "label: Vivado version", "label: What worked", "fpga-bridge doctor"] {
            XCTAssertTrue(board.contains(piece), "board-test.yml is missing \(piece)")
        }
        // Every board in the catalog is offered.
        for board in BoardCatalog.all { XCTAssertTrue(try text(".github/ISSUE_TEMPLATE/board-test.yml").contains("- \(board.displayName)\n"), board.displayName) }
        XCTAssertTrue(try text(".github/ISSUE_TEMPLATE/config.yml").contains("blank_issues_enabled: false"))
        XCTAssertTrue(try text(".github/ISSUE_TEMPLATE/bug.yml").contains("name: Bug report"))
    }
}
