import FPGABridgeCore
import Foundation

/// What the Project Summary and Design Runs show, read from the reports the last build wrote.
extension AppModel {
    func reportText(_ fileName: String) -> String? { reports.first { $0.fileName == fileName }?.text }

    func timing(at stage: DesignStage) -> TimingSummary? {
        stage == .impl ? timing : reportText("synth_timing_summary.rpt").flatMap { try? TimingSummary.parse($0) }
    }

    func utilization(at stage: DesignStage) -> UtilizationSummary? {
        reportText(stage == .impl ? BuildSummary.utilizationReport : "synth_utilization.rpt").flatMap { try? UtilizationSummary.parse($0) }
    }

    func power(at stage: DesignStage) -> PowerSummary? {
        reportText(stage == .impl ? "power.rpt" : "synth_power.rpt").flatMap(PowerSummary.parse)
    }

    func checks(_ kind: DesignReportKind, at stage: DesignStage) -> CheckSummary? {
        kind.fileName(for: stage).flatMap(reportText).flatMap(CheckSummary.parse)
    }

    var routeStatus: RouteStatus? { reportText("route_status.rpt").flatMap(RouteStatus.parse) }

    /// Warnings, critical warnings and errors in a run's log. Nil until the run has been run in this session (a
    /// restored build has its reports but not its log).
    func messageCounts(_ run: RunKind) -> (warnings: Int, critical: Int, errors: Int)? {
        guard let lines = logs[run], !lines.isEmpty else { return nil }
        var counts = (warnings: 0, critical: 0, errors: 0)
        for line in lines {
            if line.text.hasPrefix("CRITICAL WARNING:") { counts.critical += 1 }
            else if line.text.hasPrefix("WARNING:") { counts.warnings += 1 }
            else if line.text.hasPrefix("ERROR:") { counts.errors += 1 }
        }
        return counts
    }

    var synthesisStrategy: String {
        let settings = project?.settings ?? ProjectSettings()
        return settings.synthesis == ProjectSettings().synthesis ? "Vivado Synthesis Defaults" : "Vivado Synthesis Defaults*"
    }

    var implementationStrategy: String {
        let settings = project?.settings ?? ProjectSettings()
        return settings.implementation.matchingStrategy ?? "Vivado Implementation Defaults*"
    }

    /// What Vivado shows as a run's status: the last step that finished.
    func runStatusText(_ run: RunKind) -> String {
        let state = runs[run] ?? RunState()
        switch state.status {
        case .notStarted: return "Not started"
        case .running: return "Running \(run == .synthesis ? "synth_design" : "implementation")…"
        case .failed: return "\(run == .synthesis ? "synth_design" : "route_design") ERROR"
        case .cancelled: return "Cancelled"
        case .complete:
            if state.outOfDate { return "Out-of-date" }
            if run == .synthesis { return "synth_design Complete!" }
            return bitstreamReady ? "write_bitstream Complete!" : "route_design Complete!"
        }
    }
}
