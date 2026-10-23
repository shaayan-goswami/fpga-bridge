import Foundation

/// What a finished build says about the design, read from the reports in `build/`.
/// A missing or unreadable report is reported in `notes` and never fails the build.
public struct BuildSummary: Equatable, Sendable {
    public var timing: TimingSummary?
    public var utilization: UtilizationSummary?
    public var notes: [String]
    /// The implemented design's worst paths, which the build saves with the design data. Nil when it didn't.
    public var timingPaths: TimingPathSet? = nil

    public static let timingReport = "timing_summary.rpt"
    /// How many failing paths of each check `render` lists by default.
    public static let failingPathsShown = 10
    public static let utilizationReport = "utilization.rpt"

    public static func load(from directory: URL) -> BuildSummary {
        var summary = BuildSummary(timing: nil, utilization: nil, notes: [])

        switch read(timingReport, in: directory, parse: TimingSummary.parse) {
        case .success(let timing): summary.timing = timing
        case .failure(let error): summary.notes.append("\(timingReport): \(error.userMessage)")
        }
        switch read(utilizationReport, in: directory, parse: UtilizationSummary.parse) {
        case .success(let utilization): summary.utilization = utilization
        case .failure(let error): summary.notes.append("\(utilizationReport): \(error.userMessage)")
        }
        let paths = TimingPathSet.load(stage: .impl, from: directory)
        if !paths.isEmpty { summary.timingPaths = paths }
        return summary
    }

    private static func read<T>(_ name: String, in directory: URL, parse: (String) throws -> T) -> Result<T, ReportError> {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else {
            return .failure(.notFound(name))
        }
        do { return .success(try parse(text)) } catch let error as ReportError { return .failure(error) }
        catch { return .failure(.unparseable(name, error.localizedDescription)) }
    }

    /// Human-readable summary, one line per topic. When timing isn't met, the worst failing paths follow the timing
    /// line, up to `maxPaths` for setup and for hold.
    public func render(maxPaths: Int = BuildSummary.failingPathsShown) -> String {
        var lines: [String] = []
        if let timing {
            lines.append(BuildSummary.timingLine(timing))
            if timing.isTimed, !timing.constraintsMet { lines += failingPathLines(timing, maxPaths: maxPaths) }
        }
        if let utilization { lines.append(BuildSummary.resourceLine(utilization)) }
        lines += notes.map { "Note: \($0)" }
        return lines.joined(separator: "\n")
    }

    static func timingLine(_ t: TimingSummary) -> String {
        let status = !t.isTimed ? "UNCONSTRAINED (no clocks or timing constraints found)" : t.constraintsMet ? "MET" : "NOT MET"
        var parts = ["Timing     \(status)"]

        var setup = "setup WNS \(ns(t.wns))"
        if let failing = t.tnsFailingEndpoints, failing > 0 {
            setup += " (TNS \(ns(t.tns)), \(failing) of \(t.tnsTotalEndpoints.map(String.init) ?? "?") endpoints failing)"
        }
        var hold = "hold WHS \(ns(t.whs))"
        if let failing = t.thsFailingEndpoints, failing > 0 {
            hold += " (THS \(ns(t.ths)), \(failing) of \(t.thsTotalEndpoints.map(String.init) ?? "?") endpoints failing)"
        }
        if !t.isTimed { return parts[0] }
        parts += [setup, hold]
        if let failing = t.tpwsFailingEndpoints, failing > 0 { parts.append("pulse width: \(failing) endpoints failing") }
        return parts.joined(separator: "   ")
    }

    /// The worst failing setup and hold paths, worst first: slack, from, to, then the group, logic levels, data path
    /// delay and requirement, as Vivado's Timing window lists them.
    func failingPathLines(_ t: TimingSummary, maxPaths: Int) -> [String] {
        guard let timingPaths else {
            return ["           The failing paths weren't saved by this build. Build again to list them."]
        }
        var lines: [String] = []
        for check in TimingCheck.allCases {
            let failing = timingPaths.failing(check)
            guard !failing.isEmpty, maxPaths > 0 else { continue }
            // The summary counts every failing endpoint; the build saved at most 100 paths per group.
            let total = max(failing.count, (check == .setup ? t.tnsFailingEndpoints : t.thsFailingEndpoints) ?? 0)
            let shown = failing.prefix(maxPaths)
            lines.append("Failing \(check.title.lowercased()) paths, worst first" + (total > shown.count ? " (\(shown.count) of \(total)):" : ":"))
            for path in shown {
                var details = [path.group]
                if let levels = path.logicLevels { details.append("\(levels) logic level\(levels == 1 ? "" : "s")") }
                if let delay = path.dataPathDelay { details.append("data path \(String(format: "%.3f", delay)) ns") }
                if let requirement = path.requirement { details.append("requirement \(String(format: "%.3f", requirement)) ns") }
                let slack = BuildSummary.ns(path.slack)
                lines.append("  \(String(repeating: " ", count: max(0, 10 - slack.count)))\(slack)  \(path.startPoint) -> \(path.endPoint)  (\(details.joined(separator: ", ")))")
            }
        }
        return lines
    }

    static func resourceLine(_ u: UtilizationSummary) -> String {
        let shown: [ResourceUsage.Kind] = [.lut, .ff, .bram, .dsp]
        let items = shown.compactMap { kind -> String? in
            guard let r = u.usage(kind) else { return nil }
            return "\(kind.rawValue) \(count(r.used))/\(count(r.available)) (\(String(format: "%.1f", r.percent))%)"
        }
        return "Resources  " + items.joined(separator: "   ")
    }

    /// 12 prints as "12", 2.5 as "2.5".
    private static func count(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func ns(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%+.3f ns", value)
    }
}
