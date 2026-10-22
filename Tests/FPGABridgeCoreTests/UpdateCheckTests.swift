import XCTest
@testable import FPGABridgeCore

final class UpdateCheckTests: XCTestCase {
    func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    func testReadsTagsAndBundleVersions() {
        XCTAssertEqual(v("v0.2.1").description, "0.2.1")
        XCTAssertEqual(v("0.2").description, "0.2.0")
        XCTAssertEqual(v("V1").description, "1.0.0")
        XCTAssertEqual(v("1.2.3-beta.2+sha.abc").description, "1.2.3-beta.2")
        for bad in ["", "v", "1.2.3.4", "1..2", "x.y", "1.2.-3", "1.2.3-", "1.2.3-a..b", "١.٢"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testComparesNumericallyNotAsText() {
        XCTAssertLessThan(v("0.2.9"), v("0.2.10"))
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
        XCTAssertLessThan(v("0.2.1"), v("v0.2.2"))
        XCTAssertLessThan(v("0.2.1"), v("1.0"))
        XCTAssertEqual(v("v1.0"), v("1.0.0"))
        XCTAssertFalse(v("0.3.0") < v("0.3.0"))
    }

    func testPreReleasesComeBeforeTheirRelease() {
        XCTAssertLessThan(v("0.3.0-beta.1"), v("0.3.0"))
        XCTAssertLessThan(v("0.3.0-alpha"), v("0.3.0-beta"))
        XCTAssertLessThan(v("0.3.0-beta.2"), v("0.3.0-beta.10"))
        XCTAssertLessThan(v("0.3.0-1"), v("0.3.0-alpha"))
        XCTAssertLessThan(v("0.3.0-beta"), v("0.3.0-beta.1"))
        XCTAssertLessThan(v("0.2.9"), v("0.3.0-beta.1"))
    }

    func testDecodesGitHubsAnswer() throws {
        let json = """
        {"url":"https://api.github.com/repos/x/y/releases/1","html_url":"https://github.com/shaayan-goswami/fpga-bridge/releases/tag/v0.2.2",
         "tag_name":"v0.2.2","name":"0.2.2","draft":false,"prerelease":false,"assets":[]}
        """
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v0.2.2")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/shaayan-goswami/fpga-bridge/releases/tag/v0.2.2")
        XCTAssertEqual(release.version, v("0.2.2"))
    }

    func testOffersOnlyANewerPublishedReleaseThatWasNotSkipped() {
        let page = URL(string: "https://example.com")!
        let release = LatestRelease(tagName: "v0.2.2", htmlURL: page)
        XCTAssertEqual(UpdateCheck.offer(release, current: "0.2.1", skipped: nil), v("0.2.2"))
        XCTAssertNil(UpdateCheck.offer(release, current: "0.2.2", skipped: nil), "same version")
        XCTAssertNil(UpdateCheck.offer(release, current: "0.3.0", skipped: nil), "running something newer")
        XCTAssertNil(UpdateCheck.offer(release, current: "0.2.1", skipped: "0.2.2"), "skipped")
        XCTAssertEqual(UpdateCheck.offer(LatestRelease(tagName: "v0.2.3", htmlURL: page), current: "0.2.1", skipped: "0.2.2"), v("0.2.3"),
                       "a newer one than the skipped version still shows")
        XCTAssertNil(UpdateCheck.offer(release, current: nil, skipped: nil), "a development build has no version")
        XCTAssertNil(UpdateCheck.offer(LatestRelease(tagName: "nightly", htmlURL: page), current: "0.2.1", skipped: nil))
        XCTAssertNil(UpdateCheck.offer(LatestRelease(tagName: "v0.3.0", htmlURL: page, prerelease: true), current: "0.2.1", skipped: nil))
        XCTAssertNil(UpdateCheck.offer(LatestRelease(tagName: "v0.3.0", htmlURL: page, draft: true), current: "0.2.1", skipped: nil))
    }

    func testAsksAtMostOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3_600), now: now), "a clock set back")
    }
}
