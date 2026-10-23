import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// Part data that never touches the build machine or the real cache: whatever the test gives it.
final class FixedPartDataBackend: PartDataBackend, @unchecked Sendable {
    let isDemo = false
    let canFetch: Bool
    var stored: PartData?
    var fetched = 0

    init(_ data: PartData?, canFetch: Bool = true) {
        stored = data
        self.canFetch = canFetch
    }

    func cached(part: String) -> PartData? { stored }
    func fetch(part: String) async throws -> PartData {
        fetched += 1
        guard canFetch else { throw NoBuildMachine() }
        let data = DemoPartData.make(part: part)
        stored = data
        return data
    }
}

/// The Package and Device windows and I/O planning: the constraints file is what changes.
@MainActor
final class ChipViewsAppTests: ExampleSandboxTestCase {
    func until(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    let xdc = "blinky.srcs/constrs_1/imports/basys3.xdc"

    /// The example project (blinky on a Basys 3, with its XDC) built, with the made-up part data.
    func makeModel(part: PartData? = DemoPartData.make(part: "xc7a35tcpg236-1")) async throws -> AppModel {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.chipViews = ChipViews(backend: FixedPartDataBackend(part))
        model.openExampleProject()
        func port(_ name: String, _ dir: String, _ pin: String) -> DesignPort {
            DesignPort(name: name, direction: dir, packagePin: pin, ioStandard: "LVCMOS33", slew: "", drive: "", pullType: "")
        }
        func snapshot(_ stage: DesignStage) -> DesignSnapshot {
            DesignSnapshot(stage: stage, info: DesignInfo(stage: stage.rawValue, part: "xc7a35tcpg236-1", top: "blinky"),
                           cells: [DesignCell(name: "clk_IBUF_inst", type: "IBUF", isPrimitive: true),
                                   DesignCell(name: "clk_IBUF_BUFG_inst", type: "BUFG", isPrimitive: true),
                                   DesignCell(name: "q_reg", type: "FDRE", isPrimitive: true)],
                           ports: [port("clk", "IN", "W5"), port("btnC", "IN", "U18"), port("led[0]", "OUT", "U16"), port("led[1]", "OUT", "E19"),
                                   port("led[2]", "OUT", "U19"), port("led[3]", "OUT", "V19")],
                           pins: [DesignPin(name: "clk_IBUF_inst/I", direction: "IN"), DesignPin(name: "clk_IBUF_inst/O", direction: "OUT"),
                                  DesignPin(name: "clk_IBUF_BUFG_inst/I", direction: "IN"), DesignPin(name: "clk_IBUF_BUFG_inst/O", direction: "OUT"),
                                  DesignPin(name: "q_reg/C", direction: "IN", isClock: true), DesignPin(name: "q_reg/D", direction: "IN")],
                           nets: [DesignNet(name: "clk", type: "SIGNAL", endpoints: [NetEndpoint(name: "clk", isPort: true), NetEndpoint(name: "clk_IBUF_inst/I", isPort: false)]),
                                  DesignNet(name: "clk_IBUF", type: "SIGNAL", endpoints: [NetEndpoint(name: "clk_IBUF_inst/O", isPort: false), NetEndpoint(name: "clk_IBUF_BUFG_inst/I", isPort: false)]),
                                  DesignNet(name: "btnC", type: "SIGNAL", endpoints: [NetEndpoint(name: "btnC", isPort: true), NetEndpoint(name: "q_reg/D", isPort: false)])],
                           properties: stage == .impl ? ["cell:q_reg": [DesignProperty(name: "LOC", value: "SLICE_X2Y15"), DesignProperty(name: "BEL", value: "SLICEL.AFF")],
                                                         "cell:clk_IBUF_BUFG_inst": [DesignProperty(name: "LOC", value: "BUFGCTRL_X0Y0")]] : [:])
        }
        backend.outcome.designs = [.rtl: snapshot(.rtl), .synth: snapshot(.synth), .impl: snapshot(.impl)]
        model.run(.implementation)
        try await until("the build") { !model.isRunning && model.designs[.impl] != nil }
        return model
    }

    func onDisk(_ model: AppModel, _ path: String) throws -> String {
        try String(contentsOf: try XCTUnwrap(model.projectURL).appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Ports

    func testPlannedPortsComeFromTheConstraints() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.constraintFiles().map(\.path), [xdc])
        let ports = model.plannedPorts(.synth)
        XCTAssertEqual(ports.first { $0.name == "clk" }?.pin, "W5")
        XCTAssertEqual(ports.first { $0.name == "led[3]" }?.standard, "LVCMOS33")
        XCTAssertEqual(Set(ports.filter(\.isClock).map(\.name)), ["clk"], "clk reaches a BUFG through its input buffer")
        XCTAssertEqual(model.pinIssues(.synth), [])
    }

    func testPlacingAPortEditsTheXDCAndMakesTheRunsOutOfDate() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.runs[.synthesis]?.isUpToDate, true)
        XCTAssertTrue(model.placePort("led[0]", on: "v15", in: .synth))
        let text = try onDisk(model, xdc)
        XCTAssertTrue(text.contains("set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]"), text)
        XCTAssertTrue(text.contains("PACKAGE_PIN E19"), "the other LEDs are untouched")
        XCTAssertEqual(model.runs[.implementation]?.outOfDate, true, "as saving any constraint does")
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, false, "implementation reads the constraints on top of the synthesized netlist")
        XCTAssertEqual(model.plannedPorts(.synth).first { $0.name == "led[0]" }?.pin, "V15")
        XCTAssertTrue(model.tclLines.contains { $0.text == "set_property PACKAGE_PIN V15 [get_ports {led[0]}]" })
        XCTAssertNil(model.chipViews.notice)
    }

    func testAPinThatCantTakeThePortIsRefused() async throws {
        let model = try await makeModel()
        let before = try onDisk(model, xdc)
        XCTAssertFalse(model.placePort("led[0]", on: "J10", in: .synth), "a power pin in the made-up package")
        XCTAssertFalse(model.placePort("led[0]", on: "W5", in: .synth), "clk is there")
        XCTAssertTrue(model.chipViews.notice?.contains("W5") == true, model.chipViews.notice ?? "")
        XCTAssertEqual(try onDisk(model, xdc), before)
        XCTAssertEqual(model.runs[.synthesis]?.isUpToDate, true)
    }

    func testWithoutPartDataPlacementStillWorksUnchecked() async throws {
        let model = try await makeModel(part: nil)
        XCTAssertNil(model.partData(of: .synth))
        XCTAssertTrue(model.placePort("led[0]", on: "J10", in: .synth), "no rules to check it against")
        XCTAssertEqual(model.pinIssues(.synth), [])
    }

    func testUnplacingRemovesTheKeyAndTheTableShowsItUnplaced() async throws {
        let model = try await makeModel()
        model.placePort("btnC", on: nil, in: .synth)
        XCTAssertTrue(try onDisk(model, xdc).contains("set_property -dict { IOSTANDARD LVCMOS33 } [get_ports btnC]"))
        let btn = try XCTUnwrap(model.plannedPorts(.synth).first { $0.name == "btnC" })
        XCTAssertFalse(btn.isPlaced, "the XDC assigns pins, so one it doesn't mention has none, whatever the build said")
        XCTAssertTrue(model.pinIssues(.synth).contains { $0.rule == "UCIO-1" && $0.ports == ["btnC"] })
    }

    func testStandardsForSeveralPortsAndBankClashesShow() async throws {
        let model = try await makeModel()
        model.setIOStandard("LVCMOS18", of: ["led[0]", "led[1]"], in: .synth)
        let text = try onDisk(model, xdc)
        XCTAssertTrue(text.contains("{ PACKAGE_PIN U16 IOSTANDARD LVCMOS18 }"))
        XCTAssertTrue(text.contains("{ PACKAGE_PIN E19 IOSTANDARD LVCMOS18 }"))
        // led[0] (U16) shares the made-up bank 14 with 3.3 V ports.
        XCTAssertTrue(model.pinIssues(.synth).contains { $0.rule == "BIVC-1" && $0.ports.contains("led[0]") })
    }

    func testAnXDCWithUnsavedEditsGetsTheChangeInItsEditor() async throws {
        let model = try await makeModel()
        let saved = try onDisk(model, xdc)
        model.updateDraft(saved + "# my note\n", for: xdc)
        XCTAssertTrue(model.placePort("led[1]", on: "V15", in: .synth))
        XCTAssertEqual(try onDisk(model, xdc), saved, "not saved behind the user's back")
        XCTAssertTrue(model.editedText(for: xdc).contains("PACKAGE_PIN V15"))
        XCTAssertTrue(model.editedText(for: xdc).contains("# my note"))
        XCTAssertEqual(model.plannedPorts(.synth).first { $0.name == "led[1]" }?.pin, "V15", "the views follow the editor")
    }

    // MARK: Windows

    func testPackageAndDeviceWindowsBelongToTheirDesign() async throws {
        let model = try await makeModel()
        model.openPackage(.synth)
        XCTAssertEqual(model.selectedTab, .package(.synth))
        XCTAssertEqual(model.activeDesign, .synth)
        XCTAssertEqual(model.title(of: .package(.synth)), "Package")
        model.openDevice(.impl)
        XCTAssertEqual(model.selectedTab, .device(.impl))
        XCTAssertEqual(model.title(of: .device(.impl)), "Device")
        model.openDevice(.rtl)
        XCTAssertFalse(model.openTabs.contains(.device(.rtl)), "the elaborated design has no Device window, as in Vivado")
        model.open(.design(.synth))
        model.close(.design(.synth))
        XCTAssertFalse(model.openTabs.contains(.package(.synth)), "closing a design closes its windows")
        XCTAssertTrue(model.openTabs.contains(.device(.impl)))
    }

    func testPlacementIsReadFromTheSavedLOCs() async throws {
        let model = try await makeModel()
        let impl = try XCTUnwrap(model.designs[.impl])
        XCTAssertEqual(model.chipViews.cellsBySite(in: impl), ["SLICE_X2Y15": ["q_reg"], "BUFGCTRL_X0Y0": ["clk_IBUF_BUFG_inst"]])
        XCTAssertEqual(model.chipViews.cellsBySite(in: try XCTUnwrap(model.designs[.synth])), [:])
    }

    // MARK: Part data

    func testMissingPartDataCanBeFetchedOnce() async throws {
        let model = try await makeModel(part: nil)
        let backend = FixedPartDataBackend(nil)
        model.chipViews = ChipViews(backend: backend)
        XCTAssertNil(model.partData(of: .synth))
        model.chipViews.fetch("xc7a35tcpg236-1")
        XCTAssertEqual(model.chipViews.load(of: "xc7a35tcpg236-1"), .loading)
        try await until("the part data") { model.chipViews.load(of: "xc7a35tcpg236-1") == .idle }
        XCTAssertNotNil(model.partData(of: .synth))
        XCTAssertEqual(backend.fetched, 1)
    }

    func testWithoutABuildMachineFetchingSaysWhy() async throws {
        let model = try await makeModel(part: nil)
        model.chipViews = ChipViews(backend: FixedPartDataBackend(nil, canFetch: false))
        model.chipViews.fetch("xc7a35tcpg236-1")
        try await until("the failure") { model.chipViews.load(of: "xc7a35tcpg236-1") != .loading }
        XCTAssertEqual(model.chipViews.load(of: "xc7a35tcpg236-1"), .failed(NoBuildMachine.message))
    }

    func testTheBackendFollowsTheApps() {
        XCTAssertTrue(ChipViews.backend(for: DemoBackend(speed: 0)).isDemo)
        XCTAssertFalse(ChipViews.backend(for: LocalBackend()).canFetch, "no build machine: only what was saved before")
        let live = ChipViews.backend(for: LiveBackend(config: BridgeConfig(host: "pc", user: "me", vivadoPath: "C:/vivado.bat")))
        XCTAssertTrue(live.canFetch)
        XCTAssertFalse(live.isDemo)
    }

    func testTheDemoPackageHasTheExamplesPinsAsUserIO() {
        let data = DemoPartData.make(part: "xc7a35tcpg236-1")
        for pin in ["W5", "U18", "U16", "E19", "U19", "V19"] { XCTAssertEqual(data.pin(named: pin)?.kind, .userIO, pin) }
        XCTAssertEqual(data.pin(named: "J10")?.kind == .userIO, false)
        XCTAssertGreaterThan(DieLayout(part: data).blocks.count, 0)
    }
}
