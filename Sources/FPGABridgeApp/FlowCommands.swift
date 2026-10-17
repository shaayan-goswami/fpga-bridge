import FPGABridgeCore
import Foundation

extension AppModel {
    /// Whether a design's window is open (Vivado then calls it "Synthesized Design" instead of "Open ...").
    func isDesignOpen(_ stage: DesignStage) -> Bool {
        openTabs.contains(.design(stage)) || openTabs.contains(.schematic(stage))
    }

    /// The report a design command shows, if the last build wrote it.
    func report(for command: DesignCommand, stage: DesignStage) -> ReportEntry? {
        guard let file = command.report?.fileName(for: stage) else { return nil }
        return reports.first { $0.fileName == file }
    }

    /// An item under an open design in the Flow Navigator. If the design hasn't been built, building it comes first,
    /// as in Vivado, where these open the design before running.
    func perform(_ command: DesignCommand, stage: DesignStage) {
        guard command.unavailableReason == nil, hasProject else { return }
        guard designs[stage] != nil else {
            openDesign(stage)
            return
        }
        if !isDesignOpen(stage) { open(.design(stage)) }
        designOpened(stage)
        switch command {
        case .schematic:
            openSchematic(stage)
        default:
            guard let kind = command.report else { return }
            if let entry = report(for: command, stage: stage) {
                echoTcl(kind.tclCommand)
                openReport(entry.id)
            } else if kind.fileName(for: stage) == nil {
                errorMessage = "Vivado can't produce the \(kind.title.dropFirst("Report ".count)) report for the \(stage.title.lowercased())."
            } else {
                errorMessage = "The last build didn't write this report. Run \(stage == .impl ? "implementation" : "synthesis") again to produce it."
            }
        }
    }

    /// An item under Open Hardware Manager.
    func perform(_ command: HardwareCommand) {
        guard hasProject else { return }
        open(.hardware)
        switch command {
        case .openTarget: autoConnectHardware()
        case .programDevice: hardware.present(.device, host: "main")
        case .addConfigurationMemoryDevice: hardware.present(.memory, host: "main")
        }
    }

    /// Program Device and the configuration memory need an open target, as in Vivado.
    func isAvailable(_ command: HardwareCommand) -> Bool {
        command == .openTarget || hardware.target == .open
    }
}

extension DesignReportKind {
    /// The command Vivado echoes for the report, as its Tcl Console does.
    var tclCommand: String {
        switch self {
        case .timingSummary: "report_timing_summary -delay_type min_max -max_paths 10 -name timing_1"
        case .clockNetworks: "report_clock_networks -name clocks_1"
        case .clockInteraction: "report_clock_interaction -delay_type min_max -name clocks_2"
        case .methodology: "report_methodology -name ultrafast_methodology_1"
        case .drc: "report_drc -name drc_1"
        case .noise: "report_ssn -name ssn_1"
        case .utilization: "report_utilization -name utilization_1"
        case .power: "report_power -name power_1"
        }
    }
}
