import XCTest
@testable import FPGABridgeCore

final class WaveLayoutTests: XCTestCase {
    let vcd = """
    $timescale 1ns $end
    $scope module tb $end
    $var reg 1 ! clk $end
    $var reg 8 " count [7:0] $end
    $upscope $end
    $enddefinitions $end
    #0
    0!
    b0 "
    #10
    1!
    """

    func testRoundTripsThroughJSON() throws {
        let layout = WaveLayout(rows: [.divider("Clocks"), .signal("tb.clk"), .signal("tb.count [7:0]")],
                                radixes: ["tb.count [7:0]": WaveRadix.decimal.rawValue], defaultRadix: .binary,
                                viewStart: 2, viewEnd: 8, markers: [WaveMarker(name: "M1", time: 5)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString).wcfg.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try layout.save(to: url)
        XCTAssertEqual(try WaveLayout.load(from: url), layout)
    }

    func testResolvesPathsAndDropsSignalsThatAreGone() throws {
        let waveform = try Waveform.parse(vcd)
        let layout = WaveLayout(rows: [.signal("tb.count [7:0]"), .divider("Old"), .signal("tb.gone"), .signal("tb.clk")],
                                radixes: ["tb.count [7:0]": "Signed Decimal", "tb.gone": "Binary"], viewStart: 0, viewEnd: 10)
        let resolved = layout.resolve(in: waveform)
        let count = try XCTUnwrap(waveform.signals.firstIndex { $0.name == "count [7:0]" })
        let clk = try XCTUnwrap(waveform.signals.firstIndex { $0.name == "clk" })
        XCTAssertEqual(resolved.rows, [.signal(count), .divider("Old"), .signal(clk)])
        XCTAssertEqual(resolved.radixes, [count: .signed])
        XCTAssertEqual(resolved.missing, ["tb.gone"])
    }

    func testTheFileGoesNextToTheWaveformNamedForTheTestbench() {
        let vcd = URL(fileURLWithPath: "/p/blinky.sim/sim_1/behav/sim.vcd")
        XCTAssertEqual(WaveLayout.url(testbench: "blinky_tb", nextTo: vcd).path, "/p/blinky.sim/sim_1/behav/blinky_tb.wcfg.json")
    }
}
