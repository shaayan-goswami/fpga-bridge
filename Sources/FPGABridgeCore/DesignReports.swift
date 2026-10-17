import Foundation

/// The reports Vivado's Flow Navigator offers under an open design, and the file each stage's build writes for it.
public enum DesignReportKind: String, CaseIterable, Sendable {
    case timingSummary, clockNetworks, clockInteraction, methodology, drc, noise, utilization, power

    public var title: String {
        switch self {
        case .timingSummary: "Report Timing Summary"
        case .clockNetworks: "Report Clock Networks"
        case .clockInteraction: "Report Clock Interaction"
        case .methodology: "Report Methodology"
        case .drc: "Report DRC"
        case .noise: "Report Noise"
        case .utilization: "Report Utilization"
        case .power: "Report Power"
        }
    }

    /// The report file a build writes for this stage, or nil if Vivado can't produce it there.
    public func fileName(for stage: DesignStage) -> String? {
        switch (self, stage) {
        case (.methodology, .rtl): "rtl_methodology.rpt"
        case (.drc, .rtl): "rtl_drc.rpt"
        case (_, .rtl): nil
        case (.timingSummary, .synth): "synth_timing_summary.rpt"
        case (.clockNetworks, .synth): "synth_clock_networks.rpt"
        case (.clockInteraction, .synth): "synth_clock_interaction.rpt"
        case (.methodology, .synth): "synth_methodology.rpt"
        case (.drc, .synth): "synth_drc.rpt"
        case (.noise, .synth): "synth_noise.rpt"
        case (.utilization, .synth): "synth_utilization.rpt"
        case (.power, .synth): "synth_power.rpt"
        case (.timingSummary, .impl): "timing_summary.rpt"
        case (.clockNetworks, .impl): "clock_networks.rpt"
        case (.clockInteraction, .impl): "clock_interaction.rpt"
        case (.methodology, .impl): "methodology.rpt"
        case (.drc, .impl): "drc.rpt"
        case (.noise, .impl): "noise.rpt"
        case (.utilization, .impl): "utilization.rpt"
        case (.power, .impl): "power.rpt"
        }
    }

    /// The stage a report file belongs to, from its name: `rtl_` and `synth_` prefixes, the rest implementation.
    public static func stage(ofFile name: String) -> DesignStage {
        if name.hasPrefix("rtl_") { return .rtl }
        if name.hasPrefix("synth_") { return .synth }
        return .impl
    }

    /// A report's title from its file name, whatever the stage: `synth_drc.rpt` is the DRC Report.
    public static func title(ofFile name: String) -> String {
        var base = name
        for prefix in ["rtl_", "synth_"] where base.hasPrefix(prefix) { base.removeFirst(prefix.count) }
        switch base {
        case "timing_summary.rpt": return "Timing Summary Report"
        case "utilization.rpt": return "Utilization Report"
        case "timing_paths.rpt": return "Timing Report"
        case "clocks.rpt": return "Clock Report"
        case "clock_utilization.rpt": return "Clock Utilization Report"
        case "clock_networks.rpt": return "Clock Networks Report"
        case "clock_interaction.rpt": return "Clock Interaction Report"
        case "io.rpt": return "I/O Report"
        case "route_status.rpt": return "Route Status Report"
        case "drc.rpt": return "DRC Report"
        case "methodology.rpt": return "Methodology Report"
        case "power.rpt": return "Power Report"
        case "noise.rpt": return "Noise Report"
        default: return name
        }
    }
}

// MARK: Linter

/// One message from Vivado's RTL linter (`synth_design -lint`).
public struct LintMessage: Equatable, Sendable, Identifiable {
    public var id: String { "\(rule)|\(file ?? "")|\(line ?? 0)|\(text)" }
    public let severity: String
    /// The linter rule, e.g. `ASSIGN-10`.
    public let rule: String
    public let text: String
    public let rtlName: String?
    public let hierarchy: String?
    /// The file as Vivado names it (no folder), and the line.
    public let file: String?
    public let line: Int?
}

/// What a linter run found: Vivado's summary table and every message.
public struct LintReport: Equatable, Sendable {
    public struct RuleCount: Equatable, Sendable {
        public let rule: String
        public let severity: String
        public let violations: Int
        public let waived: Int
    }

    public var rules: [RuleCount] = []
    public var messages: [LintMessage] = []
    /// False if the log never said the linter finished (it failed, or Vivado stopped first).
    public var finished = false

    public init() {}

    /// Reads the linter's part of a Vivado log. Messages look like
    /// `WARNING: [Synth 37-125] [ASSIGN-10]Some bits in IO 'sw' are not read. ...` followed by
    /// `RTL Name 'sw', Hierarchy 'demo_top', File 'demo_top.v', Line 15.`
    public static func parse(log: String) -> LintReport {
        var report = LintReport()
        // Split on whole line breaks: Windows writes CR LF, which `.newlines` would split twice, leaving empty lines
        // between a message and its location.
        let lines = log.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var inTable = false
        for (k, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("| Rule ID") { inTable = true; continue }
            if inTable {
                if trimmed.hasPrefix("+") { continue }
                if trimmed.hasPrefix("|") {
                    let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.count >= 4 {
                        report.rules.append(RuleCount(rule: cells[0], severity: cells[1], violations: Int(cells[2]) ?? 0, waived: Int(cells[3]) ?? 0))
                    }
                    continue
                }
                inTable = false                       // and read this line as usual
            }
            if trimmed.contains("Linter Run Finished") { report.finished = true }
            guard let severityEnd = trimmed.range(of: ": [Synth 37-"),
                  let ruleOpen = trimmed.range(of: "] [", range: severityEnd.upperBound..<trimmed.endIndex),
                  let ruleClose = trimmed.range(of: "]", range: ruleOpen.upperBound..<trimmed.endIndex) else { continue }
            let severity = String(trimmed[..<severityEnd.lowerBound])
            let rule = String(trimmed[ruleOpen.upperBound..<ruleClose.lowerBound])
            let text = trimmed[ruleClose.upperBound...].trimmingCharacters(in: .whitespaces)
            var rtlName: String?, hierarchy: String?, file: String?, lineNumber: Int?
            if k + 1 < lines.count, lines[k + 1].contains("RTL Name") || lines[k + 1].contains("File '") {
                let detail = lines[k + 1]
                func quoted(after key: String) -> String? {
                    guard let start = detail.range(of: key + " '"), let end = detail.range(of: "'", range: start.upperBound..<detail.endIndex) else { return nil }
                    return String(detail[start.upperBound..<end.lowerBound])
                }
                rtlName = quoted(after: "RTL Name")
                hierarchy = quoted(after: "Hierarchy")
                file = quoted(after: "File")
                if let l = detail.range(of: "Line ") {
                    lineNumber = Int(detail[l.upperBound...].prefix { $0.isNumber })
                }
            }
            report.messages.append(LintMessage(severity: severity, rule: rule, text: text, rtlName: rtlName, hierarchy: hierarchy,
                                               file: file, line: lineNumber))
        }
        return report
    }
}
