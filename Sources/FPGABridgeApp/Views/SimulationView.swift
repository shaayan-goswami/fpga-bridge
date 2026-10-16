import FPGABridgeCore
import SwiftUI

/// The Simulation tab: runs the testbench and shows its log, with the waveform to open afterwards.
struct SimulationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var simulation: SimulationManager

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            if case .done(let outcome) = simulation.state, let waveform = outcome.waveform {
                WaveformRow(url: waveform)
                Divider()
            }
            if simulation.lines.isEmpty && !simulation.isRunning {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No simulation has run yet").font(.headline)
                    Text("Run Simulation compiles the design and testbench and runs it on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
            } else {
                ConsoleLines(lines: simulation.lines)
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 12)
            if simulation.isRunning {
                Button("Stop") { simulation.stop() }
            } else {
                Button(hasRun ? "Run Again" : "Run Simulation") { model.runSimulation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasProject)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10))
    }

    private var hasRun: Bool { if case .done = simulation.state { return true } else { return false } }

    @ViewBuilder private var icon: some View {
        if simulation.isRunning {
            ProgressView().controlSize(.small).frame(width: 20)
        } else {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
        }
    }

    private var symbol: String {
        guard case .done(let outcome) = simulation.state else { return "waveform.path.ecg" }
        switch outcome.result {
        case .finished: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .failed, .timedOut: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        guard case .done(let outcome) = simulation.state else { return .secondary }
        switch outcome.result {
        case .finished: return Accent.success
        case .stopped: return .secondary
        case .failed, .timedOut: return Accent.error
        }
    }

    private var title: String {
        switch simulation.state {
        case .idle: "Ready to simulate"
        case .running: "Simulating…"
        case .done(let outcome):
            switch outcome.result {
            case .finished: "Simulation finished" + (outcome.finishedAt.map { " at \($0)" } ?? "")
            case .stopped: "Simulation stopped"
            case .timedOut: "Simulation timed out"
            case .failed: outcome.stage == .compile ? "Compile failed" : "Simulation failed"
            }
        }
    }

    private var detail: String? {
        switch simulation.state {
        case .idle: "Runs the project's simulation sources with Icarus Verilog."
        case .running: nil
        case .done(let outcome): outcome.top.isEmpty ? nil : "Testbench: \(outcome.top)"
        }
    }
}

private struct WaveformRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(Accent.source)
            VStack(alignment: .leading, spacing: 1) {
                Text("Waveform").font(.callout.weight(.medium))
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open Waveform") { open() }
                .help("Opens the waveform in the app set for .vcd files, such as Surfer or GTKWave.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Opens in whatever handles .vcd; with nothing installed, shows the file so it can be opened another way.
    private func open() {
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
