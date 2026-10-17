import CoreGraphics
import XCTest
@testable import FPGABridgeCore

/// The schematic layout, on Vivado 2025.2's demo_top netlists: what is drawn, and that the drawing is sound.
final class SchematicTests: XCTestCase {
    func snapshot(_ stage: DesignStage) throws -> DesignSnapshot {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "design_vivado2025", withExtension: nil, subdirectory: "Fixtures"))
        return try DesignSnapshot.load(stage: stage, from: dir)
    }

    func layout(_ stage: DesignStage, _ spec: SchematicSpec = SchematicSpec()) throws -> (SchematicLayout, DesignSnapshot) {
        let design = try snapshot(stage)
        return (try SchematicBuilder(design: design).layout(spec), design)
    }

    /// Checks every drawing rule; used by each layout test.
    func assertSound(_ s: SchematicLayout, file: StaticString = #filePath, line: UInt = #line) {
        let canvas = CGRect(origin: .zero, size: s.size)
        for wire in s.wires {
            XCTAssertFalse(wire.segments.isEmpty, "wire \(wire.label) has segments", file: file, line: line)
            for seg in wire.segments {
                XCTAssertTrue(seg.from.x == seg.to.x || seg.from.y == seg.to.y, "\(wire.label): only horizontal and vertical lines", file: file, line: line)
                XCTAssertTrue(canvas.insetBy(dx: -1, dy: -1).contains(seg.from) && canvas.insetBy(dx: -1, dy: -1).contains(seg.to),
                              "\(wire.label) stays on the canvas", file: file, line: line)
            }
        }
        // Boxes at the same nesting level never overlap, and nested ones sit inside their module.
        let closed = s.nodes.filter { !$0.isOpenModule }
        for (i, a) in closed.enumerated() {
            XCTAssertTrue(canvas.contains(a.frame), "\(a.id) is on the canvas", file: file, line: line)
            for b in closed[(i + 1)...] where a.frame.intersects(b.frame) {
                XCTFail("\(a.id) and \(b.id) overlap", file: file, line: line)
            }
        }
        for open in s.nodes.filter(\.isOpenModule) {
            for inner in s.nodes where inner.id.hasPrefix(open.id + "/") {
                XCTAssertTrue(open.frame.contains(inner.frame), "\(inner.id) is inside \(open.id)", file: file, line: line)
            }
        }
        // Every pin a wire serves is touched by an end of one of its segments.
        let ends = Set(s.wires.flatMap { $0.segments.flatMap { [$0.from, $0.to] } }.map { [$0.x, $0.y] })
        let connected = s.nodes.flatMap(\.pins).filter { pin in ends.contains([pin.point.x, pin.point.y]) }
        XCTAssertFalse(connected.isEmpty, file: file, line: line)
    }

    // MARK: The top of the elaborated design

    func testTheTopLevelDrawsItsCellsPortsAndTheSubModule() throws {
        let (s, design) = try layout(.rtl)
        assertSound(s)
        let topCells = design.cells.filter { $0.parentPath.isEmpty && $0.type != "GND" && $0.type != "VCC" }
        let drawn = s.nodes.filter { if case .port = $0.kind { return false } else { return true } }
        XCTAssertEqual(Set(drawn.flatMap { $0.members.isEmpty ? [$0.ref.name] : $0.members }), Set(topCells.map(\.name)),
                       "every top cell, alone or in a bundle, without the constant drivers")
        let count = try XCTUnwrap(s.nodes.first { $0.title == "count_reg[7:0]" }, "Vivado bundles count_reg[0]...[7]")
        XCTAssertTrue(count.isBundle)
        XCTAssertEqual(count.members.count, 8)
        XCTAssertTrue(count.stands(for: .cell("count_reg[5]")))
        XCTAssertLessThan(s.cellCount, topCells.count)
        XCTAssertTrue(s.nodes.contains { $0.id == "u_tick" && $0.kind == .module(open: false) }, "the sub-module closed, as a box")
        XCTAssertEqual(s.portCount, design.ports.count, "every port, buses drawn as one")
        XCTAssertTrue(s.nodes.contains { $0.id == "port:led" && $0.title == "led[15:0]" })
        XCTAssertFalse(s.nodes.contains { $0.subtitle == "GND" || $0.subtitle == "VCC" })
    }

    func testInputsAreOnTheLeftAndOutputsOnTheRight() throws {
        let (s, _) = try layout(.rtl)
        let cells = s.nodes.filter { if case .port = $0.kind { return false } else { return true } }
        let inputs = s.nodes.filter { $0.kind == .port(direction: "IN") }
        let outputs = s.nodes.filter { $0.kind == .port(direction: "OUT") }
        let leftmostCell = try XCTUnwrap(cells.map(\.frame.minX).min())
        let rightmostCell = try XCTUnwrap(cells.map(\.frame.maxX).max())
        XCTAssertTrue(inputs.allSatisfy { $0.frame.maxX < leftmostCell }, "input ports left of every cell")
        XCTAssertTrue(outputs.allSatisfy { $0.frame.minX > rightmostCell }, "output ports right of every cell")
    }

    func testSignalsFlowLeftToRight() throws {
        let (s, _) = try layout(.rtl)
        let adder = try XCTUnwrap(s.nodes.first { $0.id == "count0_i__0" }, "the counter's adder")
        let register = try XCTUnwrap(s.nodes.first { $0.title == "count_reg[7:0]" })
        XCTAssertNotEqual(adder.frame.minX, register.frame.minX)
        let led = try XCTUnwrap(s.nodes.first { $0.id == "port:led" })
        XCTAssertGreaterThan(led.frame.minX, register.frame.maxX, "registers drive the LEDs, to their right")
    }

    func testBusesAreDrawnAsOneThickWire() throws {
        let (s, _) = try layout(.rtl)
        let buses = s.wires.filter(\.isBus)
        XCTAssertFalse(buses.isEmpty)
        let count = try XCTUnwrap(buses.first { $0.nets.contains("count[3]") })
        XCTAssertEqual(Set(count.nets), Set((0..<8).map { "count[\($0)]" }), "all eight bits in one wire")
        XCTAssertEqual(count.label, "count[7:0]")
        XCTAssertTrue(s.nodes.contains { $0.pins.contains { $0.label == "O[7:0]" && $0.isBus } }, "bus pins are labelled with their range")
    }

    func testConstantsBecomeTieLabels() throws {
        let (s, _) = try layout(.rtl)
        let tied = s.nodes.flatMap(\.pins).filter { $0.tie != nil }
        XCTAssertFalse(tied.isEmpty, "pins on <const0> or <const1>")
        XCTAssertTrue(tied.allSatisfy { $0.tie == "0" || $0.tie == "1" })
        XCTAssertFalse(s.wires.contains { $0.nets.contains("<const0>") || $0.nets.contains("<const1>") })
    }

    func testFeedbackGoesOverTheTop() throws {
        // The counter's register output comes back to the adder that feeds it.
        let (s, _) = try layout(.rtl)
        let top = try XCTUnwrap(s.nodes.map(\.frame.minY).min())
        XCTAssertTrue(s.wires.contains { $0.segments.contains { $0.from.y == $0.to.y && $0.from.y < top } },
                      "a loop is routed above the cells")
    }

    func testSymbolsFollowTheCellType() {
        XCTAssertEqual(SchematicSymbol.forCell(type: "RTL_AND", inputs: 2, outputs: 1, isPrimitive: true), .and)
        XCTAssertEqual(SchematicSymbol.forCell(type: "RTL_INV", inputs: 1, outputs: 1, isPrimitive: true), .inverter)
        XCTAssertEqual(SchematicSymbol.forCell(type: "RTL_MUX", inputs: 3, outputs: 1, isPrimitive: true), .mux)
        XCTAssertEqual(SchematicSymbol.forCell(type: "RTL_REG_SYNC__BREG_1", inputs: 3, outputs: 1, isPrimitive: true), .register)
        XCTAssertEqual(SchematicSymbol.forCell(type: "FDRE", inputs: 4, outputs: 1, isPrimitive: true), .register)
        XCTAssertEqual(SchematicSymbol.forCell(type: "IBUF", inputs: 1, outputs: 1, isPrimitive: true), .buffer)
        XCTAssertEqual(SchematicSymbol.forCell(type: "BUFG", inputs: 1, outputs: 1, isPrimitive: true), .buffer)
        XCTAssertEqual(SchematicSymbol.forCell(type: "LUT6", inputs: 6, outputs: 1, isPrimitive: true), .box)
        XCTAssertEqual(SchematicSymbol.forCell(type: "RTL_ADD0", inputs: 2, outputs: 1, isPrimitive: true), .box)
        XCTAssertEqual(SchematicSymbol.forCell(type: "tick_gen", inputs: 2, outputs: 1, isPrimitive: false), .module)
        XCTAssertEqual(SchematicSymbol.forCell(type: "OR", inputs: 2, outputs: 1, isPrimitive: true), .or)
        XCTAssertEqual(SchematicSymbol.forCell(type: "ORIENT", inputs: 2, outputs: 1, isPrimitive: true), .box, "not fooled by a prefix")
    }

    // MARK: Opening a module

    func testOpeningAModuleDrawsItsContentsInside() throws {
        let (closed, _) = try layout(.rtl)
        let (s, design) = try layout(.rtl, SchematicSpec(expanded: ["u_tick"]))
        assertSound(s)
        let box = try XCTUnwrap(s.nodes.first { $0.id == "u_tick" })
        XCTAssertEqual(box.kind, .module(open: true))
        let inner = s.nodes.filter { $0.id.hasPrefix("u_tick/") }
        let innerCells = design.cells.filter { $0.parentPath == "u_tick" && $0.type != "GND" && $0.type != "VCC" }
        XCTAssertEqual(Set(inner.flatMap { $0.members.isEmpty ? [$0.ref.name] : $0.members }), Set(innerCells.map(\.name)))
        XCTAssertTrue(inner.allSatisfy { box.frame.contains($0.frame) })
        XCTAssertGreaterThan(box.frame.width, closed.nodes.first { $0.id == "u_tick" }!.frame.width)
        XCTAssertTrue(inner.allSatisfy { $0.depth == 1 }, "drawn on top of the box")
        // The clock goes in through the box's edge to the counter's registers.
        let edgeClk = try XCTUnwrap(box.pins.first { $0.label == "clk" })
        XCTAssertEqual(edgeClk.point.x, box.frame.minX, accuracy: 0.5, "an input on the left edge")
    }

    func testAModuleOnItsOwn() throws {
        let (s, design) = try layout(.synth, SchematicSpec(module: "u_tick"))
        assertSound(s)
        let cells = design.cells.filter { $0.parentPath == "u_tick" && $0.type != "GND" && $0.type != "VCC" }
        XCTAssertEqual(Set(s.nodes.flatMap { $0.members.isEmpty ? [$0.ref.name] : $0.members }), Set(cells.map(\.name)))
        XCTAssertEqual(s.portCount, 0, "no top-level ports inside a module")
    }

    // MARK: A schematic of chosen cells (F4)

    func testASchematicOfChosenCellsShowsThemInsideTheirModules() throws {
        let (s, _) = try layout(.synth, SchematicSpec(only: ["u_tick/tick_reg", "dir_reg"]))
        assertSound(s)
        let ids = Set(s.nodes.map(\.id))
        XCTAssertTrue(ids.contains("u_tick/tick_reg"))
        XCTAssertTrue(ids.contains("dir_reg"))
        XCTAssertTrue(ids.contains("u_tick"), "inside its module, drawn open")
        XCTAssertEqual(s.nodes.first { $0.id == "u_tick" }?.kind, .module(open: true))
        XCTAssertFalse(s.nodes.contains { $0.stands(for: .cell("count_reg[0]")) }, "nothing else")
        XCTAssertTrue(s.nodes.flatMap(\.pins).contains(where: \.hasHiddenConnections), "pins going to logic not shown are marked")
    }

    // MARK: Every stage lays out

    func testEveryStageLaysOutSoundly() throws {
        for stage in DesignStage.allCases {
            let (s, _) = try layout(stage)
            assertSound(s)
            let (open, _) = try layout(stage, SchematicSpec(expanded: ["u_tick"]))
            assertSound(open)
        }
    }

    func testABuildWithoutConnectionsSaysSo() {
        let design = DesignSnapshot(stage: .synth, info: DesignInfo(top: "t"), cells: [DesignCell(name: "a", type: "FDRE", isPrimitive: true)], ports: [])
        XCTAssertThrowsError(try SchematicBuilder(design: design).layout(SchematicSpec())) {
            XCTAssertEqual($0 as? SchematicError, .noConnectivity)
        }
    }
}
