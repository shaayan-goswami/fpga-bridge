import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

/// An IP backend the test controls. It records what it was asked and can refuse settings like Vivado does.
final class ScriptedIPBackend: IPBackend, @unchecked Sendable {
    let isDemo = false
    private let lock = NSLock()
    private var _catalogCalls: [(part: String, refresh: Bool)] = []
    private var _templateCalls: [String] = []

    var catalog = IPCatalog(definitions: DemoIPBackend.definitions, part: "xc7a35t", vivado: "2025.2")
    var catalogError: Error?
    var properties = [IPProperty(name: "CONFIG.Output_Width", value: "16"), IPProperty(name: "CONFIG.CE", value: "false")]
    /// A setting value Vivado refuses.
    var refusedValue: String?

    var catalogCalls: [(part: String, refresh: Bool)] { lock.withLock { _catalogCalls } }
    var templateCalls: [String] { lock.withLock { _templateCalls } }

    func catalog(part: String, refresh: Bool) async throws -> IPCatalog {
        lock.withLock { _catalogCalls.append((part, refresh)) }
        if let catalogError { throw catalogError }
        return catalog
    }

    func properties(of ip: IPDefinition, part: String) async throws -> [IPProperty] { properties }

    func template(for ip: ProjectIP, part: String) async throws -> IPScriptOutput {
        lock.withLock { _templateCalls.append(ip.name) }
        if let refusedValue, ip.config.values.contains(refusedValue) {
            throw IPServiceError.vivado("ERROR: value '\(refusedValue)' is not valid")
        }
        return IPScriptOutput(verilogTemplate: ["//----------- Begin Cut here for INSTANTIATION Template ---// INST_TAG", "\(ip.name) u (.CLK(CLK));",
                                                "// INST_TAG_END ------ End INSTANTIATION Template ---------"])
    }
}

@MainActor
final class IPAppTests: ExampleSandboxTestCase {
    func makeModel(_ backend: ScriptedIPBackend = ScriptedIPBackend()) -> (AppModel, ScriptedIPBackend) {
        let model = AppModel(backend: DemoBackend(speed: 0), ips: backend, persist: false)
        model.openExampleProject()
        return (model, backend)
    }

    func until(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    let counter = ProjectIP(name: "cnt8", vlnv: "xilinx.com:ip:c_counter_binary:12.0", config: ["CONFIG.Output_Width": "8"])

    // MARK: The catalog

    func testTheFlowItemOpensTheCatalogAndLoadsItOnce() async throws {
        let (model, backend) = makeModel()
        XCTAssertTrue(FlowItem.ipCatalog.isAvailable)
        model.perform(.ipCatalog)
        XCTAssertEqual(model.selectedTab, .ipCatalog)
        XCTAssertEqual(model.title(of: .ipCatalog), "IP Catalog")
        try await until("the catalog") { model.ipCatalog != nil }
        XCTAssertEqual(backend.catalogCalls.count, 1)
        XCTAssertEqual(backend.catalogCalls.first?.part, model.project?.part, "for the project's device")
        XCTAssertEqual(backend.catalogCalls.first?.refresh, false)

        model.perform(.ipCatalog)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(backend.catalogCalls.count, 1, "already loaded: opening it again doesn't ask Vivado again")
    }

    func testRefreshAsksAgain() async throws {
        let (model, backend) = makeModel()
        model.openIPCatalog()
        try await until("the catalog") { model.ipCatalog != nil }
        model.loadIPCatalog(refresh: true)
        try await until("the refresh") { backend.catalogCalls.count == 2 }
        XCTAssertEqual(backend.catalogCalls.last?.refresh, true)
    }

    func testAFailedLoadSaysWhyAndCanBeRetried() async throws {
        let backend = ScriptedIPBackend()
        backend.catalogError = IPServiceError.noCatalog
        let (model, _) = makeModel(backend)
        model.openIPCatalog()
        try await until("the failure") { if case .failed = model.ipLoad { return true } else { return false } }
        guard case .failed(let why) = model.ipLoad else { return XCTFail() }
        XCTAssertTrue(why.contains("didn't list any IP"), why)
        XCTAssertNil(model.ipCatalog)

        backend.catalogError = nil
        model.loadIPCatalog(refresh: true)
        try await until("the retry") { model.ipCatalog != nil }
        XCTAssertEqual(model.ipLoad, .idle)
    }

    func testTheCatalogIsForgottenWhenTheProjectChanges() async throws {
        let (model, _) = makeModel()
        model.openIPCatalog()
        try await until("the catalog") { model.ipCatalog != nil }
        model.closeProject()
        XCTAssertNil(model.ipCatalog, "another project may have a different device")
        XCTAssertEqual(model.ipLoad, .idle)
    }

    func testPropertiesComeFromTheBackend() async throws {
        let (model, _) = makeModel()
        let counterDef = try XCTUnwrap(DemoIPBackend.definitions.first { $0.name == "c_counter_binary" })
        let properties = try await model.ipProperties(of: counterDef)
        XCTAssertEqual(properties.map(\.name), ["CONFIG.Output_Width", "CONFIG.CE"])
    }

    // MARK: Adding

    func testAddingAnIPSavesItAndOutdatesSynthesis() async throws {
        let (model, backend) = makeModel()
        model.run(.synthesis)
        try await until("synthesis") { model.runs[.synthesis]?.isUpToDate == true }

        try await model.addIP(counter)
        XCTAssertEqual(model.project?.ips, [counter])
        XCTAssertEqual(try Project.load(from: XCTUnwrap(model.projectURL)).ips, [counter], "written to the project file")
        XCTAssertEqual(backend.templateCalls, ["cnt8"], "Vivado checked the settings first")
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, true, "the design changed")
        XCTAssertTrue(model.tclLines.contains { $0.text.hasPrefix("create_ip -name c_counter_binary -vendor xilinx.com -library ip -version 12.0 -module_name cnt8") })
    }

    func testVivadoRefusingTheSettingsMeansNothingIsSaved() async throws {
        let backend = ScriptedIPBackend()
        backend.refusedValue = "99999"
        let (model, _) = makeModel(backend)
        let bad = ProjectIP(name: "cnt8", vlnv: counter.vlnv, config: ["CONFIG.Output_Width": "99999"])
        do {
            try await model.addIP(bad)
            XCTFail("should have thrown")
        } catch {
            XCTAssertTrue(error.userMessage.contains("99999"), error.userMessage)
        }
        XCTAssertNil(model.project?.ips)
        XCTAssertNil(try Project.load(from: XCTUnwrap(model.projectURL)).ips)
    }

    func testABadNameIsRefusedBeforeVivadoIsAsked() async throws {
        let (model, backend) = makeModel()
        do {
            try await model.addIP(ProjectIP(name: "has space", vlnv: counter.vlnv))
            XCTFail("should have thrown")
        } catch {
            XCTAssertTrue(error.userMessage.contains("instance name"), error.userMessage)
        }
        XCTAssertTrue(backend.templateCalls.isEmpty)
    }

    func testTwoIPCannotShareAName() async throws {
        let (model, _) = makeModel()
        try await model.addIP(counter)
        do {
            try await model.addIP(counter)
            XCTFail("should have thrown")
        } catch {
            XCTAssertTrue(error.userMessage.contains("already has an IP called 'cnt8'"), error.userMessage)
        }
        XCTAssertEqual(model.project?.ips?.count, 1)
    }

    func testTheBuildScriptIncludesTheAddedIP() async throws {
        let (model, _) = makeModel()
        try await model.addIP(counter)
        let project = try XCTUnwrap(model.project)
        let script = project.buildScript(sources: [], constraints: [])
        XCTAssertTrue(script.contains("create_ip -name c_counter_binary"))
        XCTAssertTrue(script.contains("set_property -dict [list CONFIG.Output_Width {8}] [get_ips cnt8]"))
        XCTAssertTrue(script.contains("synth_ip [get_ips cnt8]"))
    }

    // MARK: Templates and removing

    func testATemplateIsAskedForOncePerConfiguration() async throws {
        let (model, backend) = makeModel()
        _ = try await model.ipTemplate(for: counter)
        _ = try await model.ipTemplate(for: counter)
        XCTAssertEqual(backend.templateCalls.count, 1, "cached")
        var wider = counter
        wider.config["CONFIG.Output_Width"] = "32"
        _ = try await model.ipTemplate(for: wider)
        XCTAssertEqual(backend.templateCalls.count, 2, "different settings, different template")
    }

    func testRemovingAnIPTakesItOutOfTheFileAndOutdatesSynthesis() async throws {
        let (model, _) = makeModel()
        try await model.addIP(counter)
        model.run(.synthesis)
        try await until("synthesis") { model.runs[.synthesis]?.isUpToDate == true }

        model.removeIP(named: "cnt8")
        XCTAssertNil(model.project?.ips, "an empty list isn't written")
        XCTAssertNil(try Project.load(from: XCTUnwrap(model.projectURL)).ips)
        XCTAssertEqual(model.runs[.synthesis]?.outOfDate, true)
        model.removeIP(named: "nothing")           // harmless
    }

    // MARK: Demo data

    func testDemoCatalogHasSupportedAndUnsupportedIPAndRefusesABadValue() async throws {
        let demo = DemoIPBackend(speed: 0)
        let catalog = try await demo.catalog(part: "xc7a35t", refresh: false)
        XCTAssertTrue(catalog.vivado.contains("demo"), "sample data says so")
        XCTAssertTrue(catalog.definitions.contains { !$0.supported })
        XCTAssertTrue(catalog.definitions.contains { $0.supported })
        let counterDef = try XCTUnwrap(catalog.definitions.first { $0.name == "c_counter_binary" })
        let demoProperties = try await demo.properties(of: counterDef, part: "xc7a35t")
        XCTAssertFalse(demoProperties.isEmpty)
        let ok = try await demo.template(for: counter, part: "xc7a35t")
        XCTAssertTrue(IPScripts.cutSection(of: ok.verilogTemplate).contains("cnt8 your_instance_name"))
        do {
            _ = try await demo.template(for: ProjectIP(name: "x", vlnv: counter.vlnv, config: ["CONFIG.A": "bad"]), part: "p")
            XCTFail("demo mode should refuse 'bad'")
        } catch { /* expected */ }
    }
}
