import FPGABridgeCore
import SwiftUI

/// Vivado's Linter window: the rules that fired with how often, and every message, each linked to its line of HDL.
struct LinterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rule: String?

    var body: some View {
        Group {
            switch model.lint {
            case .idle:
                ContentUnavailableView {
                    Label("Linter", systemImage: "checklist")
                } description: {
                    Text("The linter checks the RTL for likely mistakes, such as unread inputs, before you synthesize.")
                } actions: {
                    Button("Run Linter") { model.runLinter() }.disabled(model.isRunning)
                }
            case .running:
                ProgressView("Running the linter on \(model.backend.hostName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let failure):
                VStack(spacing: 0) {
                    ContentUnavailableView {
                        Label("The linter didn't finish", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("Run Linter Again") { model.runLinter() }.disabled(model.isRunning)
                    }
                    if !failure.log.isEmpty {
                        ScrollView {
                            Text(failure.log.suffix(6000))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(maxHeight: 260)
                    }
                }
            case .done(let report):
                results(report)
            }
        }
        .background(Theme.surface)
    }

    private func results(_ report: LintReport) -> some View {
        let shown = report.messages.filter { rule == nil || $0.rule == rule }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(report.messages.isEmpty ? "No linter messages" : "\(report.messages.count) linter message\(report.messages.count == 1 ? "" : "s")")
                    .font(.headline)
                if model.backend.isDemo { Pill(text: "Sample data", color: .secondary) }
                Spacer()
                if rule != nil { Button("Show All") { rule = nil }.buttonStyle(.link) }
                Button { model.runLinter() } label: { Label("Run Again", systemImage: "arrow.clockwise") }
                    .disabled(model.isRunning)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            if !report.rules.isEmpty {
                Table(report.rules, selection: Binding(get: { rule }, set: { rule = $0 })) {
                    TableColumn("Rule ID") { Text($0.rule).font(.callout.monospaced()) }
                    TableColumn("Severity") { SeverityLabel(severity: $0.severity) }
                    TableColumn("# Violations") { Text("\($0.violations)").monospacedDigit() }
                    TableColumn("# Waived") { Text("\($0.waived)").monospacedDigit() }
                }
                .frame(height: min(CGFloat(report.rules.count) * 26 + 34, 180))
                Divider()
            }
            if report.messages.isEmpty {
                ContentUnavailableView("Nothing to fix", systemImage: "checkmark.seal", description: Text("The linter found nothing in this design."))
            } else {
                Table(shown) {
                    TableColumn("Severity") { SeverityLabel(severity: $0.severity) }.width(min: 80, ideal: 90, max: 120)
                    TableColumn("Rule") { Text($0.rule).font(.callout.monospaced()) }.width(min: 70, ideal: 90, max: 130)
                    TableColumn("Message") { Text($0.text).lineLimit(3).textSelection(.enabled) }
                    TableColumn("Hierarchy") { Text($0.hierarchy ?? "").font(.callout.monospaced()) }.width(min: 70, ideal: 110, max: 200)
                    TableColumn("Source") { message in sourceLink(message) }.width(min: 90, ideal: 130, max: 220)
                }
            }
        }
    }

    @ViewBuilder private func sourceLink(_ message: LintMessage) -> some View {
        if let file = message.file {
            let label = message.line.map { "\(file):\($0)" } ?? file
            if let path = model.projectFile(named: file) {
                Button(label) { model.goToSource(file: path, line: message.line ?? 1) }
                    .buttonStyle(.link)
                    .help("Open \(path) at this line")
            } else {
                Text(label).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SeverityLabel: View {
    let severity: String

    var body: some View {
        let upper = severity.uppercased()
        let (symbol, color): (String, Color) = upper.contains("ERROR") ? ("xmark.octagon.fill", Accent.error)
            : upper.contains("CRITICAL") ? ("exclamationmark.triangle.fill", Accent.error)
            : upper.contains("WARNING") ? ("exclamationmark.triangle.fill", Accent.warning)
            : ("info.circle", .secondary)
        Label(severity.capitalized, systemImage: symbol).foregroundStyle(color).labelStyle(.titleAndIcon)
    }
}

extension LintReport.RuleCount: Identifiable {
    public var id: String { rule }
}
