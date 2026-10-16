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
                case .ipCatalog: IPCatalogView()
                case .templates: LanguageTemplatesView()
                case .simulation: SimulationView()
                case .waveform: WaveformView()
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
struct ProjectSummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project Summary").font(.title2.weight(.bold))
                        Text(model.projectURL?.path ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.projectURL?.path ?? "")
                    }
                    Spacer()
                    Button { model.showSettings = true } label: { Label("Settings…", systemImage: "gearshape") }
                        .glassButton()
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        settingsCard
                        designRunsCard
                    }
                    VStack(spacing: 16) {
                        timingCard
                        utilizationCard
                        powerCard
                    }
                }
            }
            .padding(24)
        }
        .background(Backdrop())
    }

    private var settingsCard: some View {
        Card("Settings", symbol: "gearshape") {
            Button("Edit") { model.showSettings = true }.buttonStyle(QuietButtonStyle())
        } content: {
            if let project = model.project {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    InfoRow(label: "Project part", value: partDescription(project))
                    InfoRow(label: "Product family", value: family(ofPart: project.part))
                    InfoRow(label: "Top module name", value: project.top)
                    InfoRow(label: "Target language", value: project.targetLanguage ?? "Verilog")
                    InfoRow(label: "Simulator language", value: "Mixed")
                    InfoRow(label: "Vivado version", value: project.vivadoVersion.map { "\($0) (pinned)" } ?? "Not pinned")
                    InfoRow(label: "Build machine", value: model.backend.hostName)
                }
            }
        }
    }

    private func partDescription(_ project: Project) -> String {
        if let board = project.board.flatMap(BoardCatalog.lookup) { return "\(project.part) (\(board.displayName))" }
        return project.part
    }

    private var designRunsCard: some View {
        Card("Design Runs", symbol: "list.bullet.rectangle") {
            Button("Show All") { model.consoleVisible = true; model.consoleTab = .designRuns }.buttonStyle(QuietButtonStyle())
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Name"); Text("Status"); Text("WNS"); Text("Elapsed")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                runRow(.synthesis, wns: nil)
                runRow(.implementation, wns: model.timing?.wns)
            }
        }
    }

    private func runRow(_ kind: RunKind, wns: Double?) -> some View {
        let state = model.runs[kind] ?? RunState()
        return GridRow {
            Text(kind.runName).monospaced()
            HStack(spacing: 5) {
                RunStatusIcon(state: state)
                Text(state.label)
            }
            Text(wns.map { "\(formatSigned($0)) ns" } ?? "—").monospacedDigit()
            Text(state.elapsed > 0 ? formatDuration(state.elapsed) : "—").monospacedDigit()
        }
        .font(.callout)
    }

    @ViewBuilder
    private var timingCard: some View {
        Card("Timing", symbol: "timer") {
            if let entry = model.reports.first(where: { $0.fileName == BuildSummary.timingReport }) {
                Button("Report") { model.openReport(entry.id) }.buttonStyle(QuietButtonStyle())
            }
        } content: {
            if let timing = model.timing {
                if timing.isTimed {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(formatSigned(timing.wns)) ns")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(timing.constraintsMet ? Color.primary : Accent.error)
                        Pill(text: timing.constraintsMet ? "Timing met" : "Timing not met",
                             color: timing.constraintsMet ? Accent.success : Accent.error,
                             symbol: timing.constraintsMet ? "checkmark" : "exclamationmark.triangle.fill")
                    }
                    Text("Worst Negative Slack (setup)").font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            Text(""); Text("Setup"); Text("Hold")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        GridRow {
                            Text("Worst slack").foregroundStyle(.secondary)
                            Text("\(formatSigned(timing.wns)) ns"); Text("\(formatSigned(timing.whs)) ns")
                        }
                        GridRow {
                            Text("Total negative slack").foregroundStyle(.secondary)
                            Text("\(formatSigned(timing.tns)) ns"); Text("\(formatSigned(timing.ths)) ns")
                        }
                        GridRow {
                            Text("Failing endpoints").foregroundStyle(.secondary)
                            Text("\(timing.tnsFailingEndpoints ?? 0) of \(timing.tnsTotalEndpoints ?? 0)")
                            Text("\(timing.thsFailingEndpoints ?? 0) of \(timing.thsTotalEndpoints ?? 0)")
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                } else {
                    Label("No clocks or timing constraints were found, so nothing was timed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Accent.warning)
                }
            } else {
                placeholder("Run Implementation to see timing.", action: "Run Implementation") { model.run(.implementation) }
            }
        }
    }

    private var utilizationCard: some View {
        Card("Utilization", symbol: "chart.bar") {
            if let entry = model.reports.last(where: { $0.fileName.contains("utilization") }) {
                Button("Report") { model.openReport(entry.id) }.buttonStyle(QuietButtonStyle())
            }
        } content: {
            if let utilization = model.utilization {
                Text(model.runs[.implementation]?.status == .complete ? "Post-Implementation" : "Post-Synthesis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    ForEach([ResourceUsage.Kind.lut, .ff, .bram, .dsp, .io], id: \.self) { kind in
                        if let usage = utilization.usage(kind) { ResourceBar(usage: usage) }
                    }
                }
            } else {
                placeholder("Run Synthesis to see resource use.", action: "Run Synthesis") { model.run(.synthesis) }
            }
        }
    }

    private var powerCard: some View {
        Card("Power", symbol: "bolt") {
            Text("Power analysis needs Vivado's report_power, which isn't part of the build yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
                onCaretMove: { model.setCaret($0, in: path) }, initialCaret: model.caret(in: path))
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
