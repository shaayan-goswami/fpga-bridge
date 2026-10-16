import XCTest
@testable import FPGABridgeCore

final class WaveformViewerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func install(_ name: String, script: String = "#!/bin/sh\n") throws -> String {
        let path = dir.appendingPathComponent(name)
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    func testSurferIsPreferredOverGTKWave() throws {
        try install("gtkwave")
        XCTAssertEqual(WaveformViewer.locate(path: dir.path, searchPaths: [])?.name, "gtkwave")
        try install("surfer")
        XCTAssertEqual(WaveformViewer.locate(path: dir.path, searchPaths: [])?.name, "surfer")
        XCTAssertNil(WaveformViewer.locate(path: "/nonexistent", searchPaths: []))
        XCTAssertNotNil(WaveformViewer.locate(path: "", searchPaths: [dir.path]), "the app has no shell PATH")
    }

    func testOpenLaunchesTheViewerWithTheFileAndDoesNotWait() throws {
        let marker = dir.appendingPathComponent("args.txt").path
        let path = try install("surfer", script: "#!/bin/sh\necho \"$1\" > \"\(marker)\"\nsleep 5\n")
        let started = Date()
        try WaveformViewer(executable: path).open(URL(fileURLWithPath: "/tmp/some wave.vcd"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "returns while the viewer is still running")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker) { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                       "/tmp/some wave.vcd", "a path with a space arrives as one argument")
    }

    func testOpeningWithAMissingProgramFails() {
        XCTAssertThrowsError(try WaveformViewer(executable: "/nonexistent/surfer").open(URL(fileURLWithPath: "/tmp/x.vcd")))
    }

    func testTheCheckIsAWarningThatNamesTheInstallCommand() throws {
        let missing = WaveformViewer.check(locate: { nil })
        XCTAssertEqual(missing.level, .warn)
        XCTAssertTrue(missing.detail.contains("brew install surfer"))
        XCTAssertEqual(WaveformViewer.check(locate: { WaveformViewer(executable: "/opt/homebrew/bin/surfer") }).detail, "surfer")
        XCTAssertTrue(WaveformViewerError.notInstalled.userMessage.contains("brew install surfer"))
    }
}
