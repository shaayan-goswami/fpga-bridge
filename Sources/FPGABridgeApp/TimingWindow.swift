import FPGABridgeCore
import Foundation

/// A page of Vivado's Timing window, as its tree on the left lists them.
enum TimingPage: Hashable {
    case generalInformation, timerSettings, designTimingSummary, clockSummary, checkTiming
    /// A category's table of path groups (Intra-Clock Paths, ...).
    case category(TimingPathCategory)
    /// The paths of one group for one check (sys_clk ▸ Setup).
    case paths(TimingPathGroup, TimingCheck)
}

/// A timing path selected in the Timing window, and what selecting it selected in the design windows. While the design
/// selection is still exactly that, the path is the selected object: Properties shows Path Properties and Schematic
/// (F4) draws just the path's cells, as in Vivado.
struct TimingPathSelection: Equatable {
    let stage: DesignStage
    let id: Int
    let objects: [DesignObjectRef]
}

/// What the Timing window shows. Kept out of AppModel so the window's state lives in one place.
@MainActor
final class TimingWindowState: ObservableObject {
    @Published var page: TimingPage = .designTimingSummary
    @Published var selectedPath: TimingPathSelection?
    /// Which of the Path Properties views to show (General, Properties, Report).
    @Published var propertiesView: TimingPathPropertiesView = .general
    /// Parsed timing summaries by report, so the window doesn't read the text again on every redraw.
    private var summaries: [String: (summary: TimingSummary?, sections: TimingSummarySections)] = [:]

    func summary(of entry: ReportEntry) -> (summary: TimingSummary?, sections: TimingSummarySections) {
        let key = "\(entry.id)#\(entry.text.utf8.count)"
        if let cached = summaries[key] { return cached }
        let parsed = (try? TimingSummary.parse(entry.text), TimingSummarySections.parse(entry.text))
        summaries[key] = parsed
        return parsed
    }
}

enum TimingPathPropertiesView: String, CaseIterable, Identifiable {
    case general = "General"
    case properties = "Properties"
    case report = "Report"
    var id: String { rawValue }
}

extension AppModel {
    /// The design the Timing window is about: the open design, when it has been synthesized (the elaborated design has
    /// no timing).
    var timingStage: DesignStage? {
        guard let stage = activeDesign, stage != .rtl, designs[stage] != nil else { return nil }
        return stage
    }

    func timingPaths(for stage: DesignStage) -> TimingPathSet { designs[stage]?.timing ?? TimingPathSet() }

    /// The stage's `report_timing_summary`, which the build writes next to the paths.
    func timingSummaryReport(for stage: DesignStage) -> ReportEntry? {
        guard let file = DesignReportKind.timingSummary.fileName(for: stage) else { return nil }
        return reports.first { $0.fileName == file }
    }

    /// Whether the build left anything for the Timing window: the paths or the summary.
    func hasTimingResults(_ stage: DesignStage) -> Bool {
        !timingPaths(for: stage).isEmpty || timingSummaryReport(for: stage) != nil
    }

    /// Opens the Timing window for an open design, as Report Timing Summary does in Vivado.
    func showTimingWindow(_ stage: DesignStage) {
        if !isDesignOpen(stage) { open(.design(stage)) }
        designOpened(stage)
        consoleVisible = true
        consoleTab = .timing
        if case .paths(let group, _) = timingWindow.page, !timingPaths(for: stage).paths.contains(where: { TimingPathGroup.of($0) == group }) {
            timingWindow.page = .designTimingSummary
        }
    }

    /// Selects a path: its cells, nets and ports become the design selection, so the Netlist and Schematic show it, and
    /// Properties shows the path itself.
    func selectTimingPath(_ path: TimingPath, in stage: DesignStage) {
        guard let design = designs[stage] else { return }
        if activeDesign != stage { open(.design(stage)) }
        let objects = path.objects.filter(design.contains)
        timingWindow.selectedPath = TimingPathSelection(stage: stage, id: path.id, objects: objects)
        select(objects)
    }

    /// The selected timing path, while the design selection is still what selecting it chose.
    var shownTimingPath: TimingPath? {
        guard let selection = timingWindow.selectedPath, selection.stage == activeDesign,
              selection.objects == designSelection else { return nil }
        return timingPaths(for: selection.stage).path(selection.id)
    }

    /// The cells a schematic of a path draws: its own, without module instances (the path goes through their contents).
    func cellsForSchematic(of path: TimingPath, in design: DesignSnapshot) -> Set<String> {
        Set(path.cells.filter { design.cell(named: $0)?.isPrimitive == true })
    }

    /// Schematic (F4) of a timing path: just the cells along it.
    func schematicOfTimingPath(_ path: TimingPath, in stage: DesignStage) {
        guard let design = designs[stage], design.hasConnectivity else { return }
        let cells = cellsForSchematic(of: path, in: design)
        guard !cells.isEmpty else { return }
        if shownTimingPath?.id != path.id { selectTimingPath(path, in: stage) }
        showSchematic(SchematicSpec(only: cells), in: stage)
    }
}

/// How the paths table sorts, by Vivado's columns. A path without a requirement has an infinite slack, as Vivado
/// shows it; ties keep the build's order.
struct TimingPathOrder: SortComparator, Hashable {
    enum Column: Hashable, Sendable {
        case name, slack, levels, routes, fanout, from, to, totalDelay, logicDelay, netDelay, requirement
        case sourceClock, destinationClock, exception, uncertainty
    }

    var column: Column
    var order: SortOrder = .forward

    init(_ column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    func compare(_ a: TimingPath, _ b: TimingPath) -> ComparisonResult {
        func by<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        func text(_ x: String, _ y: String) -> ComparisonResult { x.localizedStandardCompare(y) }
        var result: ComparisonResult
        switch column {
        case .name: result = by(a.id, b.id)
        case .slack: result = by(a.slack ?? .infinity, b.slack ?? .infinity)
        case .levels: result = by(a.logicLevels ?? 0, b.logicLevels ?? 0)
        case .routes: result = by(a.routes, b.routes)
        case .fanout: result = by(a.maxFanout ?? 0, b.maxFanout ?? 0)
        case .from: result = text(a.startPoint, b.startPoint)
        case .to: result = text(a.endPoint, b.endPoint)
        case .totalDelay: result = by(a.dataPathDelay ?? 0, b.dataPathDelay ?? 0)
        case .logicDelay: result = by(a.logicDelay ?? 0, b.logicDelay ?? 0)
        case .netDelay: result = by(a.netDelay ?? 0, b.netDelay ?? 0)
        case .requirement: result = by(a.requirement ?? .infinity, b.requirement ?? .infinity)
        case .sourceClock: result = text(a.startClock, b.startClock)
        case .destinationClock: result = text(a.endClock, b.endClock)
        case .exception: result = text(a.exception, b.exception)
        case .uncertainty: result = by(a.uncertainty ?? 0, b.uncertainty ?? 0)
        }
        if order == .reverse {
            result = result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
        }
        return result == .orderedSame ? by(a.id, b.id) : result
    }
}

/// Nanoseconds the way Vivado's timing tables show them: three decimals (a slack without a requirement is `inf`).
func formatNs(_ value: Double?, missing: String = "") -> String {
    guard let value else { return missing }
    return String(format: "%.3f", value)
}

#if DEBUG
extension AppModel {
    /// FPGA_BRIDGE_TIMING_PATH=n: open the Timing window on path n, or on the Design Timing Summary for 0.
    func applyTimingScenario(_ stage: DesignStage) {
        guard let value = ProcessInfo.processInfo.environment["FPGA_BRIDGE_TIMING_PATH"], let id = Int(value) else { return }
        showTimingWindow(stage)
        guard let path = timingPaths(for: stage).path(id) else { return }
        timingWindow.page = .paths(TimingPathGroup.of(path), path.check)
        selectTimingPath(path, in: stage)
        if ProcessInfo.processInfo.environment["FPGA_BRIDGE_TIMING_SCHEMATIC"] != nil { schematicOfTimingPath(path, in: stage) }
    }
}
#endif
