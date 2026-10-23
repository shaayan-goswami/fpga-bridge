import FPGABridgeCore
import SwiftUI

/// Where the run dialogs' choices are remembered.
enum RunDefaults {
    static let jobs = "launchRunsJobs"
    static let skipLaunchDialog = "launchRunsDontShowAgain"
    static let skipCompletionDialog = "runCompletedDontShowAgain"
    /// Launch Runs' starting number of jobs. Vivado 2025.2's own `general.maxThreads` default is 2 (checked on the
    /// build machine); 8 is the most most of its steps use, and the build machine runs one job at a time.
    static let defaultJobs = 8
}

extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// What Vivado's run-completion dialog is about: a run that finished, or one that failed.
enum RunCompletion: Identifiable, Equatable {
    case completed(RunKind)
    case failed(RunKind)

    var id: String {
        switch self {
        case .completed(let step): "completed-\(step.stepName)"
        case .failed(let step): "failed-\(step.stepName)"
        }
    }

    var step: RunKind {
        switch self {
        case .completed(let step), .failed(let step): step
        }
    }

    var succeeded: Bool { if case .completed = self { return true } else { return false } }

    /// Vivado's titles: "Synthesis Completed", "Bitstream Generation Completed", "Implementation Failed".
    var title: String {
        let name = step == .bitstream ? "Bitstream Generation" : step.title
        return "\(name) \(succeeded ? "Completed" : "Failed")"
    }

    var message: String {
        let name = step == .bitstream ? "Bitstream Generation" : step.title
        return succeeded ? "\(name) successfully completed." : "\(name) failed. See the errors in the Messages window."
    }

    /// The choices Vivado offers, the first selected.
    var choices: [RunCompletionChoice] {
        switch self {
        case .completed(.synthesis): [.runImplementation, .openSynthesizedDesign, .viewReports]
        case .completed(.implementation): [.openImplementedDesign, .generateBitstream, .viewReports]
        case .completed(.bitstream): [.openImplementedDesign, .viewReports, .openHardwareManager, .generateMemoryConfigurationFile]
        case .failed: [.openMessages, .viewLog]
        }
    }
}

enum RunCompletionChoice: String, CaseIterable, Identifiable {
    case runImplementation = "Run Implementation"
    case openSynthesizedDesign = "Open Synthesized Design"
    case openImplementedDesign = "Open Implemented Design"
    case generateBitstream = "Generate Bitstream"
    case viewReports = "View Reports"
    case openHardwareManager = "Open Hardware Manager"
    case generateMemoryConfigurationFile = "Generate Memory Configuration File"
    case openMessages = "Open Messages View"
    case viewLog = "View Log"

    var id: String { rawValue }

    /// Why a choice can't be made yet, if it can't.
    var unavailableReason: String? {
        self == .generateMemoryConfigurationFile ? "Not built yet: write_cfgmem isn't run from the app. Use Generate Bitstream's .bin option for flash." : nil
    }
}

extension AppModel {
    /// The completion dialog's OK.
    func completionChosen(_ choice: RunCompletionChoice, dontShowAgain: Bool) {
        let completion = completionPrompt
        completionPrompt = nil
        rememberCompletionDialog(dontShowAgain)
        switch choice {
        case .runImplementation: run(.implementation)
        case .generateBitstream: run(.bitstream)
        case .openSynthesizedDesign: openDesign(.synth)
        case .openImplementedDesign: openDesign(.impl)
        case .viewReports: consoleVisible = true; consoleTab = .reports
        case .openHardwareManager: open(.hardware)
        case .openMessages: consoleVisible = true; consoleTab = .messages
        case .viewLog:
            consoleVisible = true
            consoleTab = .log
            if let step = completion?.step { logRun = step.run }
        case .generateMemoryConfigurationFile: break
        }
    }

    func dismissCompletion(dontShowAgain: Bool) {
        completionPrompt = nil
        rememberCompletionDialog(dontShowAgain)
    }

    private func rememberCompletionDialog(_ dontShowAgain: Bool) {
        guard dontShowAgain else { return }
        showsCompletionDialog = false
        if persistsPreferences { UserDefaults.standard.set(true, forKey: RunDefaults.skipCompletionDialog) }
    }
}

/// Vivado's Launch Runs dialog. The runs go to the build machine, so "local host" there is the build machine here;
/// the number of jobs becomes Vivado's thread limit for the run.
struct LaunchRunsSheet: View {
    @EnvironmentObject private var model: AppModel
    let target: RunKind
    @State private var jobs = RunDefaults.defaultJobs
    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch Runs").font(.title2.weight(.bold))
                Text("Launch the selected synthesis or implementation runs.").foregroundStyle(.secondary)
            }
            LabeledContent("Launch directory:") {
                Text("<Default Launch Directory>").foregroundStyle(.secondary)
                    .help("Runs are kept in .fpga-bridge on \(model.backend.hostName), one folder per run.")
            }
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Launch runs on \(model.backend.hostName)", systemImage: "largecircle.fill.circle")
                        Spacer()
                        Picker("Number of jobs:", selection: $jobs) {
                            ForEach(Array(Project.FlowOptions.threadRange), id: \.self) { Text("\($0)").tag($0) }
                        }
                        .fixedSize()
                        .help("Vivado uses up to this many processor threads on the build machine (general.maxThreads).")
                    }
                    Label("Launch runs on Remote hosts", systemImage: "circle")
                        .foregroundStyle(.tertiary)
                        .help("Not built yet: runs go to the one build machine set up with `fpga-bridge init`.")
                    Label("Use Job Submission", systemImage: "circle")
                        .foregroundStyle(.tertiary)
                        .help("Not built yet: there is no job scheduler between the Mac and the build machine.")
                    Label("Generate scripts only", systemImage: "circle")
                        .foregroundStyle(.tertiary)
                        .help("Not built yet here. `fpga-bridge script --step synth|impl|bitstream` prints a run's script.")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Don't show this dialog again", isOn: $dontAskAgain)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelLaunch() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { model.confirmLaunch(jobs: jobs, dontAskAgain: dontAskAgain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { jobs = model.launchJobs }
    }
}

/// Vivado's dialog when a run finishes ("Synthesis Completed") or fails, offering the next thing to do.
struct RunCompletionSheet: View {
    @EnvironmentObject private var model: AppModel
    let completion: RunCompletion
    @State private var choice: RunCompletionChoice?
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: completion.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.largeTitle)
                    .foregroundStyle(completion.succeeded ? Accent.success : Accent.error)
                VStack(alignment: .leading, spacing: 4) {
                    Text(completion.title).font(.title2.weight(.bold))
                    Text(completion.message).foregroundStyle(.secondary)
                }
            }
            GroupBox("Next") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(completion.choices) { option in
                        Button { choice = option } label: {
                            Label(option.rawValue, systemImage: selected == option ? "largecircle.fill.circle" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(option.unavailableReason != nil)
                        .foregroundStyle(option.unavailableReason == nil ? .primary : .tertiary)
                        .help(option.unavailableReason ?? "")
                    }
                }
                .padding(6)
            }
            Toggle("Don't show this dialog again", isOn: $dontShowAgain)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissCompletion(dontShowAgain: dontShowAgain) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { model.completionChosen(selected, dontShowAgain: dontShowAgain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var selected: RunCompletionChoice { choice ?? completion.choices[0] }
}

/// Attaches the run dialogs to the main window.
struct RunDialogs: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.launchRequest.map(LaunchTarget.init) }, set: { if $0 == nil { model.cancelLaunch() } })) {
                LaunchRunsSheet(target: $0.step).environmentObject(model)
            }
            .sheet(item: $model.completionPrompt) { RunCompletionSheet(completion: $0).environmentObject(model) }
    }

    private struct LaunchTarget: Identifiable {
        let step: RunKind
        var id: String { step.stepName }
    }
}
