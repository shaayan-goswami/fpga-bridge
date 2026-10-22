import FPGABridgeCore
import SwiftUI

/// Vivado's bottom area: Tcl Console, Messages, Log, Reports and Design Runs, and Timing while a synthesized or
/// implemented design is open.
struct ConsolePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tools: ProjectTools

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(ConsoleTab.allCases.filter { ($0 != .timing || model.timingStage != nil || model.consoleTab == .timing) && ($0 != .findResults || tools.results != nil) }) { tab in
                            ConsoleTabButton(title: label(for: tab), selected: model.consoleTab == tab) {
                                model.consoleTab = tab
                            }
                        }
                    }
                }

                Spacer()

                if model.consoleTab == .log {
                    Picker("Run", selection: $model.logRun) {
                        Text("synth_1").tag(RunKind.synthesis)
                        Text("impl_1").tag(RunKind.implementation)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if model.consoleTab == .tclConsole {
                    Button { model.clearTcl() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Clear the Tcl console")
                }
                Button { model.consoleVisible = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Hide the console")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .barBackground()
            Divider()

            switch model.consoleTab {
            case .tclConsole: TclConsoleView()
            case .messages: MessagesView()
            case .log: LogView(lines: model.logs[model.logRun] ?? [])
            case .reports: ReportsListView()
            case .designRuns: DesignRunsView()
            case .timing: TimingPanel()
            case .findResults: FindResultsView()
            }
        }
    }

    private func label(for tab: ConsoleTab) -> String {
        guard tab == .messages else { return tab.rawValue }
        let count = model.count(.warning) + model.count(.error)
        return count > 0 ? "Messages (\(count))" : tab.rawValue
    }
}

private struct ConsoleTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background {
                    if !selected && hovering { Capsule().fill(Color.primary.opacity(0.06)) }
                }
                .glassWhenSelected(selected)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ConsoleLines: View {
    let lines: [ConsoleLine]
    var showCommandMarker = false
    @AppStorage(AppearanceKey.consoleFontSize) private var fontSize = 12.0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if showCommandMarker {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .opacity(line.kind == .command ? 1 : 0)
                            }
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind.color)
                                .fontWeight(line.kind == .command ? .medium : .regular)
                                .textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                }
                .font(.system(size: fontSize, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Theme.surface)
    }
}

private struct TclConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var command = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ConsoleLines(lines: model.tclLines, showCommandMarker: true)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                TextField("Type a Tcl command here", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit {
                        model.submitTcl(command)
                        command = ""
                        focused = true
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface)
        }
    }
}

private struct LogView: View {
    let lines: [ConsoleLine]

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView("No Log", systemImage: "text.alignleft",
                                   description: Text("Run the flow to see Vivado's log here."))
        } else {
            ConsoleLines(lines: lines)
        }
    }
}

private struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showErrors = true
    @State private var showWarnings = true
    @State private var showInfo = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle(isOn: $showErrors) { Label("\(model.count(.error)) Errors", systemImage: "xmark.octagon.fill") }
                Toggle(isOn: $showWarnings) { Label("\(model.count(.warning)) Warnings", systemImage: "exclamationmark.triangle.fill") }
                Toggle(isOn: $showInfo) { Label("\(model.count(.info)) Info", systemImage: "info.circle.fill") }
                Spacer()
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()

            let groups = [RunKind.synthesis, .implementation].map { ($0, model.messages(for: $0).filter(include)) }
            if groups.allSatisfy({ $0.1.isEmpty }) {
                ContentUnavailableView("No Messages", systemImage: "checkmark.bubble",
                                       description: Text("Errors, warnings and info from runs appear here."))
            } else {
                List {
                    ForEach(groups, id: \.0) { run, messages in
                        if !messages.isEmpty {
                            Section("\(run.title) (\(run.runName))") {
                                ForEach(messages) { message in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: message.kind.symbol).foregroundStyle(message.kind.color)
                                        Text(message.text).textSelection(.enabled)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .surfaceBackground()
            }
        }
    }

    private func include(_ line: ConsoleLine) -> Bool {
        switch line.kind {
        case .error: showErrors
        case .warning: showWarnings
        case .info: showInfo
        default: false
        }
    }
}

private struct ReportsListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.reports.isEmpty {
            ContentUnavailableView("No Reports", systemImage: "doc.plaintext",
                                   description: Text("Reports appear after synthesis and implementation."))
        } else {
            List {
                ForEach([RunKind.synthesis, .implementation], id: \.self) { run in
                    let entries = model.reports.filter { $0.run == run }
                    if !entries.isEmpty {
                        Section("\(run.title) (\(run.runName))") {
                            ForEach(entries) { entry in
                                Button { model.openReport(entry.id) } label: {
                                    HStack {
                                        Label(entry.title, systemImage: "doc.plaintext")
                                        Text(entry.fileName).foregroundStyle(.secondary)
                                        Spacer()
                                        Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .surfaceBackground()
        }
    }
}

/// One run in the Design Runs table, with Vivado's columns.
struct DesignRunRow: Identifiable {
    let id: String
    let isChild: Bool
    let state: RunState
    let status: String
    let values: [String: String]
}

/// Vivado's Design Runs window: synth_1 with impl_1 under it, every column Vivado shows, and its toolbar.
struct DesignRunsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPercent = false
    @State private var collapsed = false
    @State private var search = ""
    @State private var searching = false

    static let columns: [(title: String, width: CGFloat)] = [
        ("Constraints", 86), ("Status", 200), ("WNS", 56), ("TNS", 56), ("WHS", 56), ("THS", 56), ("WBSS", 52), ("TPWS", 56),
        ("Total Power", 80), ("Failed Routes", 92), ("Methodology", 96), ("RQA Score", 76), ("QoR Suggestions", 112),
        ("LUT", 56), ("FF", 56), ("BRAM", 52), ("URAM", 52), ("DSP", 48), ("Start", 128), ("Elapsed", 70), ("Run Strategy", 340),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        cell("Name", width: 120, bold: true)
                        ForEach(Self.columns, id: \.title) { cell($0.title, width: $0.width, bold: true) }
                    }
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05))
                    Divider()
                    ForEach(shown) { row in
                        HStack(spacing: 0) {
                            HStack(spacing: 4) {
                                if !row.isChild {
                                    Button { collapsed.toggle() } label: {
                                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                                    }
                                    .buttonStyle(.plain)
                                }
                                RunStatusIcon(state: row.state).font(.caption)
                                Text(row.id).monospaced()
                            }
                            .padding(.leading, row.isChild ? 26 : 6)
                            .frame(width: 120, alignment: .leading)
                            ForEach(Self.columns, id: \.title) { column in
                                let value = row.values[column.title] ?? ""
                                cell(column.title == "Status" ? row.status : value, width: column.width,
                                     color: column.title == "Methodology" && value.hasSuffix("CW") ? Accent.error
                                        : (column.title.count == 3 && value.hasPrefix("-")) ? Accent.error : nil)
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Launch Runs") { model.run(row.isChild ? .implementation : .synthesis) }.disabled(model.isRunning)
                            Button("Reset Runs") { model.resetRuns() }.disabled(model.isRunning)
                            Button("Open Run") { model.openDesign(row.isChild ? .impl : .synth) }
                            if row.isChild { Button("Generate Bitstream") { model.run(.bitstream) }.disabled(model.isRunning) }
                        }
                        Divider().opacity(0.4)
                    }
                }
                .font(.callout.monospacedDigit())
            }
        }
        .surfaceBackground()
    }

    private func cell(_ text: String, width: CGFloat, bold: Bool = false, color: Color? = nil) -> some View {
        Text(text)
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(color ?? (bold ? Color.secondary : Color.primary))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, alignment: .leading)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { searching.toggle(); if !searching { search = "" } } label: { Image(systemName: "magnifyingglass") }.help("Search")
            if searching { TextField("Search runs", text: $search).textFieldStyle(.roundedBorder).frame(width: 160) }
            Button { collapsed = true } label: { Image(systemName: "chevron.up.chevron.down") }.help("Collapse All")
            Button { collapsed = false } label: { Image(systemName: "chevron.down.2") }.help("Expand All")
            Divider().frame(height: 14)
            Button { model.resetRuns() } label: { Image(systemName: "backward.end") }
                .disabled(model.isRunning).help("Reset Runs")
            Button {} label: { Image(systemName: "backward") }.disabled(true)
                .help("Reset to Previous Step: runs are one Vivado session here, so steps can't be undone one at a time yet")
            Button { model.run(.bitstream) } label: { Image(systemName: "play.fill").foregroundStyle(Accent.remote) }
                .disabled(model.isRunning).help("Launch Runs")
            Button {} label: { Image(systemName: "forward") }.disabled(true)
                .help("Launch Next Step: runs are one Vivado session here, so steps can't be run one at a time yet")
            Button {} label: { Image(systemName: "plus") }.disabled(true).help("Create Runs: one synthesis and one implementation run for now")
            Toggle(isOn: $showPercent) { Image(systemName: "percent") }.toggleStyle(.button).help("Show Percentage")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var shown: [DesignRunRow] {
        let all = rows.filter { !collapsed || !$0.isChild }
        guard !search.isEmpty else { return all }
        return all.filter { row in row.id.localizedCaseInsensitiveContains(search) || row.values.values.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    private var rows: [DesignRunRow] {
        let version = model.project?.vivadoVersion ?? ""
        func usage(_ u: UtilizationSummary?, _ k: ResourceUsage.Kind) -> String {
            guard let r = u?.usage(k) else { return u == nil ? "" : "0" }
            return showPercent ? String(format: "%.2f", r.percent) : formatCount(r.used)
        }
        func start(_ state: RunState) -> String {
            state.started.map { $0.formatted(date: .numeric, time: .shortened) } ?? ""
        }
        func elapsed(_ state: RunState) -> String {
            guard state.elapsed > 0 else { return "" }
            let s = Int(state.elapsed)
            return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        }
        func common(_ u: UtilizationSummary?, _ state: RunState) -> [String: String] {
            ["Constraints": "constrs_1", "LUT": usage(u, .lut), "FF": usage(u, .ff), "BRAM": usage(u, .bram),
             "URAM": u == nil ? "" : "0", "DSP": usage(u, .dsp), "Start": start(state), "Elapsed": elapsed(state)]
        }
        let synthState = model.runs[.synthesis] ?? RunState()
        var synth = common(model.utilization(at: .synth), synthState)
        synth["Run Strategy"] = "\(model.synthesisStrategy) (Vivado Synthesis\(version.isEmpty ? "" : " " + version))"

        let implState = model.runs[.implementation] ?? RunState()
        var impl = common(model.utilization(at: .impl), implState)
        impl["Run Strategy"] = "\(model.implementationStrategy) (Vivado Implementation\(version.isEmpty ? "" : " " + version))"
        if let t = model.timing, t.isTimed {
            func ns(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "NA" }
            impl["WNS"] = ns(t.wns); impl["TNS"] = ns(t.tns); impl["WHS"] = ns(t.whs); impl["THS"] = ns(t.ths); impl["TPWS"] = ns(t.tpws)
        } else if model.timing != nil {
            for k in ["WNS", "TNS", "WHS", "THS", "TPWS"] { impl[k] = "NA" }
        }
        if let p = model.power(at: .impl)?.totalOnChip { impl["Total Power"] = String(format: "%.3f", p) }
        if let r = model.routeStatus { impl["Failed Routes"] = "\(r.failedRoutes)" }
        if let m = model.checks(.methodology, at: .impl) {
            let critical = m.count("Critical Warning")
            impl["Methodology"] = critical > 0 ? "\(critical) CW" : m.total > 0 ? "\(m.total) Warn" : "0"
        }
        return [
            DesignRunRow(id: "synth_1", isChild: false, state: synthState, status: model.runStatusText(.synthesis), values: synth),
            DesignRunRow(id: "impl_1", isChild: true, state: implState, status: model.runStatusText(.implementation), values: impl),
        ]
    }
}
