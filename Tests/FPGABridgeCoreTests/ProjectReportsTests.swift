import XCTest
@testable import FPGABridgeCore

/// The reports behind the Project Summary and Design Runs, read from what Vivado 2025.2 wrote for demo_top.
final class ProjectReportsTests: XCTestCase {
    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rpt", subdirectory: "Fixtures"), name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPower() throws {
        let power = try XCTUnwrap(PowerSummary.parse(try fixture("power_vivado2025")))
        XCTAssertEqual(power.totalOnChip, 0.081)
        XCTAssertEqual(power.dynamic, 0.010)
        XCTAssertEqual(power.deviceStatic, 0.072)
        XCTAssertEqual(power.effectiveThetaJA, 5.0)
        XCTAssertEqual(power.junctionTemperature, 25.4)
        XCTAssertEqual(power.confidence, "Low")
        XCTAssertEqual(power.ambient, 25.0)
        let margin = try XCTUnwrap(power.thermalMargin)
        XCTAssertEqual(margin.celsius, 59.6, accuracy: 0.001, "Max Ambient 84.6 °C less 25 °C ambient")
        XCTAssertEqual(margin.watts, 11.92, accuracy: 0.001)
        XCTAssertEqual(power.components.first, PowerSummary.Component(name: "Clocks", watts: "<0.001", isPart: false))
        XCTAssertTrue(power.components.contains(PowerSummary.Component(name: "LUT as Logic", watts: "<0.001", isPart: true)))
        XCTAssertEqual(power.components.first { $0.name == "I/O" }?.watts, "0.009")
        XCTAssertNil(PowerSummary.parse("nothing here"))
        let lf = try fixture("power_vivado2025").replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(PowerSummary.parse(lf), power, "the same with plain line endings (Vivado writes this one with CR LF)")
    }

    func testDRCWithNothingFound() throws {
        let drc = try XCTUnwrap(CheckSummary.parse(try fixture("drc_vivado2025")))
        XCTAssertEqual(drc.rules, [])
        XCTAssertEqual(drc.total, 0)
    }

    func testMethodologyFindings() throws {
        let m = try XCTUnwrap(CheckSummary.parse(try fixture("methodology_vivado2025")))
        XCTAssertEqual(m.rules, [CheckSummary.Rule(rule: "TIMING-18", severity: "Warning", description: "Missing input or output delay", checks: 33)])
        XCTAssertEqual(m.count("warning"), 33)
        XCTAssertEqual(m.count("Critical Warning"), 0)
    }

    func testRouteStatus() throws {
        let r = try XCTUnwrap(RouteStatus.parse(try fixture("route_status_vivado2025")))
        XCTAssertEqual(r, RouteStatus(logicalNets: 156, routableNets: 85, fullyRouted: 85, routingErrors: 0))
        XCTAssertEqual(r.failedRoutes, 0)
        XCTAssertEqual(RouteStatus(logicalNets: 10, routableNets: 8, fullyRouted: 6, routingErrors: 1).failedRoutes, 3)
    }

    func testPulseWidthFromTheTimingSummary() throws {
        let t = try TimingSummary.parse(try fixture("timing_vivado2025"))
        XCTAssertNotNil(t.wpws)
        XCTAssertNotNil(t.tpwsTotalEndpoints)
        XCTAssertEqual(t.tpws, 0)
    }
}
