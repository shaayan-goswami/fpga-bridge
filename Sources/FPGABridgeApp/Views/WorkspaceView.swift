import FPGABridgeCore
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabBar()
            Divider()
            Group {
                switch model.selectedTab {
                case .summary: ProjectSummaryView()
                case .file(let path): SourceEditorView(path: path)
                case .report(let id): ReportView(id: id)
                case .hardware: HardwareManagerView()
                case .design(let stage): DesignView(stage: stage)
                case .schematic(let stage): SchematicView(stage: stage)
                case .linter: LinterView()
                case .ipCatalog: IPCatalogView()
                case .templates: LanguageTemplatesView()
                case .simulation: SimulationView()
                case .waveform: WaveformView()
                case .blockDesign(let path): BlockDesignView(path: path).id(path)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WorkspaceTabBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(model.openTabs) { tab in
                        TabButton(tab: tab)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .barBackground()
    }
}

private struct TabButton: View {
    @EnvironmentObject private var model: AppModel
    let tab: WorkspaceTab
    @State private var hovering = false

    private var selected: Bool { model.selectedTab == tab }

    private var isDirty: Bool {
        if case .file(let path) = tab { return model.isDirty(path) }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.symbol(of: tab))
                .font(.caption)
                .foregroundStyle(selected ? Color.primary : .secondary)
            Text(model.title(of: tab))
                .lineLimit(1)
            if tab.isCloseable {
                Button { model.requestClose(tab) } label: {
                    ZStack {
                        // A dot instead of the close button marks a file with unsaved edits, as in Xcode.
                        if isDirty && !hovering {
                            Circle().fill(Color.primary.opacity(0.65)).frame(width: 7, height: 7)
                        } else {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .background(hovering ? Color.primary.opacity(0.1) : .clear, in: Circle().inset(by: -4))
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .opacity(selected || hovering || isDirty ? 1 : 0)
                .help(isDirty ? "Close (unsaved changes)" : "Close")
            }
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, tab.isCloseable ? 7 : 12)
        .frame(height: 28)
        .background {
            if !selected && hovering { Capsule().fill(Color.primary.opacity(0.06)) }
        }
        .glassWhenSelected(selected)
        .contentShape(Capsule())
        .onTapGesture { model.selectedTab = tab }
        .onHover { hovering = $0 }
    }
}

// MARK: Project Summary

/// Vivado's Project Summary: Settings and Design Runs on the left; Timing, Utilization and Power on the right.
/// Vivado's Project Summary: an Overview of the project's settings and each run's results (synthesis,
/// implementation, DRC, timing, utilization, power), and a Dashboard of gadgets.
struct ProjectSummaryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.overview
    @State private var implView = "Summary"
    @State private var timingView = "Setup"
    @State private var utilizationStage = DesignStage.impl
    @State private var utilizationAsGraph = true
    @State private var powerView = "Summary"

    enum Tab: String, CaseIterable { case overview = "Overview", dashboard = "Dashboard" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Project Summary").font(.title2.weight(.bold))
                    Switcher(options: Tab.allCases.map(\.rawValue), selection: Binding(get: { tab.rawValue }, set: { tab = Tab(rawValue: $0) ?? .overview }))
                    Spacer()
                }
                switch tab {
                case .overview: overview
                case .dashboard: dashboard
                }
            }
            .padding(24)
        }
        .background(Backdrop())
    }

    // MARK: Overview

    private var overview: some View {
        VStack(spacing: 16) {
            settingsCard
            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    runCard(.synthesis)
                    runCard(.implementation)
                }
                GridRow {
                    drcCard
                    timingCard
                }
                GridRow {
                    utilizationCard
                    powerCard
                }
            }
        }
    }

    private var settingsCard: some View {
        Card("Settings") {
            Button("Edit") { model.showSettings = true }.buttonStyle(.link)
        } content: {
            if let project = model.project {
                HStack(alignment: .top, spacing: 40) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        InfoRow(label: "Project name", value: project.name)
                        InfoRow(label: "Project location", value: model.projectURL?.deletingLastPathComponent().path ?? "")
                        InfoRow(label: "Product family", value: family(ofPart: project.part))
                        InfoRow(label: "Project part", value: partDescription(project))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        InfoRow(label: "Top module name", value: project.top)
                        InfoRow(label: "Target language", value: project.targetLanguage ?? "Verilog")
                        InfoRow(label: "Simulator language", value: "Mixed")
                        InfoRow(label: "Target simulator", value: "Icarus Verilog (on the Mac)")
                    }
                }
            }
        }
    }

    private func partDescription(_ project: Project) -> String {
        if let board = project.board.flatMap(BoardCatalog.lookup) { return "\(project.part) (\(board.displayName))" }
        return project.part
    }

    private func runCard(_ run: RunKind) -> some View {
        let state = model.runs[run] ?? RunState()
        let isImpl = run == .implementation
        return Card(isImpl ? "Implementation" : "Synthesis") {
            if isImpl { Switcher(options: ["Summary", "Route Status"], selection: $implView) }
        } content: {
            if isImpl && implView == "Route Status" {
                routeStatusContent
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        HStack(spacing: 5) { RunStatusIcon(state: state); Text(model.runStatusText(run)) }
                    }
                    GridRow {
                        Text("Messages").foregroundStyle(.secondary)
                        messagesLink(run)
                    }
                    InfoRow(label: "Part", value: model.project?.part ?? "")
                    GridRow {
                        Text("Strategy").foregroundStyle(.secondary)
                        Button(isImpl ? model.implementationStrategy : model.synthesisStrategy) { model.showSettings = true }.buttonStyle(.link)
                    }
                    InfoRow(label: "Report strategy", value: isImpl ? "Vivado Implementation Default Reports" : "Vivado Synthesis Default Reports")
                    InfoRow(label: isImpl ? "Incremental implementation" : "Incremental synthesis", value: "None")
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private func messagesLink(_ run: RunKind) -> some View {
        if let counts = model.messageCounts(run) {
            let parts = [(counts.errors, "error"), (counts.critical, "critical warning"), (counts.warnings, "warning")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            Button(parts.isEmpty ? "No errors or warnings" : parts.joined(separator: ", ")) {
                model.consoleVisible = true
                model.consoleTab = .messages
            }
            .buttonStyle(.link)
        } else {
            Text("—").foregroundStyle(.secondary).help("Messages appear after a run in this session")
        }
    }

    @ViewBuilder private var routeStatusContent: some View {
        if let route = model.routeStatus {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                InfoRow(label: "Logical nets", value: "\(route.logicalNets)")
                InfoRow(label: "Routable nets", value: "\(route.routableNets)")
                InfoRow(label: "Fully routed nets", value: "\(route.fullyRouted)")
                InfoRow(label: "Nets with routing errors", value: "\(route.routingErrors)")
            }
            .font(.callout)
            reportLink("Route Status Report", file: "route_status.rpt")
        } else {
            placeholder("Run Implementation to see routing.", action: "Run Implementation") { model.run(.implementation) }
        }
    }

    private var drcCard: some View {
        Card("DRC Violations") {
            EmptyView()
        } content: {
            if let drc = model.checks(.drc, at: .impl) {
                let parts = [("Error", "error"), ("Critical Warning", "critical warning"), ("Warning", "warning"), ("Advisory", "advisory")]
                    .map { (drc.count($0.0), $0.1) }.filter { $0.0 > 0 }
                HStack(spacing: 6) {
                    Text("Summary").foregroundStyle(.secondary)
                    if parts.isEmpty {
                        Label("No violations", systemImage: "checkmark.circle.fill").foregroundStyle(Accent.success)
                    } else {
                        Label(parts.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(drc.count("Error") > 0 ? Accent.error : Accent.warning)
                    }
                }
                .font(.callout)
                reportLink("Implemented DRC Report", file: "drc.rpt")
            } else {
                placeholder("Run Implementation to check the design rules.", action: "Run Implementation") { model.run(.implementation) }
            }
        }
    }

    private var timingCard: some View {
        Card("Timing") {
            Switcher(options: ["Setup", "Hold", "Pulse Width"], selection: $timingView)
        } content: {
            if let timing = model.timing {
                if timing.isTimed {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        switch timingView {
                        case "Hold":
                            slackRow("Worst Hold Slack (WHS)", timing.whs)
                            slackRow("Total Hold Slack (THS)", timing.ths)
                            InfoRow(label: "Number of Failing Endpoints", value: "\(timing.thsFailingEndpoints ?? 0)")
                            InfoRow(label: "Total Number of Endpoints", value: "\(timing.thsTotalEndpoints ?? 0)")
                        case "Pulse Width":
                            slackRow("Worst Pulse Width Slack (WPWS)", timing.wpws)
                            slackRow("Total Pulse Width Negative Slack (TPWS)", timing.tpws)
                            InfoRow(label: "Number of Failing Endpoints", value: "\(timing.tpwsFailingEndpoints ?? 0)")
                            InfoRow(label: "Total Number of Endpoints", value: "\(timing.tpwsTotalEndpoints ?? 0)")
                        default:
                            slackRow("Worst Negative Slack (WNS)", timing.wns)
                            slackRow("Total Negative Slack (TNS)", timing.tns)
                            InfoRow(label: "Number of Failing Endpoints", value: "\(timing.tnsFailingEndpoints ?? 0)")
                            InfoRow(label: "Total Number of Endpoints", value: "\(timing.tnsTotalEndpoints ?? 0)")
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                } else {
                    Label("No clocks or timing constraints were found, so nothing was timed.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Accent.warning)
                }
                reportLink("Implemented Timing Report", file: BuildSummary.timingReport)
            } else {
                placeholder("Run Implementation to see timing.", action: "Run Implementation") { model.run(.implementation) }
            }
        }
    }

    private func slackRow(_ label: String, _ value: Double?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.3f ns", $0) } ?? "NA")
                .foregroundStyle((value ?? 0) < 0 ? Accent.error : Color.primary)
        }
    }

    private var utilizationCard: some View {
        Card("Utilization") {
            HStack(spacing: 12) {
                Switcher(options: ["Post-Synthesis", "Post-Implementation"],
                         selection: Binding(get: { utilizationStage == .impl ? "Post-Implementation" : "Post-Synthesis" },
                                            set: { utilizationStage = $0 == "Post-Synthesis" ? .synth : .impl }))
            }
        } content: {
            if let utilization = model.utilization(at: utilizationStage) {
                Switcher(options: ["Graph", "Table"], selection: Binding(get: { utilizationAsGraph ? "Graph" : "Table" }, set: { utilizationAsGraph = $0 == "Graph" }))
                let rows = ResourceUsage.Kind.allCases.compactMap { utilization.usage($0) }
                if utilizationAsGraph {
                    VStack(spacing: 10) { ForEach(rows, id: \.kind) { ResourceBar(usage: $0) } }
                } else {
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow { Text("Resource"); Text("Utilization"); Text("Available"); Text("Utilization %") }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(rows, id: \.kind) { u in
                            GridRow {
                                Text(u.kind.rawValue).gridColumnAlignment(.leading)
                                Text(formatCount(u.used)); Text("\(Int(u.available))"); Text(String(format: "%.2f", u.percent))
                            }
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            } else {
                placeholder("Run \(utilizationStage == .impl ? "Implementation" : "Synthesis") to see resource use.",
                            action: "Run \(utilizationStage == .impl ? "Implementation" : "Synthesis")") {
                    model.run(utilizationStage == .impl ? .implementation : .synthesis)
                }
            }
        }
    }

    private var powerCard: some View {
        Card("Power") {
            Switcher(options: ["Summary", "On-Chip"], selection: $powerView)
        } content: {
            if let power = model.power(at: .impl) {
                if powerView == "On-Chip" {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Array(power.components.enumerated()), id: \.offset) { _, c in
                            GridRow {
                                Text(c.name).padding(.leading, c.isPart ? 14 : 0).foregroundStyle(c.isPart ? .secondary : .primary)
                                Text("\(c.watts) W").monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)
                } else {
                    let hot = (power.thermalMargin?.celsius ?? 1) < 0
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text("Total On-Chip Power").fontWeight(.semibold)
                            Text(power.totalOnChip.map { String(format: "%.3f W", $0) } ?? "—").fontWeight(.semibold)
                                .foregroundStyle(hot ? Accent.error : Color.primary)
                        }
                        GridRow {
                            Text("Junction Temperature").fontWeight(.semibold)
                            Text(power.junctionTemperature.map { String(format: "%.1f °C", $0) } ?? "—").fontWeight(.semibold)
                                .foregroundStyle(hot ? Accent.error : Color.primary)
                        }
                        if let margin = power.thermalMargin {
                            GridRow {
                                Text("Thermal Margin").foregroundStyle(.secondary)
                                Text(String(format: "%.1f °C (%.1f W)", margin.celsius, margin.watts)).foregroundStyle(hot ? Accent.error : Color.primary)
                            }
                        }
                        InfoRow(label: "Effective \u{03D1}JA", value: power.effectiveThetaJA.map { String(format: "%.1f °C/W", $0) } ?? "—")
                        InfoRow(label: "Power supplied to off-chip devices", value: "0 W")
                        InfoRow(label: "Confidence level", value: power.confidence ?? "—")
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
                reportLink("Implemented Power Report", file: "power.rpt")
            } else {
                placeholder("Run Implementation to estimate power.", action: "Run Implementation") { model.run(.implementation) }
            }
        }
    }

    @ViewBuilder private func reportLink(_ title: String, file: String) -> some View {
        if let entry = model.reports.first(where: { $0.fileName == file }) {
            Button(title) { model.openReport(entry.id) }.buttonStyle(.link).font(.callout)
        }
    }

    private func placeholder(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).foregroundStyle(.secondary)
            Button(action, action: perform)
                .glassButton()
                .disabled(model.isRunning)
        }
        .font(.callout)
    }

    // MARK: Dashboard

    /// Vivado's default gadgets: timing, utilization and power of the latest runs.
    private var dashboard: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                Card("Timing (Route Design, WNS)") {
                    EmptyView()
                } content: {
                    if let t = model.timing, t.isTimed {
                        GadgetBar(label: "impl_1 · WNS", value: t.wns ?? 0, unit: "ns")
                        GadgetBar(label: "impl_1 · WHS", value: t.whs ?? 0, unit: "ns")
                        GadgetBar(label: "impl_1 · WPWS", value: t.wpws ?? 0, unit: "ns")
                    } else {
                        Text("Generate reports to view complete results.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Card("Utilization (Place Design)") {
                    EmptyView()
                } content: {
                    let synth = model.utilization(at: .synth), impl = model.utilization(at: .impl)
                    if synth != nil || impl != nil {
                        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("Report").gridColumnAlignment(.leading); ForEach(ResourceUsage.Kind.allCases, id: \.self) { Text($0.rawValue) } }
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach([("synth_1", synth), ("impl_1", impl)], id: \.0) { name, u in
                                if let u {
                                    GridRow {
                                        Text(name).gridColumnAlignment(.leading)
                                        ForEach(ResourceUsage.Kind.allCases, id: \.self) { k in
                                            Text(u.usage(k).map { String(format: "%.2f%%", $0.percent) } ?? "—")
                                        }
                                    }
                                }
                            }
                        }
                        .font(.callout).monospacedDigit()
                    } else {
                        Text("Generate reports to view complete results.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Card("Power (Route Design)") {
                    EmptyView()
                } content: {
                    if let p = model.power(at: .impl) {
                        GadgetBar(label: "Total Power", value: p.totalOnChip ?? 0, unit: "W")
                        GadgetBar(label: "Dynamic", value: p.dynamic ?? 0, unit: "W")
                        GadgetBar(label: "Device Static", value: p.deviceStatic ?? 0, unit: "W")
                    } else {
                        Text("Generate reports to view complete results.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .gridCellColumns(2)
            }
        }
    }
}

/// A row of a dashboard gadget: a label, a bar scaled to the value, and the value.
private struct GadgetBar: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 140, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(value < 0 ? Accent.error.gradient : Accent.success.gradient)
                    .frame(width: max(4, geo.size.width * min(1, abs(value) / max(abs(value), 1))))
            }
            .frame(height: 10)
            Text(String(format: "%.3f %@", value, unit)).font(.callout).monospacedDigit().frame(width: 90, alignment: .trailing)
        }
    }
}

/// Vivado's "Setup | Hold | Pulse Width" style switch in a panel's header.
struct Switcher: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Text("|").foregroundStyle(.tertiary) }
                Button(option) { selection = option }
                    .buttonStyle(.plain)
                    .font(.callout.weight(selection == option ? .semibold : .regular))
                    .foregroundStyle(selection == option ? .primary : .secondary)
            }
        }
    }
}

// MARK: Source editor

struct SourceEditorView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppearanceKey.editorFontSize) private var fontSize = 12.5
    @AppStorage(AppearanceKey.editorLineNumbers) private var lineNumbers = true
    let path: String

    private var language: HDLLanguage { HDLLanguage(fileExtension: (path as NSString).pathExtension) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(language.displayName).font(.caption).foregroundStyle(.secondary)
                if model.isDirty(path) {
                    Pill(text: "Edited", color: Accent.warning)
                }
                Button("Save") { model.saveFile(path) }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(!model.isDirty(path))
                    .help("Save (⌘S)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            CodeEditor(
                text: Binding(get: { model.editedText(for: path) }, set: { model.updateDraft($0, for: path) }),
                language: language, fontSize: CGFloat(fontSize), showLineNumbers: lineNumbers,
                onCaretMove: { model.setCaret($0, in: path) }, initialCaret: model.caret(in: path),
                reveal: model.editorReveal[path])
                .id(path)
        }
    }
}

// MARK: Reports

struct ReportView: View {
    @EnvironmentObject private var model: AppModel
    let id: String

    var body: some View {
        if let report = model.report(id) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.plaintext").foregroundStyle(.secondary)
                    Text(report.title).font(.callout.weight(.medium))
                    Text("\(report.run.runName) · \(report.fileName)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Text(report.text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
            }
        } else {
            ContentUnavailableView("Report Not Available", systemImage: "doc.plaintext",
                                   description: Text("Run the flow again to regenerate this report."))
        }
    }
}
