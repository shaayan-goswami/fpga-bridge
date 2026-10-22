import XCTest
@testable import FPGABridgeCore

/// The rule checks against the real xc7a35tcpg236-1 data (see PartDataTests).
final class PinRulesTests: XCTestCase {
    var part: PartData!

    override func setUpWithError() throws { part = try PartDataTests.basys3() }

    func port(_ name: String, _ direction: String = "OUT", _ pin: String, _ standard: String = "LVCMOS33", clock: Bool = false) -> PlannedPort {
        PlannedPort(name: name, direction: direction, pin: pin, standard: standard, isClock: clock)
    }

    func errors(_ ports: [PlannedPort]) -> [PinIssue] { PinRules.check(ports, part: part).filter { $0.severity == .error } }

    func testTheBasys3DemoIsClean() {
        let ports = [port("clk", "IN", "W5", clock: true), port("btnC", "IN", "U18"), port("led[0]", "OUT", "U16"), port("led[15]", "OUT", "L1"),
                     port("sw[0]", "IN", "V17"), port("sw[8]", "IN", "V2")]
        XCTAssertEqual(PinRules.check(ports, part: part), [])
    }

    func testAnUnplacedPortIsAWarning() {
        let issues = PinRules.check([port("led[1]", "OUT", "")], part: part)
        XCTAssertEqual(issues.map(\.rule), ["UCIO-1"])
        XCTAssertEqual(issues.first?.severity, .warning)
    }

    func testOnlyUserIOPinsTakePorts() {
        XCTAssertEqual(errors([port("a", "OUT", "Z99")]).map(\.rule), ["PIN"])
        let ground = errors([port("a", "OUT", "A1")])
        XCTAssertEqual(ground.count, 1)
        XCTAssertTrue(ground[0].message.contains("ground"), ground[0].message)
        XCTAssertTrue(errors([port("a", "IN", "A12")]).first?.message.contains("analog") == true, "VP_0 is the XADC's")
    }

    func testOnePortPerPin() {
        let issues = errors([port("a", "OUT", "U16"), port("b", "OUT", "u16")])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].ports, ["a", "b"])
    }

    func testOneVCCOPerBank() {
        let issues = errors([port("led[9]", "OUT", "V3"), port("x", "OUT", "W3", "LVCMOS18")])
        XCTAssertEqual(issues.map(\.rule), ["BIVC-1"])
        XCTAssertTrue(issues[0].message.contains("Bank 34"), issues[0].message)
        XCTAssertTrue(issues[0].message.contains("1.8 V (x)") && issues[0].message.contains("3.3 V (led[9])"), issues[0].message)
        XCTAssertEqual(errors([port("led[9]", "OUT", "V3"), port("x", "OUT", "U16", "LVCMOS18")]), [], "different banks")
    }

    func testDifferentialInputsLiveWithAnyVCCO() {
        let ports = [port("clk_p", "IN", "W5", "LVDS_25"), port("clk_n", "IN", "W4", "LVDS_25"), port("led", "OUT", "V3")]
        XCTAssertEqual(errors(ports), [], "an LVDS input doesn't need a 2.5 V bank")
        XCTAssertEqual(errors([port("tx_p", "OUT", "W5", "LVDS_25"), port("led", "OUT", "V3")]).map(\.rule), ["BIVC-1"], "an LVDS output does")
    }

    func testDifferentialPairsGoOnPAndN() {
        XCTAssertEqual(errors([port("clk_p", "IN", "W4", "LVDS_25")]).map(\.rule), ["DIFF"], "W4 is the N side")
        XCTAssertEqual(errors([port("clk_p", "IN", "W5", "LVDS_25"), port("clk_n", "IN", "V2", "LVDS_25")]).map(\.rule), ["DIFF"],
                       "the N port goes on W5's partner")
        XCTAssertEqual(errors([port("clk_p", "IN", "W5", "LVDS_25"), port("other", "IN", "W4")]).map(\.rule), ["DIFF"],
                       "the pair's other half can't take a single-ended port")
        XCTAssertEqual(errors([port("d", "IN", "D17", "LVDS_25")]).map(\.rule), ["IOSTDTYPE-1"], "D17 has no partner")
    }

    func testOneVREFPerBank() {
        let issues = PinRules.check([port("a", "IN", "V2", "SSTL15"), port("b", "IN", "W2", "HSTL_I_18")], part: part)
        XCTAssertEqual(issues.filter { $0.severity == .error }.map(\.rule), ["VREF"])
        let onVREF = PinRules.check([port("a", "IN", "V2", "SSTL15"), port("b", "IN", "W3", "SSTL15")], part: part)
        XCTAssertEqual(onVREF.map(\.rule), ["VREF"], "W3 is bank 34's VREF pin")
        XCTAssertEqual(onVREF.first?.severity, .warning)
    }

    func testStandardsMustSuitTheDirection() {
        XCTAssertEqual(errors([port("a", "INOUT", "V2", "HSTL_I")]).map(\.rule), ["IOSTD"], "HSTL_I has no BIDIR")
        XCTAssertEqual(errors([port("a", "OUT", "V2", "MADE_UP")]).map(\.rule), ["IOSTD"])
    }

    func testAClockOffAClockCapablePinIsAWarning() {
        let issues = PinRules.check([port("clk", "IN", "U16", clock: true)], part: part)
        XCTAssertEqual(issues.map(\.rule), ["CLK"])
        XCTAssertEqual(issues.first?.severity, .warning)
    }

    func testPlacementRefusesOnlyItsOwnErrors() {
        let others = [port("led[9]", "OUT", "V3"), port("led[10]", "OUT", "W3")]
        XCTAssertNil(PinRules.placementProblem(port: port("led[0]", "OUT", ""), pin: "U3", others: others, part: part))
        XCTAssertNotNil(PinRules.placementProblem(port: port("led[0]", "OUT", ""), pin: "A1", others: others, part: part))
        XCTAssertNotNil(PinRules.placementProblem(port: port("led[0]", "OUT", ""), pin: "V3", others: others, part: part), "taken")
        let voltage = PinRules.placementProblem(port: port("x", "OUT", "", "LVCMOS18"), pin: "U3", others: others, part: part)
        XCTAssertTrue(voltage?.contains("Bank 34") == true, voltage ?? "nil")
        XCTAssertNil(PinRules.placementProblem(port: port("clk", "IN", "", clock: true), pin: "U3", others: others, part: part),
                     "a warning doesn't stop it")
        let broken = others + [port("y", "OUT", "U2", "LVCMOS18")]
        XCTAssertNil(PinRules.placementProblem(port: port("z", "OUT", ""), pin: "U16", others: broken, part: part),
                     "an existing problem elsewhere doesn't block an unrelated move")
    }

    func testDifferentialSides() {
        XCTAssertEqual(PinRules.differentialSide(of: "clk_p"), .positive)
        XCTAssertEqual(PinRules.differentialSide(of: "RX_N[3]"), .negative)
        XCTAssertEqual(PinRules.differentialSide(of: "clkin"), .unknown)
        XCTAssertEqual(PinRules.partner(of: "rx_n[3]", in: [port("rx_p[3]", "IN", "")]), "rx_p[3]")
    }
}
