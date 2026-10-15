import FPGABridgeCore
import SwiftUI

/// Vivado's bottom area: Tcl Console, Messages, Log, Reports and Design Runs.
struct ConsolePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(ConsoleTab.allCases) { tab in
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

private struct ConsoleLines: View {
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

private struct DesignRunRow: Identifiable {
    let id: String
    let state: RunState
    let wns: String
    let tns: String
    let whs: String
    let lut: String
    let ff: String
    let bram: String
    let elapsed: String
    let strategy: String
}

/// Vivado's Design Runs table.
private struct DesignRunsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Table(rows) {
            TableColumn("Name") { row in Text(row.id).monospaced() }
            TableColumn("Status") { row in
                HStack(spacing: 5) {
                    RunStatusIcon(state: row.state)
                    Text(row.state.label)
                }
            }
            TableColumn("WNS", value: \.wns)
            TableColumn("TNS", value: \.tns)
            TableColumn("WHS", value: \.whs)
            TableColumn("LUT", value: \.lut)
            TableColumn("FF", value: \.ff)
            TableColumn("BRAM", value: \.bram)
            TableColumn("Elapsed", value: \.elapsed)
            TableColumn("Strategy", value: \.strategy)
        }
        .font(.callout.monospacedDigit())
        .surfaceBackground()
    }

    private var rows: [DesignRunRow] {
        let synthUtil = model.reports.first { $0.run == .synthesis }.flatMap { try? UtilizationSummary.parse($0.text) }
        let implUtil = model.reports.first { $0.run == .implementation && $0.fileName == BuildSummary.utilizationReport }
            .flatMap { try? UtilizationSummary.parse($0.text) }
        func row(_ kind: RunKind, util: UtilizationSummary?, timing: TimingSummary?, strategy: String) -> DesignRunRow {
            let state = model.runs[kind] ?? RunState()
            func count(_ k: ResourceUsage.Kind) -> String { util?.usage(k).map { formatCount($0.used) } ?? "" }
            return DesignRunRow(
                id: kind.runName, state: state,
                wns: timing.map { formatSigned($0.wns) } ?? "", tns: timing.map { formatSigned($0.tns) } ?? "",
                whs: timing.map { formatSigned($0.whs) } ?? "",
                lut: count(.lut), ff: count(.ff), bram: count(.bram),
                elapsed: state.elapsed > 0 ? formatDuration(state.elapsed) : "",
                strategy: strategy)
        }
        return [
            row(.synthesis, util: synthUtil, timing: nil, strategy: "Vivado Synthesis Defaults"),
            row(.implementation, util: implUtil, timing: model.timing, strategy: "Vivado Implementation Defaults"),
        ]
    }
}
