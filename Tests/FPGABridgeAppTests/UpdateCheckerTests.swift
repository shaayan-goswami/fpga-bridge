import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// Stands in for GitHub: counts the questions and gives a fixed answer, or fails like an offline Mac.
final class FakeReleases: ReleaseFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var answer: Result<LatestRelease, Error>

    init(_ answer: Result<LatestRelease, Error>) { self.answer = answer }

    var calls: Int { lock.withLock { _calls } }

    func latestRelease() async throws -> LatestRelease {
        try lock.withLock { _calls += 1; return answer }.get()
    }

    static func tag(_ tag: String) -> FakeReleases {
        FakeReleases(.success(LatestRelease(tagName: tag, htmlURL: URL(string: "https://github.com/shaayan-goswami/fpga-bridge/releases/tag/\(tag)")!)))
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        suite = "updates-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func checker(_ fetcher: FakeReleases?, version: String? = "0.2.1") -> UpdateChecker {
        UpdateChecker(currentVersion: version, fetcher: fetcher, defaults: defaults, now: { [unowned self] in self.clock })
    }

    func testANewerReleaseShowsTheNoticeAndDownloadOpensItsPage() async {
        let github = FakeReleases.tag("v0.2.2")
        let updates = checker(github)
        var opened: [URL] = []
        updates.openURL = { opened.append($0) }
        await updates.checkAtLaunchIfDue()
        XCTAssertEqual(updates.available?.version, "0.2.2")
        updates.download()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/shaayan-goswami/fpga-bridge/releases/tag/v0.2.2"])
        XCTAssertNil(updates.available)
    }

    func testTheSameOrAnOlderVersionShowsNothing() async {
        let updates = checker(FakeReleases.tag("v0.2.1"))
        await updates.checkAtLaunchIfDue()
        XCTAssertNil(updates.available)
    }

    func testAsksGitHubAtMostOnceADayButKeepsShowingWhatItFound() async {
        let github = FakeReleases.tag("v0.3.0")
        await checker(github).checkAtLaunchIfDue()
        XCTAssertEqual(github.calls, 1)

        clock += 3_600
        let relaunched = checker(github)
        await relaunched.checkAtLaunchIfDue()
        XCTAssertEqual(github.calls, 1, "an hour later GitHub isn't asked again")
        XCTAssertEqual(relaunched.available?.version, "0.3.0", "but the notice is still there")

        clock += 86_400
        await checker(github).checkAtLaunchIfDue()
        XCTAssertEqual(github.calls, 2)
    }

    func testOfflineIsSilent() async {
        let github = FakeReleases(.failure(URLError(.notConnectedToInternet)))
        let updates = checker(github)
        await updates.checkAtLaunchIfDue()
        XCTAssertEqual(github.calls, 1)
        XCTAssertNil(updates.available)
        XCTAssertNil(updates.manualResult, "nothing is reported at launch")
    }

    func testTurnedOffInSettingsNeverAsks() async {
        let github = FakeReleases.tag("v9.0.0")
        let updates = checker(github)
        updates.isEnabled = false
        await updates.checkAtLaunchIfDue()
        XCTAssertEqual(github.calls, 0)
        XCTAssertNil(updates.available)
    }

    func testADevelopmentBuildWithNoVersionNeverAsks() async {
        let github = FakeReleases.tag("v9.0.0")
        await checker(github, version: nil).checkAtLaunchIfDue()
        XCTAssertEqual(github.calls, 0)
    }

    func testSkipThisVersionHidesItForGoodButANewerOneShows() async {
        let github = FakeReleases.tag("v0.2.2")
        let updates = checker(github)
        await updates.checkAtLaunchIfDue()
        updates.skipThisVersion()
        XCTAssertNil(updates.available)
        XCTAssertEqual(updates.skippedVersion, "0.2.2")

        clock += 2 * 86_400
        let later = checker(github)
        await later.checkAtLaunchIfDue()
        XCTAssertNil(later.available, "still skipped")

        github.answer = .success(LatestRelease(tagName: "v0.2.3", htmlURL: UpdateChecker.releasesPage))
        clock += 2 * 86_400
        let newer = checker(github)
        await newer.checkAtLaunchIfDue()
        XCTAssertEqual(newer.available?.version, "0.2.3")
    }

    func testDismissHidesOnlyUntilTheNextLaunch() async {
        let github = FakeReleases.tag("v0.2.2")
        let updates = checker(github)
        await updates.checkAtLaunchIfDue()
        updates.dismiss()
        XCTAssertNil(updates.available)
        let relaunched = checker(github)
        await relaunched.checkAtLaunchIfDue()
        XCTAssertEqual(relaunched.available?.version, "0.2.2")
    }

    func testCheckNowReportsWhatItFound() async {
        let github = FakeReleases.tag("v0.2.1")
        let updates = checker(github)
        await updates.checkNow()
        XCTAssertEqual(updates.manualResult, .upToDate("0.2.1"))

        github.answer = .failure(URLError(.notConnectedToInternet))
        await updates.checkNow()
        if case .failed = updates.manualResult {} else { XCTFail("\(String(describing: updates.manualResult))") }

        github.answer = .success(LatestRelease(tagName: "v0.4.0", htmlURL: UpdateChecker.releasesPage))
        await updates.checkNow()
        XCTAssertEqual(updates.manualResult, .available("0.4.0"))
        XCTAssertEqual(updates.available?.version, "0.4.0")
        XCTAssertEqual(github.calls, 3, "Check Now asks every time")
    }

    func testNoFetcherMeansNoNetwork() async {
        let updates = checker(nil)
        await updates.checkAtLaunchIfDue()
        await updates.checkNow()
        XCTAssertNil(updates.available)
    }
}
