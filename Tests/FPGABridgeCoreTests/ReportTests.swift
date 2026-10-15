import XCTest
@testable import FPGABridgeCore

final class ReportTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rpt", subdirectory: "Fixtures"), name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Timing

    func testTimingPass() throws {
        let t = try TimingSummary.parse(fixture("timing_pass"))
        XCTAssertEqual(t.wns, 7.612)
        XCTAssertEqual(t.tns, 0)
        XCTAssertEqual(t.tnsFailingEndpoints, 0)
        XCTAssertEqual(t.tnsTotalEndpoints, 18)
        XCTAssertEqual(t.whs, 0.171)
        XCTAssertEqual(t.thsTotalEndpoints, 18)
        XCTAssertTrue(t.isTimed)
        XCTAssertTrue(t.constraintsMet)
    }

    func testTimingFail() throws {
        let t = try TimingSummary.parse(fixture("timing_fail"))
        XCTAssertEqual(t.wns, -1.234)
        XCTAssertEqual(t.tns, -12.3)
        XCTAssertEqual(t.tnsFailingEndpoints, 14)
        XCTAssertEqual(t.tnsTotalEndpoints, 23)
        XCTAssertFalse(t.constraintsMet)
    }

    func testTimingWithNoClocksIsUnconstrained() throws {
        let t = try TimingSummary.parse(fixture("timing_noclock"))
        XCTAssertNil(t.wns)
        XCTAssertNil(t.whs)
        XCTAssertFalse(t.isTimed)
        XCTAssertFalse(t.constraintsMet)
    }

    func testTimingGarbageThrows() throws {
        XCTAssertThrowsError(try TimingSummary.parse(fixture("timing_garbage")))
    }

    func testTimingVerdictFallsBackToNumbersWhenLineMissing() throws {
        let text = try fixture("timing_fail").replacingOccurrences(of: "Timing constraints are not met.", with: "")
        XCTAssertFalse(try TimingSummary.parse(text).constraintsMet)
    }

    // MARK: Utilization

    func testUtilization7Series() throws {
        let u = try UtilizationSummary.parse(fixture("utilization_7series"))
        XCTAssertEqual(u.usage(.lut), ResourceUsage(kind: .lut, used: 12, available: 20800))
        XCTAssertEqual(u.usage(.ff), ResourceUsage(kind: .ff, used: 8, available: 41600))
        XCTAssertEqual(u.usage(.bram), ResourceUsage(kind: .bram, used: 2.5, available: 50))
        XCTAssertEqual(u.usage(.dsp), ResourceUsage(kind: .dsp, used: 3, available: 90))
        XCTAssertEqual(u.usage(.io), ResourceUsage(kind: .io, used: 4, available: 106))
        XCTAssertEqual(u.usage(.bram)?.percent ?? 0, 5.0, accuracy: 0.001)
    }

    func testUtilizationIgnoresIndentedSubRows() throws {
        // "LUT as Logic" has the same numbers as "Slice LUTs" here; if sub-rows were read, nothing would break,
        // so check a sub-row that differs: "RAMB36/FIFO*" (2) vs "Block RAM Tile" (2.5).
        let u = try UtilizationSummary.parse(fixture("utilization_7series"))
        XCTAssertEqual(u.usage(.bram)?.used, 2.5)
        XCTAssertEqual(u.resources.count, 5)
    }

    func testUtilizationOlderLayoutWithoutProhibitedColumn() throws {
        let u = try UtilizationSummary.parse(fixture("utilization_older"))
        XCTAssertEqual(u.usage(.lut), ResourceUsage(kind: .lut, used: 30, available: 20800))
        XCTAssertEqual(u.usage(.ff)?.used, 16)
        XCTAssertNil(u.usage(.bram))
    }

    func testUtilizationGarbageThrows() {
        XCTAssertThrowsError(try UtilizationSummary.parse("nothing useful here\n"))
    }

    func testClbRowNamesMapToTheSameKinds() {
        XCTAssertEqual(UtilizationSummary.kind(forRowName: "CLB LUTs*"), .lut)
        XCTAssertEqual(UtilizationSummary.kind(forRowName: "CLB Registers"), .ff)
        XCTAssertNil(UtilizationSummary.kind(forRowName: "LUT as Logic"))
    }

    // MARK: Rendering and loading

    func testRenderPassingDesign() throws {
        let summary = BuildSummary(
            timing: try TimingSummary.parse(fixture("timing_pass")),
            utilization: try UtilizationSummary.parse(fixture("utilization_7series")), notes: [])
        let text = summary.render()
        XCTAssertTrue(text.contains("Timing     MET"), text)
        XCTAssertTrue(text.contains("setup WNS +7.612 ns"), text)
        XCTAssertTrue(text.contains("hold WHS +0.171 ns"), text)
        XCTAssertTrue(text.contains("LUT 12/20800 (0.1%)"), text)
        XCTAssertTrue(text.contains("BRAM 2.5/50 (5.0%)"), text)
        XCTAssertTrue(text.contains("DSP 3/90 (3.3%)"), text)
    }

    func testRenderFailingDesign() throws {
        let summary = BuildSummary(timing: try TimingSummary.parse(fixture("timing_fail")), utilization: nil, notes: [])
        let text = summary.render()
        XCTAssertTrue(text.contains("NOT MET"), text)
        XCTAssertTrue(text.contains("setup WNS -1.234 ns (TNS -12.300 ns, 14 of 23 endpoints failing)"), text)
    }

    func testRenderUnconstrainedDesign() throws {
        let summary = BuildSummary(timing: try TimingSummary.parse(fixture("timing_noclock")), utilization: nil, notes: [])
        XCTAssertTrue(summary.render().contains("UNCONSTRAINED"))
        XCTAssertFalse(summary.render().contains("MET   "))
    }

    func testLoadFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fixture("timing_pass").write(to: dir.appendingPathComponent("timing_summary.rpt"), atomically: true, encoding: .utf8)
        try fixture("utilization_7series").write(to: dir.appendingPathComponent("utilization.rpt"), atomically: true, encoding: .utf8)

        let summary = BuildSummary.load(from: dir)
        XCTAssertNotNil(summary.timing)
        XCTAssertNotNil(summary.utilization)
        XCTAssertTrue(summary.notes.isEmpty)
    }

    func testMissingAndBrokenReportsBecomeNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fixture("timing_garbage").write(to: dir.appendingPathComponent("timing_summary.rpt"), atomically: true, encoding: .utf8)
        // utilization.rpt is absent

        let summary = BuildSummary.load(from: dir)
        XCTAssertNil(summary.timing)
        XCTAssertNil(summary.utilization)
        XCTAssertEqual(summary.notes.count, 2)
        XCTAssertTrue(summary.render().contains("Note: timing_summary.rpt"))
        XCTAssertTrue(summary.render().contains("utilization.rpt: not found"))
    }
}
