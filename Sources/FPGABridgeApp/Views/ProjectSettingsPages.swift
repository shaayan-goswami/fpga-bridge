import AppKit
import FPGABridgeCore
import SwiftUI

// The Elaboration, Simulation, Synthesis, Implementation and Bitstream pages of Project Settings. Each edits a copy
// of the settings that OK and Apply write back; nothing changes until then.

/// A list of text rows with Add and Remove, each marked red when it isn't valid.
private struct StringListEditor: View {
    @Binding var items: [String]
    let placeholder: String
    let isValid: (String) -> Bool
    var chooser: (() -> String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("", text: $items[index], prompt: Text(placeholder))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .foregroundStyle(valid(items[index]) ? Color.primary : Accent.error)
                    Button { items.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }
            HStack(spacing: 12) {
                Button { items.append("") } label: { Label("Add", systemImage: "plus") }
                if let chooser {
                    Button { if let chosen = chooser() { items.append(chosen) } } label: { Label("Choose Folder…", systemImage: "folder") }
                }
            }
            .buttonStyle(.borderless)
        }
    }

    /// A blank row is allowed; it is dropped when the settings are applied.
    private func valid(_ item: String) -> Bool {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || isValid(trimmed)
    }
}

/// An optional whole number: a switch, and when it's on, a stepper.
private struct OptionalNumber: View {
    let title: String
    @Binding var value: Int?
    let range: ClosedRange<Int>
    var initial = 0

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? initial) : nil }))
            if let current = value {
                Spacer()
                Stepper(value: Binding(get: { current }, set: { value = $0 }), in: range) {
                    Text("\(current)").monospacedDigit()
                }
                .fixedSize()
            }
        }
    }
}

/// The Tcl a page produces, shown under it so the settings teach the commands (Vivado shows them in its Tcl console).
private struct TclPreview: View {
    let lines: [String]

    var body: some View {
        Section {
            Text(lines.isEmpty ? "(nothing: these settings add no flags)" : lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Tcl")
        }
    }
}

/// What the form needs from the settings dialog.
struct SettingsContext {
    var projectURL: URL?
    var settings: ProjectSettings
    var top: String
    var part: String
    var sourceModules: [String]
    var testbenchModules: [String]

    /// The lines of the generated build script that start with one of `prefixes`.
    func script(_ prefixes: [String]) -> [String] {
        let project = Project(name: "p", top: top.isEmpty ? "top" : top, part: part, sources: ["x"], constraints: [], settings: settings.cleaned())
        return project.buildScript(sources: [], constraints: []).split(separator: "\n").map(String.init)
            .filter { line in prefixes.contains { line.hasPrefix($0) } }
    }
}

// MARK: Elaboration

struct ElaborationSettingsPage: View {
    @Binding var settings: ProjectSettings
    let context: SettingsContext

    var body: some View {
        Form {
            Section {
                StringListEditor(items: $settings.language.defines, placeholder: "NAME or NAME=VALUE", isValid: ProjectSettings.isValidDefine)
            } header: {
                Text("Verilog macros")
            } footer: {
                Text("Defined for synthesis (-verilog_define) and for simulation (-D), like `define lines at the top of every file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                StringListEditor(items: $settings.language.includeDirectories, placeholder: "folder inside the project",
                                 isValid: ProjectSettings.isValidIncludeDirectory, chooser: chooseFolder)
            } header: {
                Text("Include folders")
            } footer: {
                Text("Where `include \"file.vh\" is looked for. The folder's files must be in the project's design sources so they reach the build machine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                StringListEditor(items: $settings.language.generics, placeholder: "NAME=VALUE", isValid: ProjectSettings.isValidGeneric)
            } header: {
                Text("Generics and parameters")
            } footer: {
                Text("Overrides the top module's parameters in synthesis (-generic). Simulation uses the testbench's own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TclPreview(lines: context.script(["synth_design"]))
        }
        .formStyle(.grouped)
    }

    /// A folder picker that only accepts folders inside the project, and returns the project-relative path.
    private func chooseFolder() -> String? {
        guard let root = context.projectURL else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let base = root.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
}

// MARK: Simulation

struct SimulationSettingsPage: View {
    @Binding var settings: ProjectSettings
    @Binding var simulationTop: String
    let context: SettingsContext

    var body: some View {
        Form {
            Section("Testbench") {
                Picker("Top module:", selection: $simulationTop) {
                    Text("Automatic").tag("")
                    ForEach(context.testbenchModules, id: \.self) { Text($0).tag($0) }
                }
                .help("Automatic picks the testbench module that nothing else instantiates.")
                Picker("Language standard:", selection: $settings.simulation.standard) {
                    ForEach(ProjectSettings.Simulation.Standard.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show all compiler warnings", isOn: $settings.simulation.allWarnings)
            }
            Section {
                Stepper(value: $settings.simulation.timeLimit, in: ProjectSettings.Simulation.timeLimitRange, step: 10) {
                    LabeledContent("Time limit:") { Text("\(settings.simulation.timeLimit) seconds").monospacedDigit() }
                }
                TextField("Run arguments:", text: $settings.simulation.runtimeArguments, prompt: Text("+seed=5 +verbose"))
                    .font(.body.monospaced())
                    .foregroundStyle(valid(settings.simulation.runtimeArguments) ? Color.primary : Accent.error)
            } header: {
                Text("Run")
            } footer: {
                Text("A simulation that hasn't finished after the time limit is stopped. Run arguments are plusargs, read by $test$plusargs and $value$plusargs in the testbench.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Record a waveform", isOn: $settings.simulation.recordWaveform)
                Picker("Depth:", selection: $settings.simulation.waveformDepth) {
                    Text("All levels").tag(0)
                    ForEach([1, 2, 3, 4], id: \.self) { Text("\($0) level\($0 == 1 ? "" : "s")").tag($0) }
                }
                .disabled(!settings.simulation.recordWaveform)
            } header: {
                Text("Waveform")
            } footer: {
                Text("Turning the waveform off makes long simulations faster. Depth counts hierarchy levels below the testbench, starting at the testbench itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func valid(_ text: String) -> Bool {
        text.split(separator: " ").allSatisfy { $0.hasPrefix("+") && ProjectSettings.isValidOptionText(String($0)) }
    }
}

// MARK: Synthesis

struct SynthesisSettingsPage: View {
    @Binding var settings: ProjectSettings
    let context: SettingsContext

    var body: some View {
        Form {
            Section {
                Picker("Strategy:", selection: strategy) {
                    ForEach(ProjectSettings.Synthesis.strategies, id: \.name) { Text($0.name).tag($0.name as String?) }
                    if settings.synthesis.matchingStrategy == nil { Text("Custom").tag(nil as String?) }
                }
                if let name = settings.synthesis.matchingStrategy,
                   let summary = ProjectSettings.Synthesis.strategies.first(where: { $0.name == name })?.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Strategy")
            }
            Section {
                Picker("Directive:", selection: $settings.synthesis.directive) {
                    ForEach(ProjectSettings.Synthesis.directives, id: \.self) { Text($0).tag($0) }
                }
                Picker("Flatten hierarchy:", selection: $settings.synthesis.flattenHierarchy) {
                    ForEach(ProjectSettings.Synthesis.Flatten.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("FSM extraction:", selection: $settings.synthesis.fsmExtraction) {
                    ForEach(ProjectSettings.Synthesis.FSM.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Resource sharing:", selection: $settings.synthesis.resourceSharing) {
                    ForEach(ProjectSettings.Synthesis.Toggle3.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Synthesis (synth_design)")
            }
            Section {
                Toggle("Retiming", isOn: $settings.synthesis.retiming)
                    .help("Newer Vivado versions call this flag -global_retiming and warn that -retiming is deprecated. It still works, and it is the one every version accepts.")
                Toggle("Keep equivalent registers", isOn: $settings.synthesis.keepEquivalentRegisters)
                OptionalNumber(title: "Limit block RAMs", value: $settings.synthesis.maxBlockRAM, range: 0...10_000, initial: 0)
                OptionalNumber(title: "Limit DSP slices", value: $settings.synthesis.maxDSP, range: 0...10_000, initial: 0)
                Toggle("No LUT combining (-no_lc)", isOn: $settings.synthesis.noLUTCombining)
                OptionalNumber(title: "Shift register minimum size (-shreg_min_size)", value: $settings.synthesis.shregMinSize, range: 1...1_000, initial: 3)
                OptionalNumber(title: "Control set threshold (-control_set_opt_threshold)", value: $settings.synthesis.controlSetOptThreshold,
                               range: 0...1_000_000, initial: 1)
            } header: {
                Text("Options")
            }
            Section {
                TextField("More options:", text: $settings.synthesis.moreOptions, prompt: Text("-gated_clock_conversion on"))
                    .font(.body.monospaced())
                    .foregroundStyle(ProjectSettings.isValidOptionText(settings.synthesis.moreOptions) ? Color.primary : Accent.error)
            } footer: {
                Text("Any other synth_design flags. Letters, digits and - _ = . + , : / only.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { settings.synthesis = ProjectSettings.Synthesis() }
            }
            TclPreview(lines: context.script(["synth_design"]))
        }
        .formStyle(.grouped)
    }

    /// Choosing a strategy replaces the options; editing one by hand makes it "Custom".
    private var strategy: Binding<String?> {
        Binding(get: { settings.synthesis.matchingStrategy },
                set: { name in
                    if let name, let chosen = ProjectSettings.Synthesis.strategies.first(where: { $0.name == name }) {
                        settings.synthesis.apply(chosen)
                    }
                })
    }
}

// MARK: Implementation

struct ImplementationSettingsPage: View {
    @Binding var settings: ProjectSettings
    let context: SettingsContext

    var body: some View {
        Form {
            Section {
                Picker("Strategy:", selection: strategy) {
                    ForEach(ProjectSettings.Implementation.strategies, id: \.name) { Text($0.name).tag($0.name as String?) }
                    if settings.implementation.matchingStrategy == nil { Text("Custom").tag(nil as String?) }
                }
                if let name = settings.implementation.matchingStrategy,
                   let summary = ProjectSettings.Implementation.strategies.first(where: { $0.name == name })?.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Strategy")
            }
            Section {
                Picker("opt_design:", selection: $settings.implementation.optDirective) {
                    ForEach(ProjectSettings.Implementation.optDirectives, id: \.self) { Text($0).tag($0) }
                }
                Picker("place_design:", selection: $settings.implementation.placeDirective) {
                    ForEach(ProjectSettings.Implementation.placeDirectives, id: \.self) { Text($0).tag($0) }
                }
                Toggle("phys_opt_design after placement", isOn: $settings.implementation.physOpt)
                Toggle("phys_opt_design after routing", isOn: $settings.implementation.postRoutePhysOpt)
                Picker("phys_opt_design:", selection: $settings.implementation.physOptDirective) {
                    ForEach(ProjectSettings.Implementation.physOptDirectives, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!settings.implementation.physOpt && !settings.implementation.postRoutePhysOpt)
                Picker("route_design:", selection: $settings.implementation.routeDirective) {
                    ForEach(ProjectSettings.Implementation.routeDirectives, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Directives")
            }
            Section {
                optionsField("opt_design", $settings.implementation.optMoreOptions)
                optionsField("place_design", $settings.implementation.placeMoreOptions)
                optionsField("route_design", $settings.implementation.routeMoreOptions)
            } header: {
                Text("More options")
            } footer: {
                Text("Any other flags for the step. Letters, digits and - _ = . + , : / only.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { settings.implementation = ProjectSettings.Implementation() }
            }
            TclPreview(lines: context.script(["opt_design", "place_design", "phys_opt_design", "route_design"]))
        }
        .formStyle(.grouped)
    }

    /// Choosing a strategy replaces the directives; editing one by hand makes it "Custom".
    private var strategy: Binding<String?> {
        Binding(get: { settings.implementation.matchingStrategy },
                set: { name in
                    if let name, let chosen = ProjectSettings.Implementation.strategies.first(where: { $0.name == name }) {
                        settings.implementation.apply(chosen)
                    }
                })
    }

    private func optionsField(_ label: String, _ text: Binding<String>) -> some View {
        TextField("\(label):", text: text, prompt: Text("-flag value"))
            .font(.body.monospaced())
            .foregroundStyle(ProjectSettings.isValidOptionText(text.wrappedValue) ? Color.primary : Accent.error)
    }
}

// MARK: Bitstream

struct BitstreamSettingsPage: View {
    @Binding var settings: ProjectSettings
    let context: SettingsContext

    var body: some View {
        Form {
            Section {
                Toggle("Also write a .bin file", isOn: $settings.bitstream.binFile)
                    .help("The raw file that flash programming uses (-bin_file).")
                Toggle("Compress the bitstream", isOn: $settings.bitstream.compress)
                    .help("Makes the file smaller and loads faster (BITSTREAM.GENERAL.COMPRESS).")
            } header: {
                Text("Output")
            }
            Section {
                Picker("Configuration rate:", selection: $settings.bitstream.configRate) {
                    Text("Default").tag(nil as Int?)
                    ForEach(ProjectSettings.Bitstream.configRates, id: \.self) { Text("\($0) MHz").tag($0 as Int?) }
                }
                Picker("SPI bus width:", selection: $settings.bitstream.spiBusWidth) {
                    Text("Default").tag(nil as Int?)
                    ForEach(ProjectSettings.Bitstream.spiBusWidths, id: \.self) { Text("\($0)").tag($0 as Int?) }
                }
                Picker("Unused pins:", selection: $settings.bitstream.unusedPin) {
                    ForEach(ProjectSettings.Bitstream.UnusedPin.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("For loading from the board's flash. The rates and widths are the ones 7 series devices accept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("More options:", text: $settings.bitstream.moreOptions, prompt: Text("-raw_bitfile"))
                    .font(.body.monospaced())
                    .foregroundStyle(ProjectSettings.isValidOptionText(settings.bitstream.moreOptions) ? Color.primary : Accent.error)
            } footer: {
                Text("Any other write_bitstream flags. Letters, digits and - _ = . + , : / only.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { settings.bitstream = ProjectSettings.Bitstream() }
            }
            TclPreview(lines: context.script(["set_property", "write_bitstream"]))
        }
        .formStyle(.grouped)
    }
}
