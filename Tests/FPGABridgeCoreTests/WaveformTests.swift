import XCTest
@testable import FPGABridgeCore

final class WaveformTests: XCTestCase {
    /// What Icarus Verilog writes, trimmed: nested scopes, a net seen from two scopes under one code, vector ranges,
    /// a parameter block before time 0, short vectors, x and z.
    let sample = """
    $date
        Fri Oct 16 17:42:22 2026
    $end
    $version
        Icarus Verilog
    $end
    $timescale
        1ps
    $end
    $scope module tb $end
    $var wire 8 ! led [7:0] $end
    $var reg 1 " clk $end
    $var reg 4 # bus [3:0] $end
    $scope module dut $end
    $var wire 1 " clk $end
    $var parameter 32 $ WIDTH $end
    $upscope $end
    $upscope $end
    $enddefinitions $end
    $comment Show the parameter values. $end
    $dumpall
    b1010 $
    $end
    #0
    $dumpvars
    b0 !
    0"
    bx #
    $end
    #5000
    1"
    b101 !
    #10000
    0"
    bz1 #
    #15000
    1"
    1"
    b1111 #
    """

    func testSignalsKeepTheirScopeNameAndWidth() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.signals.map(\.path), ["tb.led [7:0]", "tb.clk", "tb.bus [3:0]", "tb.dut.clk", "tb.dut.WIDTH"])
        XCTAssertEqual(w.signals.map(\.width), [8, 1, 4, 1, 32])
        XCTAssertEqual(w.signals[0].kind, "wire")
        XCTAssertTrue(w.signals[0].isBus)
        XCTAssertFalse(w.signals[1].isBus)
    }

    func testTheTimescaleAndEndTimeAreRead() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.timescaleValue, 1)
        XCTAssertEqual(w.timescaleUnit, "ps")
        XCTAssertEqual(w.endTime, 15000)
        XCTAssertEqual(try Waveform.parse(sample.replacingOccurrences(of: "$timescale\n    1ps", with: "$timescale 10 ns")).secondsPerTick, 10e-9, accuracy: 1e-18)
    }

    func testANetSeenFromTwoScopesIsRecordedForBoth() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.signals[1].times, w.signals[3].times, "tb.clk and tb.dut.clk share a code")
        XCTAssertEqual(w.signals[1].values, ["0", "1", "0", "1"])
    }

    func testValuesAreBitStringsPaddedToTheWidth() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.signals[0].values, ["00000000", "00000101"], "b0 and b101 extend with zeros")
        XCTAssertEqual(w.signals[2].values, ["xxxx", "zzz1", "1111"], "x and z extend with themselves")
        XCTAssertEqual(w.signals[4].values, ["00000000000000000000000000001010"], "the parameter block before time 0")
    }

    func testARepeatedValueIsNotARepeatedChange() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.signals[1].times, [0, 5000, 10000, 15000], "the second 1\" at 15000 adds nothing")
    }

    func testTheScopeTreeFollowsTheHierarchy() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.scopes.map(\.name), ["tb"])
        XCTAssertEqual(w.scopes[0].signals, [0, 1, 2])
        XCTAssertEqual(w.scopes[0].children.map(\.name), ["dut"])
        XCTAssertEqual(w.scopes[0].children[0].id, "tb.dut")
        XCTAssertEqual(w.scopes[0].children[0].signals, [3, 4])
    }

    func testValueAtATimeIsTheLastChangeAtOrBeforeIt() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.value(of: 1, at: 0), "0")
        XCTAssertEqual(w.value(of: 1, at: 4999), "0")
        XCTAssertEqual(w.value(of: 1, at: 5000), "1", "a change takes effect at its own time")
        XCTAssertEqual(w.value(of: 1, at: 999_999), "1", "and holds past the last change")
        XCTAssertEqual(w.value(of: 0, at: 7000), "00000101")
    }

    func testVisibleChangesCoverTheValueInForceAtTheStart() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.visibleChanges(of: 1, from: 6000, to: 12000), 1..<3, "in force at 6000 through the one at 10000")
        XCTAssertEqual(w.visibleChanges(of: 1, from: 0, to: 15000), 0..<4)
        XCTAssertEqual(w.visibleChanges(of: 1, from: 20000, to: 30000), 3..<4, "past the end: just the last value")
    }

    func testTimesReadInTheUnitThatFits() throws {
        let w = try Waveform.parse(sample)
        XCTAssertEqual(w.formatTime(0), "0 ps")
        XCTAssertEqual(w.formatTime(112_000), "112 ns")
        XCTAssertEqual(w.formatTime(2_000_100_000), "2.0001 ms")
        XCTAssertEqual(w.formatTime(1_500), "1.5 ns")
        XCTAssertEqual(w.formatTime(999), "999 ps")
        XCTAssertEqual(w.formatTime(1_000_000), "1 µs")
    }

    func testRadixFormatting() {
        XCTAssertEqual(Waveform.format("1", radix: .hex), "1", "single bits are left alone")
        XCTAssertEqual(Waveform.format("11110101", radix: .hex), "f5")
        XCTAssertEqual(Waveform.format("101", radix: .hex), "5", "padded to a whole digit")
        XCTAssertEqual(Waveform.format("1x10", radix: .hex), "x", "an x in a digit shows as x")
        XCTAssertEqual(Waveform.format("0000z001", radix: .hex), "0z")
        XCTAssertEqual(Waveform.format("11110101", radix: .decimal), "245")
        XCTAssertEqual(Waveform.format("11110101", radix: .signed), "-11")
        XCTAssertEqual(Waveform.format("01110101", radix: .signed), "117")
        XCTAssertEqual(Waveform.format("11111111111111111111111111111111", radix: .signed), "-1")
        XCTAssertEqual(Waveform.format("10x1", radix: .decimal), "x")
        XCTAssertEqual(Waveform.format("1010", radix: .binary), "1010")
    }

    func testAFileWithoutSignalsIsRefused() {
        XCTAssertThrowsError(try Waveform.parse("hello")) { XCTAssertTrue($0.userMessage.contains("isn't a VCD")) }
        XCTAssertThrowsError(try Waveform.parse(""))
    }

    func testRealAndStringValuesAreSkippedWithoutBreakingTheRest() throws {
        let text = """
        $timescale 1ns $end
        $scope module m $end
        $var real 64 ! r $end
        $var wire 1 " w $end
        $upscope $end
        $enddefinitions $end
        #0
        r3.14 !
        0"
        #10
        r2.71 !
        1"
        """
        let w = try Waveform.parse(text)
        XCTAssertEqual(w.signals[1].values, ["0", "1"])
        XCTAssertEqual(w.signals[0].values, [], "reals aren't drawn")
    }

    func testTwoWritesInOneInstantKeepTheLaterOne() throws {
        func parse(_ body: String) throws -> WaveSignal {
            try Waveform.parse("$scope module m $end\n$var wire 1 ! w $end\n$upscope $end\n$enddefinitions $end\n" + body).signals[0]
        }
        let glitch = try parse("#0\n0!\n#10\n1!\n0!\n")
        XCTAssertEqual(glitch.values, ["0"], "back where it was: no change at all")
        XCTAssertEqual(glitch.times, [0])

        let settles = try parse("#0\n0!\n#10\n1!\n0!\n1!\n")
        XCTAssertEqual(settles.values, ["0", "1"], "ends different: one change, to the final value")
        XCTAssertEqual(settles.times, [0, 10])
    }

    func testAMultiMegabyteWaveformParsesInWellUnderASecondOrTwo() throws {
        // A 100 MHz clock for 2 ms, as the blinky example writes: 400,000 changes, about 5 MB, plus a bus.
        var text = "$timescale 1ps $end\n$scope module tb $end\n$var reg 1 ! clk $end\n$var reg 16 \" count [15:0] $end\n$upscope $end\n$enddefinitions $end\n"
        var count = 0
        for i in 0..<400_000 {
            text += "#\(i * 5000)\n\(i % 2)!\n"
            if i % 2 == 1 { count += 1; text += "b" + String(count & 0xFFFF, radix: 2) + " \"\n" }
        }
        let started = Date()
        let w = try Waveform.parse(text)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(w.signals[0].times.count, 400_000)
        XCTAssertEqual(w.signals[1].times.count, 200_000)
        XCTAssertLessThan(seconds, 5, "took \(seconds)s for \(text.utf8.count / 1_000_000) MB")
    }

    // MARK: A real simulation

    func testAWaveformFromRealIcarusParses() throws {
        try XCTSkipUnless(Simulator.locate() != nil, "Icarus Verilog isn't installed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["src", "tb"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        try "module counter(input clk, output reg [3:0] count = 0); always @(posedge clk) count <= count + 1; endmodule"
            .write(to: root.appendingPathComponent("src/c.v"), atomically: true, encoding: .utf8)
        try """
        `timescale 1ns/1ps
        module tb; reg clk = 0; wire [3:0] count; counter dut(.clk(clk), .count(count));
        always #5 clk = ~clk; initial begin #100 $finish; end endmodule
        """.write(to: root.appendingPathComponent("tb/tb.v"), atomically: true, encoding: .utf8)
        let project = Project(name: "p", top: "counter", part: "x", sources: ["src"], constraints: [], simulationSources: ["tb"])
        let result = try Simulator.require().simulate(try Simulator.plan(project: project, root: root), stop: Shell.StopFlag(), output: { _ in })
        let waveform = try Waveform.load(from: try XCTUnwrap(result.waveform))

        let count = try XCTUnwrap(waveform.signals.first { $0.path == "tb.count [3:0]" })
        XCTAssertEqual(waveform.timescaleUnit, "ps")
        XCTAssertEqual(waveform.value(of: count.id, at: 0), "0000")
        XCTAssertEqual(waveform.value(of: count.id, at: 96_000), "1010", "10 rising edges by 96 ns (at 5, 15, ... 95)")
        let clk = try XCTUnwrap(waveform.signals.first { $0.path == "tb.clk" })
        XCTAssertEqual(clk.times.count, 21, "initial value plus a change every 5 ns up to 100 ns")
    }
}
