import XCTest
@testable import FPGABridgeCore

final class IPCatalogTests: XCTestCase {
    /// What Vivado 2025.2 printed for `IPCatalog.listScript(part: "xc7a35tcpg236-1")`: the real catalog, with Vivado's own
    /// messages around it and the CR LF line endings Windows adds.
    func realCatalog() throws -> IPCatalog {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ip_catalog_vivado2025", withExtension: "txt", subdirectory: "Fixtures"))
        return IPCatalog.parse(output: try String(contentsOf: url, encoding: .utf8), part: "xc7a35tcpg236-1")
    }

    func testTheRealCatalogParses() throws {
        let catalog = try realCatalog()
        XCTAssertEqual(catalog.vivado, "2025.2")
        XCTAssertGreaterThan(catalog.definitions.count, 300)
        XCTAssertTrue(catalog.definitions.allSatisfy { !$0.vlnv.isEmpty && !$0.name.isEmpty && !$0.displayName.isEmpty })
        XCTAssertEqual(Set(catalog.definitions.map(\.vlnv)).count, catalog.definitions.count, "no duplicates")
    }

    func testDefinitionsThatAreNotAddableIPAreLeftOut() throws {
        let catalog = try realCatalog()
        XCTAssertEqual(catalog.definitions.count, 366, "376 entries, less the 10 interface, signal and module_ref definitions")
        XCTAssertFalse(catalog.definitions.contains { $0.library.hasSuffix(".param") })
        XCTAssertTrue(catalog.definitions.allSatisfy { !$0.taxonomy.contains("\"") }, "no stray quote characters left as categories")
        XCTAssertEqual(Set(catalog.definitions.map(\.library)), ["ip", "inline_hdl"])
    }

    func testAKnownIPHasItsDetails() throws {
        let counter = try XCTUnwrap(try realCatalog().definitions.first { $0.name == "c_counter_binary" })
        XCTAssertEqual(counter.vlnv, "xilinx.com:ip:c_counter_binary:12.0")
        XCTAssertEqual([counter.vendor, counter.library, counter.version], ["xilinx.com", "ip", "12.0"])
        XCTAssertEqual(counter.displayName, "Binary Counter")
        XCTAssertTrue(counter.supported, "counters work on Artix-7")
        XCTAssertFalse(counter.description.isEmpty)
        XCTAssertFalse(counter.categories.isEmpty)
    }

    func testDevicesOfOtherFamiliesAreMarkedUnsupported() throws {
        let catalog = try realCatalog()
        let noc = try XCTUnwrap(catalog.definitions.first { $0.name == "axis_noc" })
        XCTAssertFalse(noc.supported, "the Versal NoC isn't for a 7 series part")
        XCTAssertFalse(try XCTUnwrap(catalog.definitions.first { $0.name == "zynq_ultra_ps_e" }).supported)
        let supported = catalog.search("", onlySupported: true)
        XCTAssertGreaterThan(supported.count, 50)
        XCTAssertLessThan(supported.count, catalog.definitions.count)
    }

    func testAnIPCanBeInSeveralCategories() throws {
        let catalog = try realCatalog()
        let cdc = try XCTUnwrap(catalog.definitions.first { $0.name == "xpm_cdc_gen" })
        XCTAssertEqual(cdc.categoryPaths, [["Foundational_Elements", "Basic"], ["Foundational_Elements", "Clock_and_Reset"]])
        let tree = IPCatalog.categories(of: catalog.definitions)
        func find(_ id: String, in nodes: [IPCategory]) -> IPCategory? {
            for n in nodes { if n.id == id { return n }; if let f = find(id, in: n.children) { return f } }
            return nil
        }
        XCTAssertTrue(try XCTUnwrap(find("/Foundational_Elements/Basic", in: tree)).definitions.contains { $0.name == "xpm_cdc_gen" })
        XCTAssertTrue(try XCTUnwrap(find("/Foundational_Elements/Clock_and_Reset", in: tree)).definitions.contains { $0.name == "xpm_cdc_gen" })
    }

    func testTheCategoryTreeHoldsEveryDefinition() throws {
        let catalog = try realCatalog()
        let tree = IPCatalog.categories(of: catalog.definitions)
        let inTree = Set(tree.flatMap(\.allDefinitions).map(\.vlnv))
        XCTAssertEqual(inTree, Set(catalog.definitions.map(\.vlnv)))
        XCTAssertEqual(tree.map(\.title), tree.map(\.title).sorted(), "categories are sorted")
    }

    func testSearchFindsByNameTitleAndDescriptionWithEveryWord() throws {
        let catalog = try realCatalog()
        XCTAssertTrue(catalog.search("counter", onlySupported: false).contains { $0.name == "c_counter_binary" })
        XCTAssertTrue(catalog.search("BINARY COUNTER", onlySupported: false).contains { $0.name == "c_counter_binary" }, "case-insensitive")
        XCTAssertTrue(catalog.search("binary counter", onlySupported: false).allSatisfy { d in
            ["binary", "counter"].allSatisfy { w in (d.displayName + d.name + d.description).lowercased().contains(w) }
        })
        XCTAssertEqual(catalog.search("zzzzqqq", onlySupported: false), [])
        XCTAssertEqual(catalog.search("   ", onlySupported: false).count, catalog.definitions.count, "blank means everything")
    }

    func testResultsAreSortedByTitle() throws {
        let titles = try realCatalog().definitions.map(\.displayName)
        XCTAssertEqual(titles, titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testOnlyTheMarkedLinesAreRead() {
        let output = """
        INFO: something Vivado said
        FPGABRIDGE-IP\tVIVADO\t2024.1\t\t\t\t\t
        FPGABRIDGE-IP\tIP\tv:l:a:1.0\ta\tAAA\t/Cat\tdesc\t1\t1
        a line that merely mentions FPGABRIDGE-IP in the middle
        FPGABRIDGE-IP\tIP\t\tnameless\tNo VLNV\t/Cat\tskipped\t0\t1
        FPGABRIDGE-IP\tIP\tshort
        """
        let c = IPCatalog.parse(output: output, part: "x")
        XCTAssertEqual(c.vivado, "2024.1")
        XCTAssertEqual(c.definitions.map(\.vlnv), ["v:l:a:1.0"])
        XCTAssertTrue(c.definitions[0].requiresLicense)
        XCTAssertEqual(c.part, "x")
    }

    func testAMissingDisplayNameFallsBackToTheName() {
        let c = IPCatalog.parse(output: "FPGABRIDGE-IP\tIP\tv:l:thing:1.0\tthing\t\t/Cat\tdesc\t0\t1\n", part: "x")
        XCTAssertEqual(c.definitions.first?.displayName, "thing")
    }

    func testAnIPWithNoCategoryGoesUnderUncategorized() {
        let def = IPDefinition(vlnv: "v:l:a:1.0", name: "a", displayName: "A", taxonomy: "", description: "", requiresLicense: false, supported: true)
        XCTAssertEqual(IPCatalog.categories(of: [def]).map(\.title), ["Uncategorized"])
    }

    func testTheScriptAsksForEverythingThePageReads() {
        let tcl = IPCatalog.listScript(part: "xc7a35tcpg236-1")
        for needle in ["create_project -in_memory -part {xc7a35tcpg236-1}", "get_ipdefs", "VLNV NAME DISPLAY_NAME TAXONOMY DESCRIPTION",
                       "SUPPORTED_FAMILIES", "REQUIRES_LICENSE", "ARCHITECTURE", IPCatalog.marker] {
            XCTAssertTrue(tcl.contains(needle), needle)
        }
        XCTAssertTrue(tcl.contains(#"[list "\t" " " "\n" " " "\r" ""]"#), "tabs and newlines inside a description can't break a line")
    }
}
