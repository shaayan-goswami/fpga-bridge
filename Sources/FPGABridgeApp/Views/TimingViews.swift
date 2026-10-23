import AppKit
import FPGABridgeCore
import SwiftUI

// MARK: Timing window

/// Vivado's Timing window, the result of Report Timing Summary: a tree of pages on the left (General Information,
/// Timer Settings, Design Timing Summary, Clock Summary, Check Timing, and each path group's Setup and Hold paths)
/// and the page on the right. Everything comes from what the build saved, so it works with the build machine asleep.
struct TimingPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var state: TimingWindowState

    var body: some View {
        if let stage = model.timingStage {
            let paths = model.timingPaths(for: stage)
            let report = model.timingSummaryReport(for: stage).map(state.summary(of:))
            HStack(spacing: 0) {
                TimingTree(stage: stage, paths: paths, summary: report?.summary, sections: report?.sections)
                    .frame(width: 250)
                Divider()
                page(stage: stage, paths: paths, summary: report?.summary, sections: report?.sections)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.surface)
        } else {
            ContentUnavailableView {
                Label("No Timing Results", systemImage: "timer")
            } description: {
                Text("Open the synthesized or implemented design to see its timing. The elaborated design isn't timed.")
            }
            .background(Theme.surface)
        }
    }

    @ViewBuilder
    private func page(stage: DesignStage, paths: TimingPathSet, summary: TimingSummary?, sections: TimingSummarySections?) -> some View {
        switch state.page {
        case .generalInformation:
            if let sections, !sections.generalInformation.isEmpty {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                        InfoRow(label: "Stage", value: stage.title)
                        ForEach(sections.generalInformation, id: \.name) { InfoRow(label: $0.name, value: $0.value) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                missingSummary(stage)
            }
        case .timerSettings:
            if let text = sections?.timerSettings, !text.isEmpty { TimingText(text: text) } else { missingSummary(stage) }
        case .designTimingSummary:
            if let summary { DesignTimingSummaryPage(stage: stage, summary: summary, paths: paths) } else { missingSummary(stage) }
        case .clockSummary:
            if let sections, !sections.clocks.isEmpty {
                Table(sections.clocks.map(ClockRow.init)) {
                    TableColumn("Name") { Text($0.name).font(.callout.monospaced()) }
                    TableColumn("Waveform (ns)") { Text($0.waveform).font(.callout.monospaced()) }
                    TableColumn("Period (ns)") { Text($0.period).monospacedDigit() }
                    TableColumn("Frequency (MHz)") { Text($0.frequency).monospacedDigit() }
                }
            } else if let text = sections?.clockSummary, !text.isEmpty {
                TimingText(text: text)
            } else {
                missingSummary(stage)
            }
        case .checkTiming:
            if let text = sections?.checkTiming, !text.isEmpty { TimingText(text: text) } else { missingSummary(stage) }
        case .category(let category):
            CategoryPage(stage: stage, category: category, paths: paths)
        case .paths(let group, let check):
            if paths.isEmpty {
                missingPaths(stage)
            } else {
                TimingPathsTable(stage: stage, title: "\(group.title) ▸ \(check.title)", paths: paths.paths(in: group, check: check))
            }
        }
    }

    private func missingSummary(_ stage: DesignStage) -> some View {
        ContentUnavailableView {
            Label("No Timing Summary", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("The last build didn't write the \(stage.title.lowercased())'s timing summary. Run \(stage == .impl ? "implementation" : "synthesis") again to produce it.")
        }
    }

    private func missingPaths(_ stage: DesignStage) -> some View {
        ContentUnavailableView {
            Label("No Timing Paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        } description: {
            Text("The last build didn't save the \(stage.title.lowercased())'s timing paths. Builds save them from this version on: run \(stage == .impl ? "implementation" : "synthesis") again.")
        }
    }
}

private struct ClockRow: Identifiable {
    let name: String
    let waveform: String
    let period: String
    let frequency: String
    var id: String { name }

    init(_ clock: (name: String, waveform: String, period: String, frequency: String)) {
        name = clock.name; waveform = clock.waveform; period = clock.period; frequency = clock.frequency
    }
}

/// A section of the timing summary report, as Vivado prints it.
private struct TimingText: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: Tree

/// The Timing window's tree. Pages the build doesn't save (pulse width per pin, user-ignored and unconstrained paths)
/// stay in the tree, greyed, with the reason, as Vivado's items would be there.
private struct TimingTree: View {
    @EnvironmentObject private var state: TimingWindowState
    let stage: DesignStage
    let paths: TimingPathSet
    let summary: TimingSummary?
    let sections: TimingSummarySections?
    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: Binding(get: { state.page }, set: { if let page = $0 { state.page = page } })) {
            Text(stage.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            row("General Information", page: .generalInformation)
            row("Timer Settings", page: .timerSettings)
            row("Design Timing Summary", page: .designTimingSummary, status: summary.map { $0.constraintsMet ? nil : Accent.error } ?? nil)
            row("Clock Summary" + (sections.map { " (\($0.clocks.count))" } ?? ""), page: .clockSummary)
            row("Check Timing" + (sections.map { " (\($0.checkTimingProblems))" } ?? ""), page: .checkTiming,
                status: (sections?.checkTimingProblems ?? 0) > 0 ? Accent.warning : nil)
            ForEach(TimingPathCategory.allCases, id: \.self) { category in
                let groups = paths.groups(in: category)
                disclosure(category.rawValue, id: category.rawValue, hasChildren: !groups.isEmpty, depth: 0)
                    .tag(TimingPage.category(category))
                if !collapsed.contains(category.rawValue) {
                    ForEach(groups) { group in
                        disclosure(group.title, id: group.id, hasChildren: true, depth: 1)
                            .selectionDisabled()
                        if !collapsed.contains(group.id) {
                            ForEach(TimingCheck.allCases, id: \.self) { check in checkRow(group, check) }
                            unavailable("Pulse Width", depth: 2,
                                        reason: "Pulse width is checked per clock pin; the build saves only its totals, in Design Timing Summary")
                        }
                    }
                }
            }
            unavailable("User Ignored Paths", depth: 0, reason: "The build doesn't save paths that set_false_path or set_clock_groups ignore")
            unavailable("Unconstrained Paths", depth: 0,
                        reason: "The build saves only constrained paths. Check Timing lists the ports and pins without constraints")
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
    }

    private func row(_ title: String, page: TimingPage, status: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            if let status { Circle().fill(status).frame(width: 6, height: 6) }
        }
        .font(.callout)
        .tag(page)
    }

    private func disclosure(_ title: String, id: String, hasChildren: Bool, depth: Int) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 12, height: 1)
            Button {
                if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed.contains(id) || !hasChildren ? 0 : 90))
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .opacity(hasChildren ? 1 : 0)
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
    }

    private func checkRow(_ group: TimingPathGroup, _ check: TimingCheck) -> some View {
        let these = paths.paths(in: group, check: check)
        let worst = these.compactMap(\.slack).min()
        return HStack(spacing: 6) {
            Color.clear.frame(width: 40, height: 1)
            Text(check.title)
            Spacer(minLength: 4)
            Text(worst.map { "\(formatNs($0)) ns" } ?? "")
                .monospacedDigit()
                .foregroundStyle((worst ?? 0) < 0 ? Accent.error : .secondary)
            Text("(\(these.count))").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
        .tag(TimingPage.paths(group, check))
    }

    private func unavailable(_ title: String, depth: Int, reason: String) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 12 + 16, height: 1)
            Text(title).lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.tertiary)
        .help(reason)
        .selectionDisabled()
    }
}

// MARK: Design Timing Summary

/// Vivado's Design Timing Summary page: Setup, Hold and Pulse Width side by side, and the verdict. The worst slacks
/// are links to the worst path, as in Vivado.
private struct DesignTimingSummaryPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var state: TimingWindowState
    let stage: DesignStage
    let summary: TimingSummary
    let paths: TimingPathSet

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Side by side as in Vivado when the pane is wide enough, else Pulse Width under the other two.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 32) { setup; hold; pulseWidth }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 32) { setup; hold }
                        pulseWidth
                    }
                    VStack(alignment: .leading, spacing: 14) { setup; hold; pulseWidth }
                }
                Group {
                    if !summary.isTimed {
                        Text("There are no user specified timing constraints.").foregroundStyle(Accent.warning)
                    } else if summary.constraintsMet {
                        Text("All user specified timing constraints are met.").foregroundStyle(Accent.success)
                    } else {
                        Text("Timing constraints are not met.").foregroundStyle(Accent.error)
                    }
                }
                .font(.callout.weight(.medium))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var setup: some View {
        column("Setup", [
            ("Worst Negative Slack (WNS):", ns(summary.wns), worst(.setup)),
            ("Total Negative Slack (TNS):", ns(summary.tns), nil),
            ("Number of Failing Endpoints:", count(summary.tnsFailingEndpoints), nil),
            ("Total Number of Endpoints:", count(summary.tnsTotalEndpoints), nil),
        ], failing: (summary.wns ?? 0) < 0)
    }

    private var hold: some View {
        column("Hold", [
            ("Worst Hold Slack (WHS):", ns(summary.whs), worst(.hold)),
            ("Total Hold Slack (THS):", ns(summary.ths), nil),
            ("Number of Failing Endpoints:", count(summary.thsFailingEndpoints), nil),
            ("Total Number of Endpoints:", count(summary.thsTotalEndpoints), nil),
        ], failing: (summary.whs ?? 0) < 0)
    }

    private var pulseWidth: some View {
        column("Pulse Width", [
            ("Worst Pulse Width Slack (WPWS):", ns(summary.wpws), nil),
            ("Total Pulse Width Negative Slack (TPWS):", ns(summary.tpws), nil),
            ("Number of Failing Endpoints:", count(summary.tpwsFailingEndpoints), nil),
            ("Total Number of Endpoints:", count(summary.tpwsTotalEndpoints), nil),
        ], failing: (summary.wpws ?? 0) < 0)
    }

    private func column(_ title: String, _ rows: [(String, String, TimingPath?)], failing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(rows, id: \.0) { label, value, path in
                    GridRow {
                        Text(label).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        if let path {
                            Button("\(value)") { show(path) }
                                .buttonStyle(.link)
                                .foregroundStyle(failing ? Accent.error : Accent.active)
                                .help("Show the worst path")
                        } else {
                            Text(value).foregroundStyle(failing && (label.hasPrefix("Worst") || label.contains("Failing") && value != "0") ? Accent.error : .primary)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
        }
    }

    private func worst(_ check: TimingCheck) -> TimingPath? {
        paths.paths(check).filter { $0.slack != nil }.min { ($0.slack ?? 0, $0.id) < ($1.slack ?? 0, $1.id) }
    }

    private func show(_ path: TimingPath) {
        state.page = .paths(TimingPathGroup.of(path), path.check)
        model.selectTimingPath(path, in: stage)
    }

    private func ns(_ value: Double?) -> String { value.map { "\(formatNs($0)) ns" } ?? "NA" }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "NA" }
}

// MARK: Path group table

/// Selecting Intra-Clock Paths (or another category) lists its groups with their worst slacks.
private struct CategoryPage: View {
    @EnvironmentObject private var state: TimingWindowState
    let stage: DesignStage
    let category: TimingPathCategory
    let paths: TimingPathSet

    private struct Row: Identifiable {
        let group: TimingPathGroup
        let setup: [TimingPath]
        let hold: [TimingPath]
        var id: String { group.id }
    }

    var body: some View {
        let rows = paths.groups(in: category).map {
            Row(group: $0, setup: paths.paths(in: $0, check: .setup), hold: paths.paths(in: $0, check: .hold))
        }
        if rows.isEmpty {
            ContentUnavailableView(paths.isEmpty ? "No Timing Paths" : "No \(category.rawValue)", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                   description: Text(paths.isEmpty ? "The last build didn't save timing paths. Run \(stage == .impl ? "implementation" : "synthesis") again."
                                                     : "This design has no paths of this kind."))
        } else {
            Table(rows) {
                TableColumn(category == .intraClock ? "Clock" : "Group") { Text($0.group.title).font(.callout.monospaced()) }
                TableColumn("Setup WNS (ns)") { row in slack(row.setup) }
                TableColumn("Failing Setup Paths") { row in Text("\(row.setup.filter(\.isFailing).count) of \(row.setup.count)").monospacedDigit() }
                TableColumn("Hold WHS (ns)") { row in slack(row.hold) }
                TableColumn("Failing Hold Paths") { row in Text("\(row.hold.filter(\.isFailing).count) of \(row.hold.count)").monospacedDigit() }
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) { state.page = .paths(row.group, .setup) }
            }
        }
    }

    private func slack(_ paths: [TimingPath]) -> some View {
        let worst = paths.compactMap(\.slack).min()
        return Text(formatNs(worst, missing: "")).monospacedDigit().foregroundStyle((worst ?? 0) < 0 ? Accent.error : .primary)
    }
}

// MARK: Paths table

/// The paths of one group and check, with Vivado's columns. Selecting a path selects it in every design window;
/// double-clicking shows its report in Properties; Schematic (F4) draws just its cells.
struct TimingPathsTable: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var state: TimingWindowState
    let stage: DesignStage
    let title: String
    let paths: [TimingPath]
    @State private var sortOrder = [TimingPathOrder(.slack)]
    @State private var selection: Set<Int> = []

    var body: some View {
        let rows = paths.sorted(using: sortOrder)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                let failing = paths.filter(\.isFailing).count
                if failing > 0 { Pill(text: "\(failing) failing", color: Accent.error, symbol: "exclamationmark.triangle.fill") }
                Spacer()
                Button { schematic() } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                    .buttonStyle(.borderless)
                    .disabled(selectedPath == nil || model.designs[stage]?.hasConnectivity != true)
                    .help("Schematic (F4): draw the selected path's cells")
                Text("\(paths.count) path\(paths.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                Group {
                    TableColumn("Name", sortUsing: TimingPathOrder(.name)) { Text($0.name) }.width(min: 56, ideal: 64)
                    TableColumn("Slack", sortUsing: TimingPathOrder(.slack)) { path in
                        Text(formatNs(path.slack, missing: "inf")).monospacedDigit().foregroundStyle(path.isFailing ? Accent.error : .primary)
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Levels", sortUsing: TimingPathOrder(.levels)) { Text($0.logicLevels.map(String.init) ?? "").monospacedDigit() }
                        .width(min: 40, ideal: 46)
                    TableColumn("Routes", sortUsing: TimingPathOrder(.routes)) { Text("\($0.routes)").monospacedDigit() }.width(min: 40, ideal: 46)
                    TableColumn("High Fanout", sortUsing: TimingPathOrder(.fanout)) { Text($0.maxFanout.map(String.init) ?? "").monospacedDigit() }
                        .width(min: 50, ideal: 70)
                    TableColumn("From", sortUsing: TimingPathOrder(.from)) { Text($0.startPoint).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                        .width(min: 100, ideal: 180)
                    TableColumn("To", sortUsing: TimingPathOrder(.to)) { Text($0.endPoint).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                        .width(min: 100, ideal: 180)
                    TableColumn("Total Delay", sortUsing: TimingPathOrder(.totalDelay)) { Text(formatNs($0.dataPathDelay)).monospacedDigit() }
                        .width(min: 56, ideal: 70)
                    TableColumn("Logic Delay", sortUsing: TimingPathOrder(.logicDelay)) { Text(formatNs($0.logicDelay)).monospacedDigit() }
                        .width(min: 56, ideal: 70)
                    TableColumn("Net Delay", sortUsing: TimingPathOrder(.netDelay)) { Text(formatNs($0.netDelay)).monospacedDigit() }
                        .width(min: 56, ideal: 70)
                }
                Group {
                    TableColumn("Requirement", sortUsing: TimingPathOrder(.requirement)) { Text(formatNs($0.requirement, missing: "inf")).monospacedDigit() }
                        .width(min: 60, ideal: 76)
                    TableColumn("Source Clock", sortUsing: TimingPathOrder(.sourceClock)) { Text($0.startClock) }.width(min: 60, ideal: 80)
                    TableColumn("Destination Clock", sortUsing: TimingPathOrder(.destinationClock)) { Text($0.endClock) }.width(min: 60, ideal: 80)
                    TableColumn("Exception", sortUsing: TimingPathOrder(.exception)) { Text($0.exception) }.width(min: 50, ideal: 70)
                    TableColumn("Clock Uncertainty", sortUsing: TimingPathOrder(.uncertainty)) { Text(formatNs($0.uncertainty)).monospacedDigit() }
                        .width(min: 60, ideal: 90)
                }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                menu(ids)
            } primaryAction: { ids in
                // Double-click: the path's report, in Properties.
                guard let id = ids.first, let path = paths.first(where: { $0.id == id }) else { return }
                model.selectTimingPath(path, in: stage)
                state.propertiesView = .report
            }
            .onChange(of: selection) { _, ids in
                guard ids.count == 1, let id = ids.first, let path = paths.first(where: { $0.id == id }),
                      model.shownTimingPath?.id != id else { return }
                model.selectTimingPath(path, in: stage)
            }
            .onAppear { syncSelection() }
            .onChange(of: model.timingWindow.selectedPath) { _, _ in syncSelection() }
        }
    }

    private var selectedPath: TimingPath? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return paths.first { $0.id == id }
    }

    /// Shows the selected path's row when it was chosen elsewhere (the worst-slack link).
    private func syncSelection() {
        guard let chosen = model.timingWindow.selectedPath, chosen.stage == stage, paths.contains(where: { $0.id == chosen.id }),
              selection != [chosen.id] else { return }
        selection = [chosen.id]
    }

    private func schematic() {
        if let path = selectedPath { model.schematicOfTimingPath(path, in: stage) }
    }

    @ViewBuilder private func menu(_ ids: Set<Int>) -> some View {
        let chosen = paths.filter { ids.contains($0.id) }
        if let path = chosen.first, chosen.count == 1 {
            Button("Path Properties") {
                model.selectTimingPath(path, in: stage)
                state.propertiesView = .general
            }
            Button("View Path Report") {
                model.selectTimingPath(path, in: stage)
                state.propertiesView = .report
            }
            Button("Schematic") { model.schematicOfTimingPath(path, in: stage) }
                .disabled(model.designs[stage]?.hasConnectivity != true)
            Divider()
            Button("Select Startpoint") { selectEnd(path.startPoint, isPort: path.startIsPort) }
            Button("Select Endpoint") { selectEnd(path.endPoint, isPort: path.endIsPort) }
            Divider()
        }
        if !chosen.isEmpty {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.map(Self.copyLine).joined(separator: "\n"), forType: .string)
            }
        }
    }

    private func selectEnd(_ name: String, isPort: Bool) {
        model.select(isPort ? .port(name) : .pin(name))
    }

    /// A row as Vivado copies it: the columns separated by tabs.
    static func copyLine(_ p: TimingPath) -> String {
        [p.name, formatNs(p.slack, missing: "inf"), p.logicLevels.map(String.init) ?? "", "\(p.routes)", p.maxFanout.map(String.init) ?? "",
         p.startPoint, p.endPoint, formatNs(p.dataPathDelay), formatNs(p.logicDelay), formatNs(p.netDelay),
         formatNs(p.requirement, missing: "inf"), p.startClock, p.endClock, p.exception, formatNs(p.uncertainty)].joined(separator: "\t")
    }
}

// MARK: Path Properties

/// Vivado's Path Properties window: General (the report's summary and the clock and data path tables), Properties
/// (what `get_timing_paths` says about the path) and Report (`report_timing` text).
struct TimingPathProperties: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var state: TimingWindowState
    let design: DesignSnapshot
    let path: TimingPath

    var body: some View {
        let report = design.timing.report(for: path.id)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Path Properties").font(.headline)
                Spacer()
                Button { model.schematicOfTimingPath(path, in: design.stage) } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                    .buttonStyle(.borderless)
                    .disabled(!design.hasConnectivity)
                    .help("Schematic (F4): draw the path's cells")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            HStack(spacing: 6) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(path.isFailing ? Accent.error : Accent.active)
                Text(path.name).font(.callout.weight(.medium))
                Text("\(path.check.title), slack \(formatNs(path.slack, missing: "inf")) ns")
                    .font(.callout)
                    .foregroundStyle(path.isFailing ? Accent.error : .secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider()
            Group {
                switch state.propertiesView {
                case .general: general(report)
                case .properties: properties
                case .report:
                    if let report { ScrollView([.vertical, .horizontal]) { reportText(report.text) } } else { noReport }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 14) {
                ForEach(TimingPathPropertiesView.allCases) { item in
                    Button { state.propertiesView = item } label: {
                        Text(item.rawValue)
                            .font(.caption.weight(state.propertiesView == item ? .semibold : .regular))
                            .foregroundStyle(state.propertiesView == item ? .primary : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(state.propertiesView == item ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
    }

    private var noReport: some View {
        Text("The build saved the report of the first \(DesignDump.maxTimingReports) paths only.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func reportText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: General

    private func general(_ report: TimingPathReport?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Summary").font(.callout.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    InfoRow(label: "Name", value: path.name)
                    GridRow {
                        Text("Slack").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("\(formatNs(path.slack, missing: "inf")) ns").foregroundStyle(path.isFailing ? Accent.error : .primary).monospacedDigit()
                    }
                    .font(.callout)
                    GridRow {
                        Text("Source").foregroundStyle(.secondary)
                        ObjectLink(ref: path.startIsPort ? .port(path.startPoint) : .pin(path.startPoint))
                    }
                    .font(.callout)
                    GridRow {
                        Text("Destination").foregroundStyle(.secondary)
                        ObjectLink(ref: path.endIsPort ? .port(path.endPoint) : .pin(path.endPoint))
                    }
                    .font(.callout)
                    InfoRow(label: "Path Group", value: path.group)
                    InfoRow(label: "Path Type", value: item(report, "Path Type") ?? "\(path.check == .setup ? "Setup (Max" : "Hold (Min") at \(path.corner) Process Corner)")
                    InfoRow(label: "Requirement", value: path.requirement.map { "\(formatNs($0)) ns" } ?? "")
                    InfoRow(label: "Data Path Delay", value: item(report, "Data Path Delay") ?? path.dataPathDelay.map { "\(formatNs($0)) ns" } ?? "")
                    InfoRow(label: "Logic Levels", value: item(report, "Logic Levels") ?? path.logicLevels.map(String.init) ?? "")
                    InfoRow(label: "Clock Path Skew", value: item(report, "Clock Path Skew") ?? path.skew.map { "\(formatNs($0)) ns" } ?? "")
                    InfoRow(label: "Clock Uncertainty", value: item(report, "Clock Uncertainty") ?? path.uncertainty.map { "\(formatNs($0)) ns" } ?? "")
                    if let input = item(report, "Input Delay") { InfoRow(label: "Input Delay", value: input) }
                    if let output = item(report, "Output Delay") { InfoRow(label: "Output Delay", value: output) }
                }
                if let report {
                    steps("Source Clock Path", report.sourceClockPath)
                    steps("Data Path", report.dataPath)
                    steps("Destination Clock Path", report.destinationClockPath)
                } else {
                    Text("The build saved the report of the first \(DesignDump.maxTimingReports) paths only, so the delay tables aren't here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func item(_ report: TimingPathReport?, _ name: String) -> String? {
        report?.summary.first { $0.name == name }?.value
    }

    @ViewBuilder private func steps(_ title: String, _ steps: [TimingPathReport.Step]) -> some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow {
                            Text("Delay Type"); Text("Incr (ns)"); Text("Path (ns)"); Text("Location"); Text("Netlist Resource(s)")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            GridRow {
                                Text(step.delayType).lineLimit(1)
                                Text(step.increment.map { formatNs($0) } ?? "").monospacedDigit().gridColumnAlignment(.trailing)
                                Text(step.total.map { formatNs($0) } ?? "").monospacedDigit().gridColumnAlignment(.trailing)
                                Text(step.location).foregroundStyle(.secondary)
                                resource(step)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder private func resource(_ step: TimingPathReport.Step) -> some View {
        let label = (step.edge.isEmpty ? "" : step.edge + "  ") + step.resource
        if let ref = step.object, design.contains(ref) {
            Button(label) { model.select(ref) }
                .buttonStyle(.link)
                .font(.caption.monospaced())
                .lineLimit(1)
                .help("Select \(ref.name)")
        } else {
            Text(label).font(.caption.monospaced()).lineLimit(1)
        }
    }

    // MARK: Properties

    private var properties: some View {
        let rows: [(String, String)] = [
            ("ARRIVAL_TIME", formatNs(path.arrivalTime)), ("CLASS", "timing_path"), ("CORNER", path.corner),
            ("DATAPATH_DELAY", formatNs(path.dataPathDelay)), ("DATAPATH_LOGIC_DELAY", formatNs(path.logicDelay)),
            ("DATAPATH_NET_DELAY", formatNs(path.netDelay)), ("DELAY_TYPE", path.check.delayType),
            ("ENDPOINT_CLOCK", path.endClock), ("ENDPOINT_PIN", path.endPoint), ("EXCEPTION", path.exception),
            ("GROUP", path.group), ("LOGIC_LEVELS", path.logicLevels.map(String.init) ?? ""),
            ("MAX_FANOUT", path.maxFanout.map(String.init) ?? ""), ("NAME", "\(path.startPoint) --> \(path.endPoint)"),
            ("REQUIRED_TIME", formatNs(path.requiredTime)), ("REQUIREMENT", formatNs(path.requirement)),
            ("SKEW", formatNs(path.skew)), ("SLACK", formatNs(path.slack)), ("STARTPOINT_CLOCK", path.startClock),
            ("STARTPOINT_PIN", path.startPoint), ("UNCERTAINTY", formatNs(path.uncertainty)),
        ]
        return ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(rows, id: \.0) { name, value in
                    GridRow {
                        Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
