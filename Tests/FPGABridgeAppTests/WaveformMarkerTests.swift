import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// Markers, dividers and the saved layout (Vivado's markers and .wcfg).
@MainActor
final class WaveformMarkerTests: XCTestCase {
    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func vcd(extra: Bool = true) -> String {
        """
        $timescale 1ns $end
        $scope module tb $end
        $var reg 1 ! clk $end
        $var reg 8 " count [7:0] $end
        \(extra ? "$var reg 1 # done $end\n" : "")$upscope $end
        $enddefinitions $end
        #0
        0!
        b0 "
        #1000
        1!
        #10000
        0!
        """
    }

    func model(_ text: String? = nil, layout: URL? = nil) throws -> WaveformModel {
        let model = WaveformModel()
        model.saveDelay = 0
        model.adopt(try Waveform.parse(text ?? vcd()), from: nil, layout: layout)
        return model
    }

    func id(_ model: WaveformModel, _ name: String) -> Int { model.waveform!.signals.firstIndex { $0.name == name }! }

    func names(_ model: WaveformModel) -> [String] {
        model.rows.map { row in
            switch row {
            case .signal(let id): model.waveform!.signals[id].name
            case .divider(let id): "-- \(model.dividerName(id))"
            }
        }
    }

    // MARK: Markers

    func testAddMarkerAtTheCursorWithNumberedNames() throws {
        let wave = try model()
        wave.setCursor(tick: 1500)
        XCTAssertEqual(wave.addMarker()?.time, 1500)
        wave.setCursor(tick: 4000)
        XCTAssertEqual(wave.addMarker()?.name, "M2")
        wave.deleteMarker(wave.markers[0].id)
        XCTAssertEqual(wave.addMarker()?.name, "M1", "a freed name is reused")
        XCTAssertEqual(wave.markers.map(\.time), [4000, 4000])
    }

    func testWithNoCursorAMarkerGoesInTheMiddleOfTheView() throws {
        let wave = try model()
        XCTAssertEqual(wave.addMarker()?.time, UInt64((wave.viewStart + wave.span / 2).rounded()))
    }

    func testDraggingAndRenamingAndClamping() throws {
        let wave = try model()
        let marker = try XCTUnwrap(wave.addMarker())
        wave.moveMarker(marker.id, toTick: 2_499.6)
        XCTAssertEqual(wave.marker(marker.id)?.time, 2500)
        wave.moveMarker(marker.id, toTick: 1e9)
        XCTAssertEqual(wave.marker(marker.id)?.time, 10_000, "not past the end of the run")
        wave.moveMarker(marker.id, toTick: -5)
        XCTAssertEqual(wave.marker(marker.id)?.time, 0)
        wave.renameMarker(marker.id, to: "  reset released ")
        XCTAssertEqual(wave.marker(marker.id)?.name, "reset released")
        wave.renameMarker(marker.id, to: "   ")
        XCTAssertEqual(wave.marker(marker.id)?.name, "reset released", "an empty name is ignored")
    }

    func testMeasurementsFromTheNearestMarkerAndBetweenTwoPicked() throws {
        let wave = try model()
        wave.setCursor(tick: 1000)
        let a = try XCTUnwrap(wave.addMarker())
        wave.setCursor(tick: 6000)
        let b = try XCTUnwrap(wave.addMarker())
        wave.setCursor(tick: 5000)
        XCTAssertEqual(wave.nearestMarker?.id, b.id)
        XCTAssertEqual(wave.delta(from: b.time, to: 5000), "−1 µs")
        XCTAssertTrue(wave.measurements.contains("M2 → cursor −1 µs"), "\(wave.measurements)")

        wave.selectMarker(a.id)
        wave.selectMarker(b.id)
        XCTAssertTrue(wave.measurements.contains("M1 → M2 +5 µs"), "\(wave.measurements)")
        let c = try XCTUnwrap(wave.addMarker())
        wave.selectMarker(c.id)
        XCTAssertEqual(wave.selectedMarkers, [b.id, c.id], "only the last two picked count")
        XCTAssertEqual(wave.marker(near: 6_040, within: 50)?.id, b.id)
        XCTAssertNil(wave.marker(near: 7_000, within: 50))
    }

    // MARK: Dividers

    func testDividersGoAboveTheSelectedSignalAndCanBeRenamedMovedAndRemoved() throws {
        let wave = try model()
        wave.selected = id(wave, "count [7:0]")
        let divider = wave.addDivider(named: "Counter")
        XCTAssertEqual(names(wave), ["clk", "-- Counter", "count [7:0]", "done"])
        XCTAssertEqual(wave.shown.count, 3, "dividers aren't signals")
        wave.renameDivider(divider, to: "Datapath")
        wave.move(.divider(divider), by: -1)
        XCTAssertEqual(names(wave), ["-- Datapath", "clk", "count [7:0]", "done"])
        wave.move(.divider(divider), by: -1)
        XCTAssertEqual(names(wave).first, "-- Datapath", "can't move past the top")
        wave.removeDivider(divider)
        XCTAssertEqual(names(wave), ["clk", "count [7:0]", "done"])
    }

    // MARK: Layout

    func testTheLayoutIsSavedAndComesBackOnTheNextRun() async throws {
        let file = tmp.appendingPathComponent("tb.wcfg.json")
        let first = try model(layout: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "opening writes nothing")
        first.hide(id(first, "clk"))
        first.selected = id(first, "done")
        first.addDivider(named: "Status")
        first.setRadix(.decimal, for: id(first, "count [7:0]"))
        first.zoom(by: 4, anchor: 0.5)
        first.setCursor(tick: 3000)
        first.addMarker()
        try first.saveLayout()

        let next = try model(layout: file)
        XCTAssertEqual(names(next), ["count [7:0]", "-- Status", "done"])
        XCTAssertEqual(next.radix(for: id(next, "count [7:0]")), .decimal)
        XCTAssertEqual(next.viewStart, first.viewStart, accuracy: 0.001)
        XCTAssertEqual(next.viewEnd, first.viewEnd, accuracy: 0.001)
        XCTAssertEqual(next.markers.map(\.time), [3000])
        XCTAssertNil(next.layoutNote)
    }

    func testChangesSaveThemselves() async throws {
        let file = tmp.appendingPathComponent("tb.wcfg.json")
        let wave = try model(layout: file)
        wave.hide(id(wave, "done"))
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(nanoseconds: 10_000_000) }
        let saved = try WaveLayout.load(from: file)
        XCTAssertEqual(saved.rows, [.signal("tb.clk"), .signal("tb.count [7:0]")])
    }

    func testSignalsThatDisappearedAreDroppedWithANote() throws {
        let file = tmp.appendingPathComponent("tb.wcfg.json")
        let first = try model(layout: file)
        try first.saveLayout()
        let next = try model(vcd(extra: false), layout: file)
        XCTAssertEqual(names(next), ["clk", "count [7:0]"])
        XCTAssertEqual(next.layoutNote, "1 saved signal is no longer in this simulation and was dropped: tb.done")
    }

    func testAnUnreadableLayoutFallsBackToTheDefault() throws {
        let file = tmp.appendingPathComponent("tb.wcfg.json")
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        let wave = try model(layout: file)
        XCTAssertEqual(names(wave), ["clk", "count [7:0]", "done"])
        XCTAssertNotNil(wave.layoutNote)
    }

    func testOpenAndResetLayout() throws {
        let other = tmp.appendingPathComponent("other.wcfg.json")
        try WaveLayout(rows: [.signal("tb.done")], viewStart: 0, viewEnd: 500, markers: [WaveMarker(name: "X", time: 100)]).save(to: other)
        let wave = try model(layout: tmp.appendingPathComponent("tb.wcfg.json"))
        try wave.openLayout(other)
        XCTAssertEqual(names(wave), ["done"])
        XCTAssertEqual(wave.markers.map(\.name), ["X"])
        wave.resetLayout()
        XCTAssertEqual(names(wave), ["clk", "count [7:0]", "done"])
        XCTAssertTrue(wave.markers.isEmpty)
    }

    func testAWaveformOpenedWithoutATestbenchSavesNothing() async throws {
        let wave = try model()
        wave.hide(0)
        try wave.saveLayout()
        XCTAssertNil(wave.layoutURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
    }
}
