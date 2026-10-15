import AppKit
import FPGABridgeCore
import SwiftUI

/// Vivado's New Project wizard, page for page: Project Name, Project Type, Add Sources, Add Constraints,
/// Default Part, New Project Summary. Choosing "Do not specify sources at this time" skips the two source pages,
/// as in Vivado.
@MainActor
final class WizardState: ObservableObject {
    enum Step: Int, CaseIterable {
        case intro, name, type, sources, constraints, part, summary

        var title: String {
            switch self {
            case .intro: "New Project"
            case .name: "Project Name"
            case .type: "Project Type"
            case .sources: "Add Sources"
            case .constraints: "Add Constraints (optional)"
            case .part: "Default Part"
            case .summary: "New Project Summary"
            }
        }

        var subtitle: String {
            switch self {
            case .intro: "This wizard will guide you through the creation of a new project."
            case .name: "Enter a name for your project and specify a directory where the project data files will be stored."
            case .type: "Specify the type of project to create."
            case .sources: "Specify HDL files, or directories containing HDL files, to add to your project. Create a new source file on disk and add it to your project. You can also add and create sources later."
            case .constraints: "Specify or create constraint files for physical and timing constraints."
            case .part: "Choose a default part or board for your project."
            case .summary: "Review the project before it is created."
            }
        }
    }

    enum PartTab: String, CaseIterable, Identifiable {
        case parts = "Parts", boards = "Boards"
        var id: String { rawValue }
    }

    struct PendingFile: Identifiable, Equatable {
        let id = UUID()
        var url: URL?
        var newName: String?
        /// Set by the Define Module dialog for files created in the wizard.
        var module: ModuleDefinition?
        var name: String { url?.lastPathComponent ?? newName ?? "" }
        var location: String { url?.deletingLastPathComponent().path ?? "<Local to Project>" }
    }

    @Published var step: Step = .intro
    @Published var name = "project_1"
    @Published var location: URL
    @Published var createSubdirectory = true
    @Published var doNotSpecifySources = false
    @Published var designFiles: [PendingFile] = []
    @Published var constraintFiles: [PendingFile] = []
    @Published var language = "Verilog"
    @Published var partTab: PartTab = .parts
    @Published var familyFilter = "All"
    @Published var search = ""
    @Published var selectedPart: String?
    @Published var selectedBoard: String?
    @Published var error: String?

    init() {
        location = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        if let raw = ProcessInfo.processInfo.environment["FPGA_BRIDGE_WIZARD_STEP"], let n = Int(raw),
           let start = Step(rawValue: n) {
            step = start
        }
    }

    var visibleSteps: [Step] {
        Step.allCases.filter { !(doNotSpecifySources && ($0 == .sources || $0 == .constraints)) }
    }

    var projectDirectory: URL { createSubdirectory ? location.appendingPathComponent(name) : location }

    var nameProblem: String? {
        if name.isEmpty { return "Enter a project name." }
        if name.contains(" ") { return "Spaces aren't allowed in the project name." }
        if !Project.isPlain(name) { return "Use only letters, digits, '_' and '-'." }
        if createSubdirectory && FileManager.default.fileExists(atPath: projectDirectory.path) {
            return "\(projectDirectory.path) already exists."
        }
        return nil
    }

    var part: String? {
        if partTab == .boards, let board = selectedBoard.flatMap(BoardCatalog.lookup) { return board.part }
        return selectedPart ?? selectedBoard.flatMap(BoardCatalog.lookup)?.part
    }

    var canAdvance: Bool {
        switch step {
        case .name: nameProblem == nil
        case .part: part != nil
        default: true
        }
    }

    func next() {
        guard let index = visibleSteps.firstIndex(of: step), index + 1 < visibleSteps.count else { return }
        step = visibleSteps[index + 1]
    }

    func back() {
        guard let index = visibleSteps.firstIndex(of: step), index > 0 else { return }
        step = visibleSteps[index - 1]
    }

    func request() -> NewProjectRequest {
        var request = NewProjectRequest(name: name, location: location, part: part ?? "",
                                        board: partTab == .boards ? selectedBoard : nil)
        request.createSubdirectory = createSubdirectory
        request.language = language
        if !doNotSpecifySources {
            request.designSources = designFiles.compactMap(\.url)
            request.constraints = constraintFiles.compactMap(\.url)
            request.newFiles = designFiles.compactMap { file in file.newName.map { NewFile(set: .design, name: $0, module: file.module) } }
                + constraintFiles.compactMap { $0.newName.map { NewFile(set: .constraints, name: $0) } }
        }
        return request
    }

    /// New design files still needing a module definition (Vivado asks for these when you click Finish).
    var newDesignFiles: [PendingFile] {
        doNotSpecifySources ? [] : designFiles.filter { $0.newName != nil }
    }

    /// The parts we can offer: the ones on the supported boards. Any other part can be typed in Settings later.
    static var parts: [String] { Array(Set(BoardCatalog.all.map(\.part))).sorted() }
}

struct NewProjectWizard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = WizardState()
    @State private var defineDrafts: [ModuleDraft]?

    var body: some View {
        HStack(spacing: 0) {
            stepList
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.step.title).font(.title2.weight(.bold))
                    Text(state.step.subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Group {
                    switch state.step {
                    case .intro: IntroPage()
                    case .name: NamePage()
                    case .type: TypePage()
                    case .sources: FilesPage(set: .design, files: $state.designFiles)
                    case .constraints: FilesPage(set: .constraints, files: $state.constraintFiles)
                    case .part: PartPage()
                    case .summary: SummaryPage()
                    }
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environmentObject(state)

                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Accent.error)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 8)
                }
                Divider()
                buttons
            }
        }
        .frame(width: 880, height: 620)
        .background(Backdrop())
        .sheet(isPresented: Binding(get: { defineDrafts != nil }, set: { if !$0 { defineDrafts = nil } })) {
            if let drafts = defineDrafts {
                DefineModuleSheet(drafts: drafts) { defined in
                    for draft in defined {
                        if let i = state.designFiles.firstIndex(where: { $0.newName == draft.fileName }) {
                            state.designFiles[i].module = draft.module
                        }
                    }
                    create()
                }
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.visibleSteps, id: \.self) { step in
                let index = state.visibleSteps.firstIndex(of: step) ?? 0
                let current = state.visibleSteps.firstIndex(of: state.step) ?? 0
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(index < current ? Accent.success : (index == current ? Accent.active : Color.secondary.opacity(0.25)))
                            .frame(width: 10, height: 10)
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 6, weight: .black)).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    Text(step.title)
                        .fontWeight(index == current ? .semibold : .regular)
                        .foregroundStyle(index <= current ? .primary : .secondary)
                }
                .padding(.vertical, 5)
            }
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(20)
        .frame(width: 210, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface(cornerRadius: 18)
        .padding(12)
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Back") { state.error = nil; state.back() }
                .disabled(state.step == state.visibleSteps.first)
            if state.step == .summary {
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton()
            } else {
                Button("Next") { state.error = nil; state.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canAdvance)
            }
        }
        .controlSize(.large)
        .padding(16)
    }

    /// Like Vivado: new design files get a Define Module dialog before the project is created.
    private func finish() {
        let pending = state.newDesignFiles
        if pending.isEmpty {
            create()
        } else {
            defineDrafts = pending.compactMap { $0.newName.map { ModuleDraft(fileName: $0, set: .design) } }
        }
    }

    private func create() {
        do {
            try model.createProject(state.request())
            dismiss()
        } catch {
            state.error = "\(error.userMessage)"
        }
    }
}

// MARK: Pages

private struct IntroPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You will:")
            VStack(alignment: .leading, spacing: 10) {
                bullet("character.cursor.ibeam", "Name your project and choose where it is stored")
                bullet("square.stack", "Specify the type of project")
                bullet("doc.badge.plus", "Add existing sources and constraints, or create new ones")
                bullet("memorychip", "Choose a default part or board")
            }
            Spacer().frame(height: 6)
            Label("Synthesis and implementation will run in Vivado on \(model.backend.hostName). Everything else happens on this Mac.",
                  systemImage: "desktopcomputer")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).labelStyle(WizardBulletLabelStyle())
    }
}

private struct WizardBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(.secondary).frame(width: 22)
            configuration.title
        }
    }
}

private struct NamePage: View {
    @EnvironmentObject private var state: WizardState

    var body: some View {
        Form {
            TextField("Project name:", text: $state.name)
            LabeledContent("Project location:") {
                HStack {
                    Text(state.location.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                    Button("Choose…", action: choose)
                }
            }
            Toggle("Create project subdirectory", isOn: $state.createSubdirectory)
            LabeledContent("Project will be created at:") {
                Text(state.projectDirectory.path)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let problem = state.nameProblem {
                Label(problem, systemImage: "exclamationmark.circle.fill").foregroundStyle(Accent.warning)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.location
        if panel.runModal() == .OK, let url = panel.url { state.location = url }
    }
}

private struct TypePage: View {
    @EnvironmentObject private var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            option(selected: true, title: "RTL Project",
                   detail: "You will be able to add sources, run RTL analysis, synthesis, implementation, and generate a bitstream.")
            Toggle("Do not specify sources at this time", isOn: $state.doNotSpecifySources)
                .padding(.leading, 34)
            ForEach([
                ("Post-synthesis Project", "Add sources from a synthesized netlist."),
                ("I/O Planning Project", "Plan I/O pins without RTL sources."),
                ("Imported Project", "Import a Synplify, XST or ISE project."),
                ("Example Project", "Use File > Project > Open Example instead."),
            ], id: \.0) { title, detail in
                option(selected: false, title: title, detail: detail + " Not supported yet.").opacity(0.45)
            }
        }
    }

    private func option(selected: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.primary : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.primary.opacity(0.06) : .clear))
    }
}

/// The Add Sources / Add Constraints pages: a file table with Add Files, Add Directories and Create File.
private struct FilesPage: View {
    @EnvironmentObject private var state: WizardState
    let set: SourceSet
    @Binding var files: [WizardState.PendingFile]
    @State private var selection: WizardState.PendingFile.ID?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { pick(directories: false) } label: { Label("Add Files…", systemImage: "doc.badge.plus") }
                if set == .design {
                    Button { pick(directories: true) } label: { Label("Add Directories…", systemImage: "folder.badge.plus") }
                }
                Button { creating = true } label: { Label("Create File…", systemImage: "square.and.pencil") }
                Spacer()
                Button { files.removeAll { $0.id == selection } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove the selected file")
            }

            Table(files, selection: $selection) {
                TableColumn("Index") { file in Text("\((files.firstIndex(of: file) ?? 0) + 1)").monospacedDigit() }
                    .width(44)
                TableColumn("Name") { file in Label(file.name, systemImage: set == .constraints ? "pin" : "doc.text") }
                TableColumn("Library") { _ in Text("xil_defaultlib").foregroundStyle(.secondary) }
                    .width(110)
                TableColumn("Location") { file in Text(file.location).foregroundStyle(.secondary).truncationMode(.middle) }
            }
            .overlay {
                if files.isEmpty {
                    Text(set == .design ? "Use Add Files, Add Directories or Create File to add sources."
                                        : "Use Add Files or Create File to add constraints.")
                        .foregroundStyle(.secondary)
                }
            }

            if set == .design {
                HStack(spacing: 24) {
                    Picker("Target language:", selection: $state.language) {
                        Text("Verilog").tag("Verilog")
                        Text("VHDL").tag("VHDL")
                    }
                    .fixedSize()
                    Picker("Simulator language:", selection: .constant("Mixed")) { Text("Mixed").tag("Mixed") }
                        .fixedSize()
                        .disabled(true)
                }
            }
            Toggle("Copy sources into project", isOn: .constant(true))
                .disabled(true)
                .help("Sources are always copied into the project's .srcs folder, so the build machine gets everything it needs.")
        }
        .sheet(isPresented: $creating) {
            CreateSourceFileSheet(sourceSet: set, defaultLanguage: state.language) { name in
                if !files.contains(where: { $0.newName == name }) { files.append(.init(newName: name)) }
            }
        }
    }

    private func pick(directories: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        guard panel.runModal() == .OK else { return }
        var urls: [URL] = []
        for url in panel.urls {
            if directories {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                while let item = walker?.nextObject() as? URL {
                    if item.hasDirectoryPath { continue }
                    if ["v", "sv", "vh", "svh", "vhd", "vhdl"].contains(item.pathExtension.lowercased()) { urls.append(item) }
                }
            } else {
                urls.append(url)
            }
        }
        files += urls.filter { url in !files.contains { $0.url == url } }.map { .init(url: $0) }
    }
}

private struct PartPage: View {
    @EnvironmentObject private var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $state.partTab) {
                    ForEach(WizardState.PartTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if state.partTab == .parts {
                    Picker("Family:", selection: $state.familyFilter) {
                        ForEach(["All", "Artix-7", "Spartan-7"], id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                }
                Spacer()
                TextField("Search", text: $state.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            if state.partTab == .parts {
                Table(partRows, selection: $state.selectedPart) {
                    TableColumn("Part") { Text($0.id).monospaced() }
                        .width(min: 170, ideal: 180)
                    TableColumn("Family", value: \.family)
                    TableColumn("Package", value: \.package)
                    TableColumn("Speed", value: \.speed).width(60)
                    TableColumn("Used On", value: \.boards)
                }
            } else {
                Table(boardRows, selection: $state.selectedBoard) {
                    TableColumn("Display Name") { Text($0.displayName).fontWeight(.medium) }
                    TableColumn("Vendor") { _ in Text("digilentinc.com").foregroundStyle(.secondary) }
                    TableColumn("Part") { Text($0.part).monospaced() }
                    TableColumn("Family", value: \.family)
                }
            }
            if let part = state.part {
                Label("Default part: \(part)", systemImage: "memorychip").foregroundStyle(.secondary)
            }
        }
    }

    struct PartRow: Identifiable {
        let id: String
        let family: String
        let package: String
        let speed: String
        let boards: String
    }

    private var partRows: [PartRow] {
        WizardState.parts.map { part in
            // xc7a35ticsg324-1L -> device xc7a35ti, package csg324, speed -1L
            let package = part.range(of: "^xc7[a-z]\\d+(ti|t)?", options: .regularExpression)
                .map { String(part[$0.upperBound...].prefix { $0 != "-" }) } ?? ""
            let speed = part.split(separator: "-").last.map { "-\($0)" } ?? ""
            let boards = BoardCatalog.all.filter { $0.part == part }.map(\.displayName).joined(separator: ", ")
            return PartRow(id: part, family: family(ofPart: part), package: package, speed: speed, boards: boards)
        }
        .filter { state.familyFilter == "All" || $0.family == state.familyFilter }
        .filter { state.search.isEmpty || $0.id.localizedCaseInsensitiveContains(state.search)
            || $0.boards.localizedCaseInsensitiveContains(state.search) }
    }

    private var boardRows: [Board] {
        BoardCatalog.all.filter {
            state.search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(state.search)
                || $0.part.localizedCaseInsensitiveContains(state.search)
        }
    }
}

private struct SummaryPage: View {
    @EnvironmentObject private var state: WizardState

    var body: some View {
        let request = state.request()
        let board = request.board.flatMap(BoardCatalog.lookup)
        VStack(alignment: .leading, spacing: 14) {
            summaryLine("checkmark.circle.fill", "A new RTL project named '\(request.name)' will be created.")
            if state.doNotSpecifySources {
                summaryLine("info.circle", "No source files or directories will be added. Use Add Sources to add them later.")
            } else {
                summaryLine("doc.text", "\(request.designSources.count + request.newFiles.filter { $0.set == .design }.count) source files will be added.")
                summaryLine("pin", "\(request.constraints.count + request.newFiles.filter { $0.set == .constraints }.count) constraints files will be added.")
            }
            Divider()
            Text("The default part and product family for the new project:").fontWeight(.medium)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if let board { InfoRow(label: "Default Board", value: board.displayName) }
                InfoRow(label: "Default Part", value: request.part, monospaced: true)
                InfoRow(label: "Family", value: family(ofPart: request.part))
                InfoRow(label: "Location", value: state.projectDirectory.path)
            }
            Spacer().frame(height: 4)
            Text("To create the project, click Finish.").foregroundStyle(.secondary)
        }
    }

    private func summaryLine(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).labelStyle(WizardBulletLabelStyle())
    }
}
