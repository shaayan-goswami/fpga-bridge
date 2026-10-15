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
        .background(.bar)
    }
}

private struct TabButton: View {
    @EnvironmentObject private var model: AppModel
    let tab: WorkspaceTab
    @State private var hovering = false

    private var selected: Bool { model.selectedTab == tab }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.symbol(of: tab))
                .font(.caption)
                .foregroundStyle(selected ? Color.primary : .secondary)
            Text(model.title(of: tab))
                .lineLimit(1)
            if tab.isCloseable {
                Button { model.close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(hovering ? Color.primary.opacity(0.1) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(selected || hovering ? 1 : 0)
                .help("Close")
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

// MARK: Source viewer

struct SourceEditorView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppearanceKey.editorFontSize) private var fontSize = 12.5
    @AppStorage(AppearanceKey.editorLineNumbers) private var lineNumbers = true
    let path: String

    var body: some View {
        let text = model.contents(of: path)
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(language).font(.caption).foregroundStyle(.secondary)
                Pill(text: "Read-only preview", color: .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: 0) {
                    if lineNumbers {
                        Text((1...lineCount).map(String.init).joined(separator: "\n"))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 10)
                        Divider()
                    }
                    Text(Highlighter.highlight(text, fileExtension: (path as NSString).pathExtension))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .font(.system(size: fontSize, design: .monospaced))
                .lineSpacing(3)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var language: String {
        switch (path as NSString).pathExtension.lowercased() {
        case "sv", "svh": "SystemVerilog"
        case "vhd", "vhdl": "VHDL"
        case "xdc": "XDC"
        default: "Verilog"
        }
    }
}

/// Small regex highlighter: keywords, numbers, strings, directives and comments.
enum Highlighter {
    private static let verilogKeywords = [
        "module", "endmodule", "input", "output", "inout", "wire", "reg", "logic", "always", "always_ff", "always_comb",
        "assign", "begin", "end", "if", "else", "case", "endcase", "default", "posedge", "negedge", "parameter",
        "localparam", "initial", "for", "generate", "endgenerate", "genvar", "integer", "function", "endfunction",
    ]
    private static let vhdlKeywords = [
        "library", "use", "entity", "is", "port", "end", "architecture", "of", "begin", "signal", "process", "if",
        "then", "else", "elsif", "in", "out", "inout", "std_logic", "std_logic_vector", "rising_edge",
    ]
    private static let xdcKeywords = [
        "set_property", "create_clock", "get_ports", "get_pins", "get_clocks", "set_input_delay", "set_output_delay",
    ]

    static func highlight(_ text: String, fileExtension: String) -> AttributedString {
        var result = AttributedString(text)
        let ext = fileExtension.lowercased()
        let keywords: [String]
        let comments: [String]
        switch ext {
        case "vhd", "vhdl":
            keywords = vhdlKeywords
            comments = ["--[^\\n]*"]
        case "xdc":
            keywords = xdcKeywords
            comments = ["#[^\\n]*"]
        default:
            keywords = verilogKeywords
            comments = ["//[^\\n]*", "/\\*[\\s\\S]*?\\*/"]
        }
        let options: NSRegularExpression.Options = ext.hasPrefix("vhd") ? [.caseInsensitive] : []

        // Mostly grey: weight carries structure, with muted accents for keywords, directives and strings.
        func paint(_ pattern: String, options: NSRegularExpression.Options = [],
                   _ style: (inout AttributedSubstring) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let attributed = Range(range, in: result) else { continue }
                style(&result[attributed])
            }
        }

        result.foregroundColor = Color.primary.opacity(0.88)
        paint("\\b(" + keywords.joined(separator: "|") + ")\\b", options: options) {
            $0.foregroundColor = Accent.source
            $0.inlinePresentationIntent = .stronglyEmphasized
        }
        paint("\\b\\d+'[bBhHdDoO][0-9a-fA-F_xXzZ]+|\\b\\d[\\d_]*(\\.\\d+)?\\b") { $0.foregroundColor = .primary }
        paint("`\\w+|\\$\\w+") {
            $0.foregroundColor = Accent.remote
            $0.inlinePresentationIntent = .stronglyEmphasized
        }
        paint("\"[^\"\\n]*\"") { $0.foregroundColor = Accent.constraint }
        for pattern in comments {
            paint(pattern) {
                $0.foregroundColor = Color.secondary.opacity(0.8)
                $0.inlinePresentationIntent = .emphasized
            }
        }
        return result
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
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            ContentUnavailableView("Report Not Available", systemImage: "doc.plaintext",
                                   description: Text("Run the flow again to regenerate this report."))
        }
    }
}
