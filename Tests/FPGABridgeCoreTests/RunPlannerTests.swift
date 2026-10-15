import XCTest
@testable import FPGABridgeCore

final class RunPlannerTests: XCTestCase {
    private func plan(_ target: RunKind, synth: Bool, impl: Bool) -> [RunKind] {
        RunPlanner.steps(for: target, synthesisUpToDate: synth, implementationUpToDate: impl)
    }

    func testRunSynthesisRunsOnlySynthesis() {
        for synth in [true, false] { for impl in [true, false] {
            XCTAssertEqual(plan(.synthesis, synth: synth, impl: impl), [.synthesis])
        } }
    }

    func testRunImplementationRunsSynthesisFirstOnlyWhenNeeded() {
        XCTAssertEqual(plan(.implementation, synth: true, impl: true), [.implementation], "an explicit request always runs")
        XCTAssertEqual(plan(.implementation, synth: true, impl: false), [.implementation])
        XCTAssertEqual(plan(.implementation, synth: false, impl: false), [.synthesis, .implementation])
        XCTAssertEqual(plan(.implementation, synth: false, impl: true), [.synthesis, .implementation])
    }

    func testGenerateBitstreamRunsWhateverIsMissing() {
        XCTAssertEqual(plan(.bitstream, synth: true, impl: true), [.bitstream])
        XCTAssertEqual(plan(.bitstream, synth: true, impl: false), [.implementation, .bitstream])
        XCTAssertEqual(plan(.bitstream, synth: false, impl: false), [.synthesis, .implementation, .bitstream])
    }

    func testBitstreamNeverComesFromAnImplementationOfOldSynthesis() {
        // The old rule planned [synthesis, bitstream] here, building a bitstream from the stale implementation.
        XCTAssertEqual(plan(.bitstream, synth: false, impl: true), [.synthesis, .implementation, .bitstream])
    }

    func testStepsAreAlwaysInDependencyOrderWithoutRepeats() {
        for target in RunKind.allCases { for synth in [true, false] { for impl in [true, false] {
            let steps = plan(target, synth: synth, impl: impl)
            XCTAssertEqual(steps, steps.sorted { RunKind.allCases.firstIndex(of: $0)! < RunKind.allCases.firstIndex(of: $1)! })
            XCTAssertEqual(steps.count, Set(steps).count)
            XCTAssertEqual(steps.last, target, "the requested step is the last one")
        } } }
    }

    func testBitstreamBelongsToTheImplementationRun() {
        XCTAssertEqual(RunKind.bitstream.run, .implementation)
        XCTAssertEqual(RunKind.bitstream.runName, "impl_1")
        XCTAssertEqual(RunKind.synthesis.runName, "synth_1")
    }
}
