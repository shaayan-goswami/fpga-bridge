import FPGABridgeCore
import SwiftUI
import XCTest
@testable import FPGABridgeApp

/// A block design in a project: listed under Design Sources, opened from the Flow Navigator, and left out of builds
/// with a note. The block design is Vivado 2025.2's, from the core tests' fixtures.
@MainActor
final class BlockDesignAppTests: ExampleSandboxTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FPGABridgeCoreTests/Fixtures/blockdesign_vivado2025/mb_system")
    }

    /// The example project, with the MicroBlaze block design copied where Vivado keeps block designs.
    private func exampleWithBlockDesign(backend: Backend = DemoBackend(speed: 0)) throws -> (AppModel, String) {
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        let root = try XCTUnwrap(model.projectURL)
        let project = try XCTUnwrap(model.project)
        let relative = "\(ProjectCreator.relativeDirectory(for: .design, projectName: project.name))/bd/mb_system"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(relative))
        model.openProject(at: root)
        return (model, relative + "/mb_system.bd")
    }

    func testWithoutABlockDesignOpenBlockDesignIsGreyedWithAReason() {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        XCTAssertEqual(model.blockDesignPaths, [])
        XCTAssertNotNil(model.unavailableReason(of: .openBlockDesign))
        XCTAssertTrue(model.unavailableReason(of: .createBlockDesign)?.hasPrefix("Coming soon") == true)
        XCTAssertTrue(model.unavailableReason(of: .generateBlockDesign)?.hasPrefix("Coming soon") == true)
        XCTAssertNil(model.unavailableReason(of: .runSynthesis))
        model.perform(.openBlockDesign)
        XCTAssertFalse(model.openTabs.contains { if case .blockDesign = $0 { return true } else { return false } })
    }

    func testABlockDesignIsListedUnderDesignSources() throws {
        let (model, path) = try exampleWithBlockDesign()
        XCTAssertEqual(model.blockDesignPaths, [path])
        let group = try XCTUnwrap(model.sourceTree.first { $0.id == "group.design" })
        let node = try XCTUnwrap(group.children?.first { $0.id == "bd:" + path })
        XCTAssertEqual(node.title, "mb_system")
        XCTAssertEqual(node.detail, "(mb_system.bd)")
        XCTAssertEqual(node.path, path)
        XCTAssertTrue(node.children?.contains { $0.title == "microblaze_0 : mb_system_microblaze_0_0" } == true)
        XCTAssertEqual(node.children?.count, 13, "every IP (the AXI Interconnect is one), plain hierarchies left out")
        let hdl = try SourceTreeBuilder.build(top: model.project!.top, design: model.project!.resolveSources(in: model.projectURL!),
                                             constraints: [], simulation: [], read: model.contents(of:))
        XCTAssertEqual(group.detail, "(\(Int(hdl[0].detail!.dropFirst().dropLast())! + 1))", "the count includes the block design")
    }

    func testOpenBlockDesignOpensItsTab() throws {
        let (model, path) = try exampleWithBlockDesign()
        XCTAssertNil(model.unavailableReason(of: .openBlockDesign))
        model.perform(.openBlockDesign)
        XCTAssertEqual(model.selectedTab, .blockDesign(path))
        XCTAssertEqual(model.title(of: .blockDesign(path)), "Block Design - mb_system")
        XCTAssertTrue(model.tclLines.contains { $0.text == "open_bd_design {\(path)}" && $0.kind == .command })
        model.close(.blockDesign(path))
        XCTAssertFalse(model.openTabs.contains(.blockDesign(path)))
    }

    func testABuildLeavesTheBlockDesignOutAndSaysSo() async throws {
        let backend = ScriptedBuildBackend()
        let (model, _) = try exampleWithBlockDesign(backend: backend)
        model.run(.synthesis)
        while model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.runs, [.synthesis], "the build still runs")
        let note = try XCTUnwrap(model.tclLines.first { $0.text.contains("mb_system.bd") })
        XCTAssertEqual(note.kind, .warning)
        XCTAssertTrue(note.text.contains("Block designs aren't built yet"))
        // The script itself reads HDL only.
        let script = try model.project!.buildScript(sources: model.project!.resolveSources(in: model.projectURL!), constraints: [])
        XCTAssertFalse(script.contains(".bd"))
    }

    func testABuildWithoutBlockDesignsSaysNothingAboutThem() async throws {
        let backend = ScriptedBuildBackend()
        let model = AppModel(backend: backend, persist: false)
        model.openExampleProject()
        model.run(.synthesis)
        while model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.tclLines.contains { $0.text.contains("Block designs") })
    }

    func testSelectionNamesAsVivadoDoes() throws {
        let design = try BlockDesign.load(from: fixture.appendingPathComponent("mb_system.bd"))
        XCTAssertEqual(BDSelection.cell("microblaze_0_local_memory/lmb_bram").vivadoName, "/microblaze_0_local_memory/lmb_bram")
        XCTAssertEqual(BDSelection.pin(cell: "axi_gpio_0", name: "S_AXI").vivadoName, "/axi_gpio_0/S_AXI")
        XCTAssertEqual(BDSelection.net(level: "", name: "reset_1", isInterface: false).vivadoName, "/reset_1")
        XCTAssertTrue(BDSelection.port("UART_0").exists(in: design))
        XCTAssertTrue(BDSelection.net(level: "microblaze_0_local_memory", name: "microblaze_0_dlmb_bus", isInterface: true).exists(in: design))
        XCTAssertFalse(BDSelection.net(level: "", name: "reset_1", isInterface: true).exists(in: design))
        XCTAssertFalse(BDSelection.cell("gone").exists(in: design))
    }

    func testAddressEditorRowsGroupByMasterAndSpace() throws {
        let design = try BlockDesign.load(from: fixture.appendingPathComponent("mb_system.bd"))
        var selection: BDSelection?
        let table = AddressEditorTable(design: design, selection: Binding(get: { selection }, set: { selection = $0 }))
        let rows = table.rows
        XCTAssertEqual(rows.map(\.name), ["/microblaze_0", "/microblaze_0/Data", "/axi_gpio_0", "/axi_uartlite_0",
                                          "/microblaze_0_local_memory/dlmb_bram_if_cntlr", "/microblaze_0/Instruction",
                                          "/microblaze_0_local_memory/ilmb_bram_if_cntlr"])
        let uart = try XCTUnwrap(rows.first { $0.name == "/axi_uartlite_0" })
        XCTAssertEqual([uart.interface, uart.segment, uart.base, uart.range, uart.high], ["S_AXI", "Reg", "0x4060_0000", "64K", "0x4060_FFFF"])
        XCTAssertEqual(uart.cell, "axi_uartlite_0")
    }
}
