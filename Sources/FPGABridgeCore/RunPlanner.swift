import Foundation

/// What can be launched. Like Vivado, a bitstream is the last step of the implementation run.
public enum RunKind: Hashable, CaseIterable, Sendable {
    case synthesis, implementation, bitstream

    /// The Vivado run the step belongs to.
    public var run: RunKind { self == .bitstream ? .implementation : self }
    public var runName: String { run == .synthesis ? "synth_1" : "impl_1" }
    public var title: String {
        switch self {
        case .synthesis: "Synthesis"
        case .implementation: "Implementation"
        case .bitstream: "Bitstream"
        }
    }

    /// The step's name in Vivado's terms: the run, or `write_bitstream` for the bitstream step of impl_1.
    public var stepName: String { self == .bitstream ? "write_bitstream" : runName }

    /// The checkpoint the step leaves in its run folder on the build machine, for the next step to start from.
    /// The bitstream step leaves none.
    public var checkpoint: String? {
        switch self {
        case .synthesis: "post_synth"
        case .implementation: "post_route"
        case .bitstream: nil
        }
    }

    /// The step whose checkpoint this one opens when it runs on its own.
    public var startsFrom: RunKind? {
        switch self {
        case .synthesis: nil
        case .implementation: .synthesis
        case .bitstream: .implementation
        }
    }

    /// The step with this `stepName`.
    public init?(stepName: String) {
        guard let step = RunKind.flow.first(where: { $0.stepName == stepName }) else { return nil }
        self = step
    }

    /// The steps in flow order.
    public static let flow: [RunKind] = [.synthesis, .implementation, .bitstream]
}

/// Vivado's rules for what a run command has to do first.
public enum RunPlanner {
    /// The steps to run, in order, for a request. Each step needs the ones before it, so whatever is missing or
    /// out-of-date upstream runs first, and anything downstream of a re-run step runs again.
    ///
    /// - Run Synthesis runs synthesis, and only that.
    /// - Run Implementation runs implementation, after synthesis if synthesis isn't up to date.
    /// - Generate Bitstream runs the bitstream step, after whichever of the others is needed. If synthesis re-runs,
    ///   implementation re-runs too: its result would be from the old netlist.
    public static func steps(for target: RunKind, synthesisUpToDate: Bool, implementationUpToDate: Bool) -> [RunKind] {
        var plan: [RunKind] = []
        if target == .synthesis || !synthesisUpToDate { plan.append(.synthesis) }
        if target != .synthesis {
            let synthesisRuns = plan.contains(.synthesis)
            if target == .implementation || synthesisRuns || !implementationUpToDate { plan.append(.implementation) }
        }
        if target == .bitstream { plan.append(.bitstream) }
        return plan
    }
}
