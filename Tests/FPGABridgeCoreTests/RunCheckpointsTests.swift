import XCTest
@testable import FPGABridgeCore

final class RunKeysTests: XCTestCase {
    let design = ["src/top.v": "aa", "src/alu.sv": "bb"]
    let constraints = ["pins.xdc": "cc"]

    func keys(_ change: (inout Project) -> Void = { _ in }, design: [String: String]? = nil, constraints: [String: String]? = nil,
              vivado: String = #"C:\Xilinx\2025.2\Vivado\bin\vivado.bat"#) -> RunKeys {
        var p = Project(name: "p", top: "top", part: "xc7a35tcpg236-1", sources: ["src"], constraints: [])
        change(&p)
        return RunKeys(project: p, design: design ?? self.design, constraints: constraints ?? self.constraints, vivadoPath: vivado)
    }

    func testTheSameInputsGiveTheSameKeys() {
        XCTAssertEqual(keys(), keys())
        XCTAssertEqual(keys().synthesis.count, 16)
    }

    func testAConstraintChangeLeavesSynthesisCurrent() {
        let a = keys(), b = keys(constraints: ["pins.xdc": "dd"])
        XCTAssertEqual(a.synthesis, b.synthesis)
        XCTAssertNotEqual(a.implementation, b.implementation)
        XCTAssertNotEqual(a.bitstream, b.bitstream, "the bitstream follows implementation")
    }

    func testASourceOrSynthesisSettingChangesEveryKey() {
        let a = keys()
        for b in [keys(design: ["src/top.v": "zz", "src/alu.sv": "bb"]), keys { $0.top = "other" },
                  keys { $0.settings = ProjectSettings(); $0.settings?.synthesis.retiming = true },
                  keys { $0.settings = ProjectSettings(); $0.settings?.language.defines = ["FAST"] },
                  keys(vivado: #"C:\Xilinx\2024.2\Vivado\bin\vivado.bat"#)] {
            XCTAssertNotEqual(a.synthesis, b.synthesis)
            XCTAssertNotEqual(a.implementation, b.implementation)
        }
    }

    func testImplementationAndBitstreamSettingsOnlyTouchTheirOwnSteps() {
        let a = keys()
        let impl = keys { $0.settings = ProjectSettings(); $0.settings?.implementation.routeDirective = "Explore" }
        XCTAssertEqual(a.synthesis, impl.synthesis)
        XCTAssertNotEqual(a.implementation, impl.implementation)
        let bit = keys { $0.settings = ProjectSettings(); $0.settings?.bitstream.compress = true }
        XCTAssertEqual(a.implementation, bit.implementation)
        XCTAssertNotEqual(a.bitstream, bit.bitstream)
        let sim = keys { $0.settings = ProjectSettings(); $0.settings?.simulation.timeLimit = 5 }
        XCTAssertEqual(a, sim, "simulation settings never touch a run")
    }

    func testRecordedKeysAndWhichAreStillCurrent() {
        let a = keys()
        XCTAssertEqual(a.recorded(through: .synthesis), ["synth_1": a.synthesis])
        XCTAssertEqual(a.recorded(through: .bitstream), ["synth_1": a.synthesis, "impl_1": a.implementation, "write_bitstream": a.bitstream])
        XCTAssertEqual(a.current(in: a.recorded(through: .bitstream)), [.synthesis, .implementation, .bitstream])
        let moved = keys(constraints: ["pins.xdc": "dd"])
        XCTAssertEqual(moved.current(in: a.recorded(through: .bitstream)), [.synthesis])
        XCTAssertEqual(a.current(in: ["impl_1": a.implementation]), [], "a step counts only with every step before it")
    }
}

final class BuildFolderTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("buildfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func folder(_ name: String, _ files: [String]) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try name.write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        return url
    }

    func contents(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            result[name] = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
        }
        return result
    }

    let full = ["rtl_cells.tsv", "synth_utilization.rpt", "synth_cells.tsv", "timing_summary.rpt", "impl_cells.tsv",
                "power.rpt", "top.bit", "top.bin", "build-manifest.json"]

    func testSynthesisReplacesEverything() throws {
        let build = try folder("old", full)
        try BuildFolder.merge(try folder("new", ["rtl_cells.tsv", "synth_cells.tsv"]), into: build, startingWith: .synthesis)
        XCTAssertEqual(try contents(build), ["rtl_cells.tsv": "new", "synth_cells.tsv": "new"])
    }

    func testImplementationKeepsSynthesisAndReplacesTheRest() throws {
        let build = try folder("old", full)
        try BuildFolder.merge(try folder("new", ["timing_summary.rpt", "impl_cells.tsv"]), into: build, startingWith: .implementation)
        XCTAssertEqual(try contents(build), ["rtl_cells.tsv": "old", "synth_utilization.rpt": "old", "synth_cells.tsv": "old",
                                             "timing_summary.rpt": "new", "impl_cells.tsv": "new"])
    }

    func testTheBitstreamReplacesOnlyTheBitstream() throws {
        let build = try folder("old", full)
        try BuildFolder.merge(try folder("new", ["top.bit"]), into: build, startingWith: .bitstream)
        let after = try contents(build)
        XCTAssertEqual(after["top.bit"], "new")
        XCTAssertNil(after["top.bin"], "a .bin from an earlier bitstream doesn't stay next to a new .bit")
        XCTAssertEqual(after["timing_summary.rpt"], "old")
    }

    func testMergingIntoAMissingFolderCreatesIt() throws {
        let build = tmp.appendingPathComponent("build")
        try BuildFolder.merge(try folder("new", ["synth_cells.tsv"]), into: build, startingWith: .implementation)
        XCTAssertEqual(try contents(build), ["synth_cells.tsv": "new"])
    }
}
