import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// The selection the Netlist, Properties (and later Schematic) windows share, and Go To Source.
@MainActor
final class DesignSelectionAppTests: ExampleSandboxTestCase {
    func until(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// A model with an example project and a built design at each stage, whose one cell comes from `file` line 3.
    func makeModel(file: String? = nil) async throws -> AppModel {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        let source = file ?? model.sourceTree.first?.children?.first?.path
        func snapshot(_ stage: DesignStage) -> DesignSnapshot {
            DesignSnapshot(stage: stage, info: DesignInfo(stage: stage.rawValue, top: "top"),
                           cells: [DesignCell(name: "u/ff", type: "FDRE", isPrimitive: true, sourceFile: source, sourceLine: 3),
                                   DesignCell(name: "u", type: "sub", isPrimitive: false)],
                           ports: [DesignPort(name: "led", direction: "OUT", packagePin: "U16", ioStandard: "LVCMOS33", slew: "", drive: "", pullType: "")],
                           pins: [DesignPin(name: "u/ff/Q", direction: "OUT")],
                           nets: [DesignNet(name: "u/q", type: "SIGNAL", endpoints: [NetEndpoint(name: "u/ff/Q", isPort: false)])])
        }
        backend.outcome.designs = [.rtl: snapshot(.rtl), .synth: snapshot(.synth)]
        model.run(.synthesis)
        try await until("the build") { !model.isRunning && model.designs[.synth] != nil }
        return model
    }

    // MARK: The open design

    func testOpeningADesignShowsItsNetlistAndClosingItGoesBackToSources() async throws {
        let model = try await makeModel()
        XCTAssertNil(model.activeDesign)
        XCTAssertEqual(model.sidePane, .sources)

        model.perform(.openSynthesizedDesign)
        XCTAssertEqual(model.activeDesign, .synth)
        XCTAssertEqual(model.sidePane, .netlist, "Vivado shows the Netlist window once a design is open")
        XCTAssertNotNil(model.activeSnapshot)

        model.perform(.openElaboratedDesign)
        XCTAssertEqual(model.activeDesign, .rtl, "the last one opened is active")
        model.close(.design(.rtl))
        XCTAssertEqual(model.activeDesign, .synth, "back to the other open design")
        model.close(.design(.synth))
        XCTAssertNil(model.activeDesign)
        XCTAssertEqual(model.sidePane, .sources)
        XCTAssertFalse(model.propertiesShowsDesign)
    }

    func testSwitchingDesignsClearsASelectionThatBelongedToTheOther() async throws {
        let model = try await makeModel()
        model.perform(.openSynthesizedDesign)
        model.select(.cell("u/ff"))
        model.perform(.openElaboratedDesign)
        XCTAssertEqual(model.designSelection, [])
        model.select(.net("u/q"))
        model.open(.design(.rtl))
        XCTAssertEqual(model.designSelection, [.net("u/q")], "reopening the same design keeps it")
    }

    // MARK: Selecting

    func testSelectingReplacesExtendingAddsOrRemoves() async throws {
        let model = try await makeModel()
        model.perform(.openSynthesizedDesign)
        model.propertiesShowsDesign = false
        model.select(.cell("u/ff"))
        XCTAssertEqual(model.designSelection, [.cell("u/ff")])
        XCTAssertTrue(model.propertiesShowsDesign, "Properties follows the newest selection")
        model.select(.port("led"), extend: true)
        XCTAssertEqual(model.designSelection, [.cell("u/ff"), .port("led")])
        XCTAssertEqual(model.primarySelection, .port("led"), "Properties shows the most recently selected")
        model.select(.cell("u/ff"), extend: true)
        XCTAssertEqual(model.designSelection, [.port("led")], "⌘-click again takes it out")
        model.select(nil)
        XCTAssertEqual(model.designSelection, [])
    }

    func testANewBuildForgetsTheSelection() async throws {
        let model = try await makeModel()
        model.perform(.openSynthesizedDesign)
        model.select(.cell("u/ff"))
        model.resetRuns()
        XCTAssertEqual(model.designSelection, [])
    }

    // MARK: Go To Source

    func testGoToSourceOpensTheFileAtTheLine() async throws {
        let model = try await makeModel()
        let cell = try XCTUnwrap(model.designs[.synth]?.cell(named: "u/ff"))
        let path = try XCTUnwrap(cell.sourceFile)
        XCTAssertTrue(model.canGoToSource(cell))

        model.goToSource(cell)
        XCTAssertEqual(model.selectedTab, .file(path))
        let text = model.editedText(for: path) as NSString
        let reveal = try XCTUnwrap(model.editorReveal[path])
        let lines = (text as String).components(separatedBy: "\n")
        XCTAssertEqual(text.substring(with: reveal.range), lines[2], "line 3, without its line break")
        XCTAssertEqual(model.caret(in: path), reveal.range.location)

        model.goToSource(cell)
        XCTAssertEqual(model.editorReveal[path]?.token, reveal.token + 1, "asking again moves the editor again")
    }

    func testACellFromAFileThatIsGoneCantGoToSource() async throws {
        let model = try await makeModel(file: "src/deleted.v")
        let cell = try XCTUnwrap(model.designs[.synth]?.cell(named: "u/ff"))
        XCTAssertFalse(model.canGoToSource(cell))
        model.goToSource(cell)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotEqual(model.selectedTab, .file("src/deleted.v"))
        XCTAssertFalse(model.canGoToSource(DesignCell(name: "x", type: "GND", isPrimitive: true)), "no source line")
    }

    func testLineRanges() {
        let text = "one\ntwo\r\nthree" as NSString
        XCTAssertEqual(text.substring(with: AppModel.range(ofLine: 1, in: text)), "one")
        XCTAssertEqual(text.substring(with: AppModel.range(ofLine: 2, in: text)), "two", "CR LF is not part of the line")
        XCTAssertEqual(text.substring(with: AppModel.range(ofLine: 3, in: text)), "three")
        XCTAssertEqual(text.substring(with: AppModel.range(ofLine: 99, in: text)), "three", "past the end: the last line")
        XCTAssertEqual(AppModel.range(ofLine: 1, in: ""), NSRange(location: 0, length: 0))
    }

    // MARK: Schematic

    func testTheElaboratedDesignOpensOnASchematicOfTheTop() async throws {
        let model = try await makeModel()
        model.perform(.openElaboratedDesign)
        XCTAssertEqual(model.selectedTab, .schematic(.rtl), "as Vivado does")
        XCTAssertTrue(model.openTabs.contains(.design(.rtl)))
        XCTAssertEqual(model.schematicSpecs[.rtl], SchematicSpec())
        model.perform(.openSynthesizedDesign)
        XCTAssertEqual(model.selectedTab, .design(.synth), "the synthesized design doesn't")
    }

    func testF4DrawsTheSelectionAndPreviousGoesBack() async throws {
        let model = try await makeModel()
        model.perform(.openSynthesizedDesign)
        model.schematicOfSelection()
        XCTAssertEqual(model.schematicSpecs[.synth], SchematicSpec(), "nothing selected: the top level")
        XCTAssertEqual(model.selectedTab, .schematic(.synth))

        model.select(.net("u/q"))
        model.schematicOfSelection()
        XCTAssertEqual(model.schematicSpecs[.synth]?.only, ["u/ff"], "a net draws the cells it connects")
        model.select(.pin("u/ff/Q"))
        XCTAssertEqual(model.cellsForSchematic(of: model.designSelection, in: try XCTUnwrap(model.designs[.synth])), ["u/ff"])

        model.schematicBack(.synth)
        XCTAssertEqual(model.schematicSpecs[.synth], SchematicSpec())
        model.schematicForward(.synth)
        XCTAssertEqual(model.schematicSpecs[.synth]?.only, ["u/ff"])
    }

    func testExpandingAModuleInPlaceAndCollapsingIt() async throws {
        let model = try await makeModel()
        model.perform(.openSynthesizedDesign)
        model.openSchematic()
        model.toggleInSchematic("u", stage: .synth)
        XCTAssertEqual(model.schematicSpecs[.synth]?.expanded, ["u"])
        model.toggleInSchematic("u", stage: .synth)
        XCTAssertEqual(model.schematicSpecs[.synth]?.expanded, [])
        model.schematicBack(.synth)
        XCTAssertEqual(model.schematicSpecs[.synth]?.expanded, ["u"], "each step can be undone with Previous")
    }

    func testClosingADesignClosesItsSchematic() async throws {
        let model = try await makeModel()
        model.perform(.openElaboratedDesign)
        XCTAssertTrue(model.openTabs.contains(.schematic(.rtl)))
        model.close(.design(.rtl))
        XCTAssertFalse(model.openTabs.contains(.schematic(.rtl)))
        XCTAssertNil(model.activeDesign)
        XCTAssertEqual(model.title(of: .schematic(.synth)), "Schematic")
    }
}
