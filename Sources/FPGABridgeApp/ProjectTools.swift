import AppKit
import FPGABridgeCore
import SwiftUI

/// The state behind File > Project > Save As / Archive / Write Tcl, Edit > Find in Files / Replace in Files and the
/// Sources window's context menu. The commands themselves are on `AppModel` (below); this holds which dialog is open
/// and what the last search found.
@MainActor
final class ProjectTools: ObservableObject {
    enum Sheet: Identifiable, Equatable {
        case saveAs, archive, writeTcl
        case find(replace: Bool)
        /// Remove File from Project, for this project-relative file.
        case remove(String)

        var id: String {
            switch self {
            case .saveAs: "saveAs"
            case .archive: "archive"
            case .writeTcl: "writeTcl"
            case .find(let replace): replace ? "replace" : "find"
            case .remove(let path): "remove:\(path)"
            }
        }
    }

    /// Which sources Find in Files looks through (Vivado's "Look in").
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All Project Sources"
        case design = "Design Sources"
        case constraints = "Constraints"
        case simulation = "Simulation Sources"
        var id: String { rawValue }
    }

    /// What the last Find or Replace in Files found, for the Find Results tab and the Replace preview.
    struct Results: Equatable {
        var options: FileSearch.Options
        /// Set when searching to replace: what each match becomes.
        var replacement: String?
        var root: URL
        var matches: [FileSearch.Match]
        var filesSearched: Int
        var cancelled = false

        var files: [String] { var seen = Set<String>(); return matches.map(\.path).filter { seen.insert($0).inserted } }

        func matches(in path: String) -> [FileSearch.Match] { matches.filter { $0.path == path } }

        var summary: String {
            let count = matches.count
            let what = "\"\(options.text)\""
            let base = count == 0 ? "No matches for \(what)"
                : "\(count) \(count == 1 ? "match" : "matches") for \(what) in \(files.count) of \(filesSearched) \(filesSearched == 1 ? "file" : "files")"
            return cancelled ? base + " (stopped)" : base
        }
    }

    @Published var sheet: Sheet?
    /// How Remove and Replace delete a file: to the Trash. Tests delete outright.
    var deleteFile: ProjectOperations.Delete = ProjectOperations.moveToTrash

    // Find in Files
    @Published var options = FileSearch.Options(text: "")
    @Published var replacement = ""
    @Published var scope = Scope.all
    @Published var fileTypes = ""
    @Published private(set) var results: Results?
    @Published private(set) var isSearching = false
    @Published private(set) var searched = 0
    @Published private(set) var toSearch = 0
    /// Each file's text before the last Replace, so it can be undone while the edits are still unsaved.
    @Published private(set) var undoText: [String: String]?
    private var searchTask: Task<Void, Never>?
    /// The search whose results are showing. A search that was replaced or stopped must not write into them.
    private var generation = 0

    /// Starts a search. `files` are project-relative with the text to search (an unsaved draft) or nil to read the
    /// file from disk. Earlier results are replaced; a search already running is stopped.
    func search(_ options: FileSearch.Options, replacement: String?, files: [(path: String, draft: String?)], root: URL) throws {
        let expression = try FileSearch.expression(for: options)
        let template = replacement.map { FileSearch.template($0, options: options) }
        cancelSearch()
        generation += 1
        let mine = generation
        isSearching = true
        searched = 0
        toSearch = files.count
        results = Results(options: options, replacement: replacement, root: root, matches: [], filesSearched: 0)
        undoText = nil
        let chunks = stride(from: 0, to: files.count, by: 16).map { Array(files[$0..<min($0 + 16, files.count)]) }
        searchTask = Task { [weak self] in
            for chunk in chunks {
                // Reading and matching happen off the main thread, a few files at a time, so Cancel takes effect quickly.
                let part = await Task.detached { () -> [FileSearch.Match] in
                    chunk.flatMap { file -> [FileSearch.Match] in
                        guard let text = file.draft ?? (try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8)) else { return [] }
                        return FileSearch.matches(in: text, path: file.path, expression: expression, template: template)
                    }
                }.value
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                self.results?.matches += part
                self.results?.filesSearched += chunk.count
                self.searched += chunk.count
            }
            guard let self, self.generation == mine else { return }
            self.isSearching = false
            self.searchTask = nil
        }
    }

    /// Waits for the running search (tests).
    func waitForSearch() async { await searchTask?.value }

    func cancelSearch() {
        guard let searchTask else { return }
        searchTask.cancel()
        self.searchTask = nil
        generation += 1
        isSearching = false
        results?.cancelled = true
    }

    func clearResults() {
        cancelSearch()
        results = nil
        undoText = nil
    }

    fileprivate func rememberForUndo(_ before: [String: String]) { undoText = before }
    fileprivate func forgetUndo() { undoText = nil }
}

// MARK: Commands

extension AppModel {
    /// The project's files, design first, disabled ones included.
    var allProjectFiles: [(path: String, set: SourceSet)] {
        guard let project, let projectURL else { return [] }
        let design = (try? project.resolveSources(in: projectURL, includingDisabled: true)) ?? []
        let constraints = (try? project.resolveConstraints(in: projectURL, includingDisabled: true)) ?? []
        let simulation = (try? project.resolveSimulationSources(in: projectURL, includingDisabled: true)) ?? []
        return design.map { ($0, .design) } + constraints.map { ($0, .constraints) } + simulation.map { ($0, .simulation) }
    }

    func setOf(_ path: String) -> SourceSet? {
        guard let project, let projectURL else { return nil }
        return ProjectOperations.set(of: path, in: project, root: projectURL)
    }

    /// Runs `action` once `path` has no unsaved edits (saving or discarding them as the user chooses).
    func afterResolvingUnsaved(file path: String, _ action: @escaping () -> Void) {
        if isDirty(path) {
            unsavedPrompt = UnsavedPrompt(files: [path], proceed: action)
        } else {
            action()
        }
    }

    /// Which runs a change to a file in `set` makes out-of-date: a testbench doesn't affect synthesis.
    private func runsAffected(by sets: [SourceSet?]) -> [RunKind] {
        sets.contains { $0 == .design || $0 == .constraints } ? [.synthesis, .implementation] : []
    }

    /// Follows a file to its new name in open tabs and the selection; nil closes its tab.
    private func retarget(_ old: String, to new: String?) {
        guard let index = openTabs.firstIndex(of: .file(old)) else { return }
        if let new {
            openTabs[index] = .file(new)
            if selectedTab == .file(old) { selectedTab = .file(new) }
        } else {
            close(.file(old))
        }
        if selectedSourceID == "file:\(old)" { selectedSourceID = new.map { "file:\($0)" } }
    }

    private func perform(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { errorMessage = "Couldn't \(what): \(error.userMessage)" }
    }

    // MARK: File > Project

    func saveProjectAs(name: String, location: URL, includeResults: Bool) {
        guard let projectURL else { return }
        afterResolvingUnsaved {
            self.perform("save the project") {
                let copy = try ProjectOperations.saveAs(projectURL, name: name, location: location, includeResults: includeResults)
                self.echoTcl("save_project_as \(name) {\(location.appendingPathComponent(name).path)}\(includeResults ? "" : " -exclude_run_results")")
                self.openProject(at: copy)
            }
        }
    }

    func archiveProject(to zip: URL, includeResults: Bool) {
        guard let projectURL else { return }
        afterResolvingUnsaved {
            self.echoTcl("archive_project {\(zip.path)} -force -include_config_settings\(includeResults ? "" : " -exclude_run_results")")
            Task {
                let outcome = await Task.detached { Result { try ProjectOperations.archive(projectURL, to: zip, includeResults: includeResults) } }.value
                switch outcome {
                case .success:
                    self.tclLines.append(ConsoleLine(text: "INFO: [FPGA Bridge] archived the project to \(zip.path)", kind: .info))
                    NSWorkspace.shared.activateFileViewerSelecting([zip])
                case .failure(let error):
                    self.errorMessage = "Couldn't archive the project: \(error.userMessage)"
                }
            }
        }
    }

    /// Writes the build script and/or the project-mode script into `folder`. Returns the files written.
    @discardableResult
    func writeTcl(buildScript: Bool, projectScript: Bool, to folder: URL) -> [URL] {
        guard let project, let projectURL else { return [] }
        var written: [URL] = []
        perform("write the Tcl") {
            if projectScript {
                let url = folder.appendingPathComponent("\(project.name).tcl")
                try ProjectScripts.projectModeScript(project: project, root: projectURL).write(to: url, atomically: true, encoding: .utf8)
                echoTcl("write_project_tcl -force {\(url.path)}")
                written.append(url)
            }
            if buildScript {
                let url = folder.appendingPathComponent("\(project.name)_build.tcl")
                try ProjectScripts.buildScript(project: project, root: projectURL).write(to: url, atomically: true, encoding: .utf8)
                tclLines.append(ConsoleLine(text: "INFO: [FPGA Bridge] wrote the build script to \(url.path)", kind: .info))
                written.append(url)
            }
        }
        return written
    }

    // MARK: Sources context menu

    func removeFile(_ path: String, deleteFromDisk: Bool) {
        guard let projectURL else { return }
        afterResolvingUnsaved(file: path) {
            let set = self.setOf(path)
            self.perform("remove \((path as NSString).lastPathComponent)") {
                try ProjectOperations.remove(path, from: projectURL, deleteFromDisk: deleteFromDisk, delete: self.tools.deleteFile)
                self.echoTcl("remove_files {\(path)}")
                if deleteFromDisk { self.echoTcl("file delete -force {\(path)}") }
                self.retarget(path, to: nil)
                self.reloadProjectAfterChange(outOfDate: self.runsAffected(by: [set]))
            }
        }
    }

    func setFileEnabled(_ path: String, _ enabled: Bool) {
        guard let projectURL else { return }
        let set = setOf(path)
        perform(enabled ? "enable the file" : "disable the file") {
            try ProjectOperations.setEnabled(path, enabled, in: projectURL)
            echoTcl("set_property is_enabled \(enabled) [get_files {\(path)}]")
            reloadProjectAfterChange(outOfDate: runsAffected(by: [set]))
        }
    }

    func isFileEnabled(_ path: String) -> Bool { project.map { ProjectOperations.isEnabled(path, in: $0) } ?? true }

    func moveFile(_ path: String, to target: SourceSet) {
        guard let projectURL else { return }
        afterResolvingUnsaved(file: path) {
            let set = self.setOf(path)
            self.perform("move \((path as NSString).lastPathComponent)") {
                let moved = try ProjectOperations.move(path, to: target, in: projectURL)
                self.echoTcl("move_files -fileset [get_filesets \(target.directoryName)] [get_files {\(path)}]")
                self.retarget(path, to: moved)
                // Moving a testbench into design sources changes the design; so does taking a file out of them.
                self.reloadProjectAfterChange(outOfDate: self.runsAffected(by: [set, target]))
            }
        }
    }

    /// Set as Top for a module, in the set it belongs to (simulation sources set the testbench to simulate).
    func setAsTop(_ module: String, in set: SourceSet) {
        guard let projectURL else { return }
        perform("set the top") {
            try ProjectOperations.setTop(module, for: set, in: projectURL)
            echoTcl(set == .simulation ? "set_property top \(module) [get_filesets sim_1]" : "set_property top \(module) [current_fileset]")
            reloadProjectAfterChange(outOfDate: set == .simulation ? [] : [.synthesis, .implementation])
        }
    }

    func replaceFileWithPanel(_ path: String) {
        guard let set = setOf(path) else { return }
        let panel = NSOpenPanel()
        panel.title = "Replace File"
        panel.message = "Choose the file to use instead of \((path as NSString).lastPathComponent)."
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceFile(path, with: url, set: set)
    }

    func replaceFile(_ path: String, with url: URL, set: SourceSet? = nil) {
        guard let projectURL else { return }
        afterResolvingUnsaved(file: path) {
            let set = set ?? self.setOf(path)
            self.perform("replace \((path as NSString).lastPathComponent)") {
                let newPath = try ProjectOperations.replace(path, with: url, in: projectURL, delete: self.tools.deleteFile)
                self.echoTcl("remove_files {\(path)}")
                self.echoTcl("import_files -fileset \(set?.directoryName ?? "sources_1") -norecurse {\(url.path)}")
                self.retarget(path, to: newPath)
                self.reloadProjectAfterChange(outOfDate: self.runsAffected(by: [set]))
            }
        }
    }

    func canCopyIntoProject(_ path: String) -> Bool { project.map { ProjectOperations.canCopyIntoProject(path, in: $0) } ?? false }

    func copyFileIntoProject(_ path: String) {
        guard let projectURL else { return }
        afterResolvingUnsaved(file: path) {
            let set = self.setOf(path)
            self.perform("copy \((path as NSString).lastPathComponent) into the project") {
                let copy = try ProjectOperations.copyIntoProject(path, in: projectURL)
                self.echoTcl("import_files -fileset \(set?.directoryName ?? "sources_1") -norecurse {\(path)}")
                self.retarget(path, to: copy)
                self.reloadProjectAfterChange(outOfDate: [])
            }
        }
    }

    func showInFinder(_ path: String) {
        guard let projectURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([projectURL.appendingPathComponent(path)])
    }

    func copyPath(_ path: String) {
        guard let projectURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(projectURL.appendingPathComponent(path).path, forType: .string)
    }

    /// Vivado's Refresh Hierarchy: reads the sources again (after editing them outside the app, say).
    func refreshHierarchy() {
        reloadProjectAfterChange(outOfDate: [])
        echoTcl("update_compile_order -fileset sources_1")
    }

    /// Source Node Properties: shows the node in the Properties window.
    func showProperties(of node: SourceNode) {
        selectedSourceID = node.id
        propertiesShowsDesign = false
    }

    // MARK: Find / Replace in Files

    /// The files Find in Files looks through, with any unsaved text, filtered by scope and file types.
    func filesToSearch(scope: ProjectTools.Scope, fileTypes: String) -> [(path: String, draft: String?)] {
        allProjectFiles.filter { file in
            switch scope {
            case .all: true
            case .design: file.set == .design
            case .constraints: file.set == .constraints
            case .simulation: file.set == .simulation
            }
        }
        .filter { FileSearch.matchesFileTypes($0.path, filter: fileTypes) }
        .map { ($0.path, drafts[$0.path]) }
    }

    /// Runs Find in Files (or the search before Replace) and shows the Find Results tab.
    func findInFiles(replacing: Bool) {
        guard let projectURL else { return }
        let t = tools
        do {
            try t.search(t.options, replacement: replacing ? t.replacement : nil,
                         files: filesToSearch(scope: t.scope, fileTypes: t.fileTypes), root: projectURL)
            consoleTab = .findResults
            consoleVisible = true
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Applies the last Replace search to the chosen files. The changes go into the editor's unsaved text, so nothing
    /// is written until Save, and Undo Replace (or Don't Save) puts the files back. Returns how many matches changed.
    @discardableResult
    func replaceInFiles(_ files: Set<String>) -> Int {
        guard let results = tools.results, let replacement = results.replacement,
              let expression = try? FileSearch.expression(for: results.options) else { return 0 }
        let template = FileSearch.template(replacement, options: results.options)
        var before: [String: String] = [:]
        var total = 0
        for path in results.files where files.contains(path) {
            let text = editedText(for: path)
            let (changed, count) = FileSearch.replacing(in: text, expression: expression, template: template)
            guard count > 0 else { continue }
            before[path] = text
            updateDraft(changed, for: path)
            total += count
        }
        tools.rememberForUndo(before)
        if !before.isEmpty {
            tclLines.append(ConsoleLine(
                text: "INFO: [FPGA Bridge] replaced \(total) \(total == 1 ? "match" : "matches") in \(before.count) \(before.count == 1 ? "file" : "files"). The changes are unsaved: Save All keeps them, Undo Replace takes them back.",
                kind: .info))
        }
        return total
    }

    func undoReplaceInFiles() {
        guard let before = tools.undoText else { return }
        for (path, text) in before { updateDraft(text, for: path) }
        tools.forgetUndo()
    }

    /// Opens a file at a Find Results match and selects it.
    func reveal(_ match: FileSearch.Match) {
        let length = (editedText(for: match.path) as NSString).length
        let location = min(match.range.location, length)
        let range = NSRange(location: location, length: min(match.range.length, length - location))
        setCaret(range.location, in: match.path)
        editorReveal[match.path] = EditorReveal(range: range, token: (editorReveal[match.path]?.token ?? 0) + 1)
        openFile(match.path)
    }
}
