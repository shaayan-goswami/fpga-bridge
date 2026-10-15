import AppKit
import FPGABridgeCore
import SwiftUI

/// Vivado's Settings dialog (Flow Navigator > Settings): Project Settings on the left, OK / Cancel / Apply.
struct ProjectSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Page: String, CaseIterable, Identifiable {
        case general = "General"
        case simulation = "Simulation"
        case elaboration = "Elaboration"
        case synthesis = "Synthesis"
        case implementation = "Implementation"
        case bitstream = "Bitstream"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .simulation: "waveform.path.ecg"
            case .elaboration: "square.stack.3d.up"
            case .synthesis: "cpu"
            case .implementation: "arrow.triangle.branch"
            case .bitstream: "memorychip"
            }
        }
    }

    @State private var page: Page? = .general
    @State private var top = ""
    @State private var board = ""
    @State private var part = ""
    @State private var language = "Verilog"
    @State private var vivadoVersion = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $page) {
                    Section("Project Settings") {
                        ForEach(Page.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                Divider()
                Group {
                    switch page ?? .general {
                    case .general: general
                    default: notConfigurable(page ?? .general)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                Button("OK") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(14)
        }
        .frame(width: 780, height: 520)
        .onAppear(perform: load)
    }

    private var general: some View {
        Form {
            Section {
                LabeledContent("Name:") { Text(model.project?.name ?? "") }
                Picker("Board:", selection: $board) {
                    Text("None").tag("")
                    ForEach(BoardCatalog.all) { Text($0.displayName).tag($0.id) }
                }
                .onChange(of: board) { _, id in
                    if let found = BoardCatalog.lookup(id) { part = found.part }
                }
                LabeledContent("Project device:") {
                    TextField("", text: $part)
                        .labelsHidden()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .disabled(!board.isEmpty)
                }
                .help(board.isEmpty ? "Any Vivado part number" : "Set by the board. Choose None to type a part.")
                Picker("Target language:", selection: $language) {
                    Text("Verilog").tag("Verilog")
                    Text("VHDL").tag("VHDL")
                }
                LabeledContent("Top module name:") {
                    HStack {
                        TextField("", text: $top).labelsHidden()
                        Menu {
                            ForEach(modules, id: \.self) { name in Button(name) { top = name } }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Choose a module from the design sources")
                    }
                }
            } header: {
                Text("General")
            }
            Section {
                TextField("Pinned Vivado version:", text: $vivadoVersion, prompt: Text("e.g. 2023.2"))
            } footer: {
                Text("Builds warn when the build machine is set up for a different version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func notConfigurable(_ page: Page) -> some View {
        ContentUnavailableView {
            Label("\(page.rawValue) Settings", systemImage: page.symbol)
        } description: {
            Text(page == .simulation
                 ? "Simulation with Verilator is planned."
                 : "Runs use Vivado's default \(page.rawValue.lowercased()) strategy. Changing it isn't supported yet.")
        }
    }

    private var modules: [String] {
        guard let project = model.project, let url = model.projectURL else { return [] }
        let files = (try? project.resolveSources(in: url)) ?? []
        return files.flatMap { ProjectCreator.declaredModules(in: model.contents(of: $0)) }.sorted()
    }

    private func load() {
        guard !loaded, let project = model.project else { return }
        loaded = true
        top = project.top
        board = project.board.flatMap { BoardCatalog.lookup($0)?.id } ?? ""
        part = project.part
        language = project.targetLanguage ?? "Verilog"
        vivadoVersion = project.vivadoVersion ?? ""
    }

    private func apply() {
        let version = vivadoVersion.trimmingCharacters(in: .whitespaces)
        model.applySettings(top: top.trimmingCharacters(in: .whitespaces), part: part.trimmingCharacters(in: .whitespaces),
                            board: board.isEmpty ? nil : board, language: language,
                            vivadoVersion: version.isEmpty ? nil : version)
    }
}

/// Vivado's Add Sources wizard: choose constraints, design or simulation sources, then add or create files.
struct AddSourcesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var set: SourceSet = .design
    @State private var choosing = true
    @State private var files: [URL] = []
    @State private var newFiles: [String] = []
    @State private var creating = false
    @State private var defineDrafts: [ModuleDraft]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(choosing ? "Add Sources" : "Add or Create \(set.title)").font(.title2.weight(.bold))
                Text(choosing ? "This guides you through the process of adding and creating sources for your project."
                              : "Specify files to add to your project, or create a new file on disk and add it.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Group {
                if choosing {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([SourceSet.constraints, .design, .simulation]) { option in
                            Button { set = option } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: set == option ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(set == option ? Color.primary : .secondary)
                                        .font(.title3)
                                    Text("Add or create \(option.title.lowercased())")
                                    Spacer()
                                }
                                .padding(10)
                                .contentShape(Rectangle())
                                .background(RoundedRectangle(cornerRadius: 8).fill(set == option ? Color.primary.opacity(0.06) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button { pick() } label: { Label("Add Files…", systemImage: "doc.badge.plus") }
                            Button { creating = true } label: { Label("Create File…", systemImage: "square.and.pencil") }
                        }
                        List {
                            ForEach(files, id: \.self) { Label($0.lastPathComponent, systemImage: "doc.text") }
                            ForEach(newFiles, id: \.self) { Label("\($0) (new)", systemImage: "doc.badge.plus") }
                        }
                        .listStyle(.bordered)
                        .overlay {
                            if files.isEmpty && newFiles.isEmpty {
                                Text("No files yet.").foregroundStyle(.secondary)
                            }
                        }
                        Text("Files are copied into the project.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if choosing {
                    Button("Next") { choosing = false }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Back") { choosing = true }
                    Button("Finish") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(files.isEmpty && newFiles.isEmpty)
                }
            }
            .controlSize(.large)
            .padding(14)
        }
        .frame(width: 620, height: 460)
        #if DEBUG
        .onAppear {
            // Screenshot scenario: jump straight to Define Module with a sample port list.
            guard DebugHooks.scenario == "definemodule", defineDrafts == nil else { return }
            choosing = false
            newFiles = ["uart_tx.v", "uart_tb.v"]
            var draft = ModuleDraft(fileName: "uart_tx.v", set: .design)
            draft.module.ports = [
                PortDefinition(name: "clk"), PortDefinition(name: "rst"),
                PortDefinition(name: "data", isBus: true, msb: 7, lsb: 0), PortDefinition(name: "start"),
                PortDefinition(name: "tx", direction: .output), PortDefinition(name: "busy", direction: .output),
            ]
            defineDrafts = [draft, ModuleDraft(fileName: "uart_tb.v", set: .simulation)]
        }
        #endif
        .sheet(isPresented: $creating) {
            CreateSourceFileSheet(sourceSet: set, defaultLanguage: model.project?.targetLanguage ?? "Verilog") { name in
                if !newFiles.contains(name) { newFiles.append(name) }
            }
        }
        .sheet(isPresented: Binding(get: { defineDrafts != nil }, set: { if !$0 { defineDrafts = nil } })) {
            if let drafts = defineDrafts {
                DefineModuleSheet(drafts: drafts) { defined in
                    commit(modules: Dictionary(uniqueKeysWithValues: defined.map { ($0.fileName, $0.module) }))
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { files += panel.urls.filter { !files.contains($0) } }
    }

    /// New design or simulation files get a Define Module dialog first, as in Vivado. Constraints don't.
    private func finish() {
        let needModules = set != .constraints && !newFiles.isEmpty
        if needModules {
            defineDrafts = newFiles.map { ModuleDraft(fileName: $0, set: set) }
        } else {
            commit(modules: [:])
        }
    }

    private func commit(modules: [String: ModuleDefinition]) {
        if !files.isEmpty { model.addSources(files, to: set) }
        for name in newFiles { model.createSourceFile(named: name, in: set, module: modules[name]) }
        dismiss()
    }
}
