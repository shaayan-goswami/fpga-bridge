import AppKit
import FPGABridgeCore
import SwiftUI

/// Presents the dialogs `ProjectTools.sheet` asks for. Attached once to the main window.
struct ProjectToolSheets: ViewModifier {
    @ObservedObject var tools: ProjectTools
    let model: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: $tools.sheet) { sheet in
            Group {
                switch sheet {
                case .saveAs: SaveProjectAsSheet()
                case .archive: ArchiveProjectSheet()
                case .writeTcl: WriteTclSheet()
                case .find(let replace): FindInFilesSheet(replace: replace)
                case .remove(let path): RemoveFileSheet(path: path)
                }
            }
            .environmentObject(model)
            .environmentObject(tools)
        }
    }
}

/// The layout every dialog here shares: a title and explanation, the fields, then Cancel and the action.
private struct ToolDialog<Content: View>: View {
    let title: String
    let subtitle: String
    let action: String
    var actionDisabled = false
    var width: CGFloat = 560
    let perform: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            content()
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(action) { perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(actionDisabled)
            }
            .controlSize(.large)
            .padding(14)
        }
        .frame(width: width)
    }
}

/// A folder field with a Browse button, as in Vivado's dialogs.
private struct FolderField: View {
    let label: String
    @Binding var folder: URL

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(folder.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(folder.path)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = folder
                    if panel.runModal() == .OK, let url = panel.url { folder = url }
                }
            }
        }
    }
}

// MARK: File > Project > Save As

private struct SaveProjectAsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location = FileManager.default.homeDirectoryForCurrentUser
    @State private var includeResults = false

    var body: some View {
        ToolDialog(title: "Save Project As",
                   subtitle: "Copies the whole project to a new name and folder, then opens the copy. The original stays as it is.",
                   action: "OK", actionDisabled: problem != nil) {
            model.saveProjectAs(name: name, location: location, includeResults: includeResults)
            dismiss()
        } content: {
            Form {
                TextField("Project name", text: $name)
                FolderField(label: "Project location", folder: $location)
                Toggle("Include run results", isOn: $includeResults)
                    .help("Also copy build/ and the simulation output. Without them the copy starts with no runs.")
                Text(problem ?? "The project will be created at \(location.appendingPathComponent(name).path)")
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Accent.error)
            }
            .formStyle(.columns)
        }
        .onAppear {
            name = (model.project?.name ?? "project") + "_copy"
            if let url = model.projectURL { location = url.deletingLastPathComponent() }
        }
    }

    private var problem: String? {
        if !Project.isPlain(name) { return "Project names can use letters, digits, '_' and '-' only." }
        if FileManager.default.fileExists(atPath: location.appendingPathComponent(name).path) {
            return "\(location.appendingPathComponent(name).path) already exists."
        }
        return nil
    }
}

// MARK: File > Project > Archive

private struct ArchiveProjectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location = FileManager.default.homeDirectoryForCurrentUser
    @State private var includeResults = false

    var body: some View {
        ToolDialog(title: "Archive Project",
                   subtitle: "Saves the project as a zip file, to send to someone or keep as a snapshot.",
                   action: "OK", actionDisabled: name.isEmpty || name.contains("/")) {
            model.archiveProject(to: location.appendingPathComponent(name + ".zip"), includeResults: includeResults)
            dismiss()
        } content: {
            Form {
                TextField("Archive name", text: $name)
                FolderField(label: "Archive location", folder: $location)
                Toggle("Include run results", isOn: $includeResults)
                    .help("Also include build/ (reports, design data, the bitstream) and the simulation output.")
                Toggle("Include configuration settings", isOn: .constant(true))
                    .disabled(true)
                    .help("Every setting is in fpga-bridge.json, which is always in the archive.")
                Text(FileManager.default.fileExists(atPath: location.appendingPathComponent(name + ".zip").path)
                     ? "\(name).zip already exists there and will be replaced." : "Creates \(location.appendingPathComponent(name + ".zip").path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.columns)
        }
        .onAppear {
            name = model.project?.name ?? "project"
            if let url = model.projectURL { location = url.deletingLastPathComponent() }
        }
    }
}

// MARK: File > Project > Write Tcl

private struct WriteTclSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser
    @State private var projectScript = true
    @State private var buildScript = false

    var body: some View {
        let name = model.project?.name ?? "project"
        ToolDialog(title: "Write Project Tcl",
                   subtitle: "Writes Tcl scripts for this project, to use in Vivado on the build machine.",
                   action: "OK", actionDisabled: !projectScript && !buildScript, width: 600) {
            let written = model.writeTcl(buildScript: buildScript, projectScript: projectScript, to: folder)
            if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
            dismiss()
        } content: {
            Form {
                FolderField(label: "Output folder", folder: $folder)
                Toggle(isOn: $projectScript) {
                    Text("Project script (\(name).tcl)")
                    Text("Recreates the project in Vivado's project mode, to open it in Vivado's own window.")
                }
                Toggle(isOn: $buildScript) {
                    Text("Build script (\(name)_build.tcl)")
                    Text("The non-project script FPGA Bridge runs for a build, to run by hand.")
                }
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        }
        .onAppear { if let url = model.projectURL { folder = url } }
    }

    private var note: String {
        let inProject = model.projectURL.map { $0.standardizedFileURL == folder.standardizedFileURL } ?? false
        return inProject
            ? "Both scripts find the sources relative to where they are, so copy the whole project folder to the build machine with them. The Vivado project is created in a folder beside it."
            : "The scripts expect to be in the project folder, next to fpga-bridge.json. Saved elsewhere, move them there before running them."
    }
}

// MARK: Remove File from Project

private struct RemoveFileSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var delete = false

    var body: some View {
        ToolDialog(title: "Remove Sources", subtitle: "Are you sure you want to remove this file from the project?", action: "OK") {
            model.removeFile(path, deleteFromDisk: delete)
            dismiss()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Label(path, systemImage: "doc.text").font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                Toggle("Also delete the project local file/directory from disk", isOn: $delete)
                Text(delete ? "The file goes to the Trash, where it can be put back from the Finder."
                            : "The file stays on disk but is no longer part of the project. Adding it again with Add Sources brings it back. To keep it in the project but out of builds, use Disable File instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Edit > Find in Files / Replace in Files

private struct FindInFilesSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tools: ProjectTools
    @Environment(\.dismiss) private var dismiss
    let replace: Bool
    @State private var problem: String?
    /// Files the Replace preview will change; all of them until unticked.
    @State private var excluded: Set<String> = []
    @State private var previewed = false

    var body: some View {
        ToolDialog(title: replace ? "Replace in Files" : "Find in Files",
                   subtitle: replace
                       ? "Finds text in the project's sources and replaces it. The changes go into the open editors, unsaved, so you can check them before saving."
                       : "Finds text in the project's sources. Results appear in the Find Results tab; click one to open the file there.",
                   action: replace ? (previewed ? "Replace" : "Find") : "Find",
                   actionDisabled: tools.options.text.isEmpty || tools.isSearching || (previewed && selectedCount == 0),
                   width: replace ? 680 : 560) {
            if replace && previewed {
                model.replaceInFiles(Set(tools.results?.files ?? []).subtracting(excluded))
                dismiss()
            } else {
                run()
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    TextField("Find what", text: $tools.options.text)
                    if replace { TextField("Replace with", text: $tools.replacement) }
                    Picker("Look in", selection: $tools.scope) {
                        ForEach(ProjectTools.Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("File types", text: $tools.fileTypes, prompt: Text("All files, or e.g. *.v, *.sv"))
                    LabeledContent("Options") {
                        HStack(spacing: 14) {
                            Toggle("Match case", isOn: $tools.options.matchCase)
                            Toggle("Whole word", isOn: $tools.options.wholeWord)
                            Toggle("Regular expression", isOn: $tools.options.regularExpression)
                        }
                    }
                }
                .formStyle(.columns)
                .onChange(of: tools.options) { _, _ in previewed = false }
                .onChange(of: tools.replacement) { _, _ in previewed = false }

                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Accent.error)
                }
                if replace { preview }
            }
        }
        // Reopened after a Replace search (Find Again…), show that preview rather than starting over.
        .onAppear { if replace, tools.results?.replacement != nil, tools.undoText == nil { previewed = true } }
    }

    private var selectedCount: Int {
        (tools.results?.matches ?? []).filter { !excluded.contains($0.path) }.count
    }

    private func run() {
        problem = nil
        do { _ = try FileSearch.expression(for: tools.options) } catch { problem = error.userMessage; return }
        model.findInFiles(replacing: replace)
        if replace { previewed = true; excluded = [] } else { dismiss() }
    }

    @ViewBuilder
    private var preview: some View {
        if tools.isSearching {
            HStack {
                ProgressView(value: Double(tools.searched), total: Double(max(tools.toSearch, 1)))
                Button("Stop") { tools.cancelSearch() }
            }
        } else if previewed, let results = tools.results {
            VStack(alignment: .leading, spacing: 6) {
                Text(results.summary).font(.callout.weight(.semibold))
                List {
                    ForEach(results.files, id: \.self) { path in
                        Section {
                            ForEach(results.matches(in: path)) { match in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(match.line): \(match.lineText.trimmingCharacters(in: .whitespaces))")
                                        .strikethrough(true, color: Accent.error.opacity(0.7))
                                        .foregroundStyle(.secondary)
                                    Text("\(match.line): \((match.replacedLine ?? "").trimmingCharacters(in: .whitespaces))")
                                }
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .opacity(excluded.contains(path) ? 0.4 : 1)
                            }
                        } header: {
                            Toggle(isOn: Binding(get: { !excluded.contains(path) },
                                                 set: { if $0 { excluded.remove(path) } else { excluded.insert(path) } })) {
                                Text("\((path as NSString).lastPathComponent)  (\(results.matches(in: path).count))")
                            }
                            .help(path)
                        }
                    }
                }
                .frame(height: 220)
                Text("Unticked files are left alone.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Find Results (console tab)

/// Vivado's Find Results tab: matches grouped by file; click one to open the file at it.
struct FindResultsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tools: ProjectTools
    @AppStorage(AppearanceKey.consoleFontSize) private var fontSize = 12.0
    /// Files whose matches are folded away; every file starts open, as in Vivado.
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if tools.isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching… \(tools.searched) of \(tools.toSearch) files")
                    Button("Stop") { tools.cancelSearch() }
                } else if let results = tools.results {
                    Text(results.summary)
                }
                Spacer()
                if tools.undoText != nil {
                    Button("Undo Replace") { model.undoReplaceInFiles() }
                        .help("Put back the text the last Replace in Files changed (while it is still unsaved)")
                }
                Button("Find Again…") { tools.sheet = .find(replace: tools.results?.replacement != nil) }
                Button { tools.clearResults(); model.consoleTab = .tclConsole } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close Find Results")
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()
            if let results = tools.results {
                List {
                    ForEach(results.files, id: \.self) { path in
                        DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(path) },
                                                            set: { if $0 { collapsed.remove(path) } else { collapsed.insert(path) } })) {
                            ForEach(results.matches(in: path)) { match in
                                Button { model.reveal(match) } label: { row(match) }
                                    .buttonStyle(.plain)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").foregroundStyle(Accent.source)
                                Text((path as NSString).lastPathComponent).fontWeight(.medium)
                                Text("(\(results.matches(in: path).count))").foregroundStyle(.secondary)
                                Text((path as NSString).deletingLastPathComponent).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .font(.system(size: fontSize))
            }
        }
        .background(Theme.surface)
    }

    /// `12: wire clk;` with the match in bold.
    private func row(_ match: FileSearch.Match) -> some View {
        let line = match.lineText as NSString
        let before = line.substring(to: match.rangeInLine.location)
        let found = line.substring(with: match.rangeInLine)
        let after = line.substring(from: NSMaxRange(match.rangeInLine))
        let text = Text("\(before)\(Text(found).bold().foregroundStyle(Accent.active))\(after)")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(match.line)").foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
            text.lineLimit(1)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .contentShape(Rectangle())
        .help("\(match.path), line \(match.line), column \(match.column)")
    }
}

// MARK: Sources context menu

/// Vivado's Sources window context menu for a file or module, with Show in Finder and Copy Path added. Items that
/// need something not built yet stay visible, greyed, with the reason underneath.
struct SourceContextMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tools: ProjectTools
    let node: SourceNode

    var body: some View {
        if let path = node.path, !path.isEmpty {
            let set = model.setOf(path)
            let enabled = model.isFileEnabled(path)
            Button("Source Node Properties…") { model.showProperties(of: node) }
            Button("Open File") { model.openFile(path) }
            Divider()
            Button("Replace File…") { model.replaceFileWithPanel(path) }
            Button("Copy File Into Project") { model.copyFileIntoProject(path) }
                .disabled(!model.canCopyIntoProject(path))
            Button("Remove File from Project…") { tools.sheet = .remove(path) }
            Button(enabled ? "Disable File" : "Enable File") { model.setFileEnabled(path, !enabled) }
            if set == .design {
                Button("Move to Simulation Sources") { model.moveFile(path, to: .simulation) }
            } else if set == .simulation {
                Button("Move to Design Sources") { model.moveFile(path, to: .design) }
            }
            unavailable("Set Used In…", "FPGA Bridge uses each file by its set: design sources in synthesis and simulation, simulation sources in simulation only.")
            Divider()
            setAsTop(path: path, set: set, enabled: enabled)
            unavailable("Hierarchy Update", "The compile order is always automatic here.")
            Button("Refresh Hierarchy") { model.refreshHierarchy() }
            Divider()
            Button("Add Sources…") { model.showAddSources = true }
            Divider()
            Button("Show in Finder") { model.showInFinder(path) }
            Button("Copy Path") { model.copyPath(path) }
        } else {
            Button("Refresh Hierarchy") { model.refreshHierarchy() }
            Button("Add Sources…") { model.showAddSources = true }
        }
    }

    @ViewBuilder
    private func setAsTop(path: String, set: SourceSet?, enabled: Bool) -> some View {
        // A module row sets that module; a file row sets the module the file declares (the first, if several).
        let isModuleRow = !node.id.hasPrefix("file:")
        let module = isModuleRow
            ? node.title.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
            : model.projectURL.flatMap { ProjectOperations.modules(in: path, root: $0).first }
        if let set, set != .constraints, let module, enabled {
            let isTop = set == .simulation ? model.project?.simulationTop == module : model.project?.top == module
            Button("Set as Top") { model.setAsTop(module, in: set) }
                .disabled(isTop)
        } else {
            unavailable("Set as Top", set == .constraints ? "Constraints have no modules." : enabled ? "No module found in this file." : "The file is disabled.")
        }
    }

    private func unavailable(_ title: String, _ reason: String) -> some View {
        Button {} label: {
            Text(title)
            Text(reason)
        }
        .disabled(true)
    }
}
