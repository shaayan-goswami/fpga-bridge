import Foundation

/// File > Project > Save As and Archive, and the Sources window's file commands (Remove, Enable/Disable, Move to
/// Design/Simulation Sources, Set as Top, Replace File, Copy File Into Project). Each one is plain file work on a
/// project folder: it changes files and `fpga-bridge.json`, and the app reloads the project afterwards.
///
/// Projects made by the app list their source *folders* (`blinky.srcs/sources_1`), so a file's place on disk is what
/// puts it in a set. Moving a file between sets moves it between those folders, as Vivado's "Move to Simulation
/// Sources" does for imported files. A project from the command line may list single files instead; those entries are
/// edited in the project file and the file stays where it is.
public enum ProjectOperations {
    /// How a file leaves the disk: the Trash in the app, so it can be put back; a plain delete in the tests.
    public typealias Delete = @Sendable (URL) throws -> Void

    public static let moveToTrash: Delete = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    /// Folders a build or simulation writes, relative to the project: left out of Save As and Archive unless run
    /// results are included.
    public static func resultFolders(projectName: String) -> [String] {
        [Remote.localOutputDir, "\(projectName).runs", "\(projectName).sim", "\(projectName).cache", "\(projectName).hw",
         "\(projectName).ip_user_files", ".Xil"]
    }

    // MARK: Save As

    /// Copies the project to `<location>/<name>` under a new name, renaming `<old>.srcs` (and the other
    /// `<old>.*` folders) and every path in the project file to match. Returns the new project folder.
    @discardableResult
    public static func saveAs(_ directory: URL, name: String, location: URL, includeResults: Bool) throws -> URL {
        let fm = FileManager.default
        guard Project.isPlain(name) else { throw ProjectCreatorError.invalidName }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: location.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectCreatorError.locationMissing(location.path)
        }
        let project = try Project.load(from: directory)
        let destination = location.appendingPathComponent(name)
        guard !fm.fileExists(atPath: destination.path) else { throw ProjectCreatorError.alreadyExists(destination.path) }
        let source = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard !target.hasPrefix(source + "/") else { throw ProjectOperationError.insideItself }

        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: destination) } }

        let skipped = includeResults ? [] : Set(resultFolders(projectName: project.name))
        for item in try fm.contentsOfDirectory(atPath: directory.path) where !skipped.contains(item) && item != ".DS_Store" {
            try fm.copyItem(at: directory.appendingPathComponent(item), to: destination.appendingPathComponent(renamed(item, from: project.name, to: name)))
        }

        var copy = project
        copy.name = name
        func rename(_ path: String) -> String {
            let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let first = parts.first else { return path }
            return ([renamed(first, from: project.name, to: name)] + parts.dropFirst()).joined(separator: "/")
        }
        copy.sources = copy.sources.map(rename)
        copy.constraints = copy.constraints.map(rename)
        copy.simulationSources = copy.simulationSources?.map(rename)
        copy.disabled = copy.disabled?.map(rename)
        if var settings = copy.settings {
            settings.language.includeDirectories = settings.language.includeDirectories.map(rename)
            copy.settings = settings
        }
        try copy.validate()
        try copy.save(to: destination)
        succeeded = true
        return destination
    }

    /// `<old>.srcs` becomes `<new>.srcs`, and the same for the other folders Vivado names after the project.
    static func renamed(_ item: String, from old: String, to new: String) -> String {
        item.hasPrefix(old + ".") ? new + item.dropFirst(old.count) : item
    }

    // MARK: Archive

    /// Zips the project folder (Vivado's Archive Project) with `ditto`, as the Finder's Compress does. Without run
    /// results, the build and simulation folders are left out. An existing archive at `zip` is replaced.
    public static func archive(_ directory: URL, to zip: URL, includeResults: Bool) throws {
        let fm = FileManager.default
        let project = try Project.load(from: directory)
        var source = directory
        var staging: URL?
        defer { if let staging { try? fm.removeItem(at: staging) } }
        if !includeResults {
            let base = fm.temporaryDirectory.appendingPathComponent("fpga-bridge-archive-\(UUID().uuidString)")
            let copy = base.appendingPathComponent(directory.lastPathComponent)
            staging = base
            try fm.createDirectory(at: copy, withIntermediateDirectories: true)
            let skipped = Set(resultFolders(projectName: project.name))
            for item in try fm.contentsOfDirectory(atPath: directory.path) where !skipped.contains(item) && item != ".DS_Store" {
                try fm.copyItem(at: directory.appendingPathComponent(item), to: copy.appendingPathComponent(item))
            }
            source = copy
        }
        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        let result = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", source.path, zip.path], timeout: 600)
        guard result.status == 0 else {
            throw ProjectOperationError.archiveFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Which set a file is in

    /// The set a project file belongs to, disabled or not. Nil if the project doesn't use it.
    public static func set(of path: String, in project: Project, root: URL) -> SourceSet? {
        if (try? project.resolveSources(in: root, includingDisabled: true))?.contains(path) == true { return .design }
        if (try? project.resolveConstraints(in: root, includingDisabled: true))?.contains(path) == true { return .constraints }
        if (try? project.resolveSimulationSources(in: root, includingDisabled: true))?.contains(path) == true { return .simulation }
        return nil
    }

    static func entries(of set: SourceSet, in project: Project) -> [String] {
        switch set {
        case .design: project.sources
        case .constraints: project.constraints
        case .simulation: project.simulationSources ?? []
        }
    }

    static func setEntries(_ entries: [String], of set: SourceSet, in project: inout Project) {
        switch set {
        case .design: project.sources = entries
        case .constraints: project.constraints = entries
        case .simulation: project.simulationSources = entries.isEmpty ? nil : entries
        }
    }

    /// Whether `path` is listed by name (rather than through a folder) in the set's entries.
    public static func isListedByName(_ path: String, in project: Project) -> Bool {
        SourceSet.allCases.contains { entries(of: $0, in: project).contains(path) }
    }

    /// Whether one of the set's entries (a folder, or the file itself) brings in `path`.
    static func covers(_ entries: [String], _ path: String) -> Bool {
        entries.contains { $0 == "." || $0 == path || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private static func renameDisabled(_ old: String, to new: String?, in project: inout Project) {
        guard var list = project.disabled, list.contains(old) else { return }
        list.removeAll { $0 == old }
        if let new { list.append(new) }
        project.disabled = list.isEmpty ? nil : list.sorted()
    }

    // MARK: Remove File from Project

    /// Whether Remove can leave the file on disk: only a file listed by name, since a file in a listed folder is in
    /// the project as long as it is there.
    public static func canKeepOnDiskWhenRemoved(_ path: String, in project: Project) -> Bool { isListedByName(path, in: project) }

    /// Takes a file out of the project. A file listed by name loses its entry (and is deleted only if asked); a file
    /// in a source folder has to leave the folder, so it is deleted (moved to the Trash by the app).
    public static func remove(_ path: String, from directory: URL, deleteFromDisk: Bool, delete: Delete = moveToTrash) throws {
        var project = try Project.load(from: directory)
        guard let set = set(of: path, in: project, root: directory) else { throw ProjectOperationError.notInProject(path) }
        let byName = entries(of: set, in: project).contains(path)
        guard byName || deleteFromDisk else { throw ProjectOperationError.mustDelete(path) }
        if byName {
            let remaining = entries(of: set, in: project).filter { $0 != path }
            guard set != .design || !remaining.isEmpty else { throw ProjectOperationError.lastDesignEntry }
            setEntries(remaining, of: set, in: &project)
        }
        renameDisabled(path, to: nil, in: &project)
        if deleteFromDisk { try delete(directory.appendingPathComponent(path)) }
        if set == .design { fixTop(&project, root: directory) }
        try project.save(to: directory)
    }

    // MARK: Enable / Disable File

    public static func isEnabled(_ path: String, in project: Project) -> Bool { !(project.disabled ?? []).contains(path) }

    public static func setEnabled(_ path: String, _ enabled: Bool, in directory: URL) throws {
        var project = try Project.load(from: directory)
        guard set(of: path, in: project, root: directory) != nil else { throw ProjectOperationError.notInProject(path) }
        var list = Set(project.disabled ?? [])
        if enabled { list.remove(path) } else { list.insert(path) }
        project.disabled = list.isEmpty ? nil : list.sorted()
        try project.save(to: directory)
    }

    // MARK: Move to Design / Simulation Sources

    /// Moves an HDL file between design and simulation sources and returns its new project-relative path. A file
    /// in `<name>.srcs/sources_1/...` goes to the same place under `sim_1` (and back); a file listed by name just
    /// changes lists.
    @discardableResult
    public static func move(_ path: String, to target: SourceSet, in directory: URL) throws -> String {
        var project = try Project.load(from: directory)
        guard let current = set(of: path, in: project, root: directory) else { throw ProjectOperationError.notInProject(path) }
        guard current != target else { return path }
        guard current != .constraints, target != .constraints else { throw ProjectOperationError.cannotMove(path, target) }

        if entries(of: current, in: project).contains(path) {
            let remaining = entries(of: current, in: project).filter { $0 != path }
            guard current != .design || !remaining.isEmpty else { throw ProjectOperationError.lastDesignEntry }
            setEntries(remaining, of: current, in: &project)
            setEntries(entries(of: target, in: project) + [path], of: target, in: &project)
            if current == .design || target == .design { fixTop(&project, root: directory) }
            try project.save(to: directory)
            return path
        }

        let fromFolder = ProjectCreator.relativeDirectory(for: current, projectName: project.name) + "/"
        let toFolder = ProjectCreator.relativeDirectory(for: target, projectName: project.name)
        let newPath = path.hasPrefix(fromFolder)
            ? toFolder + "/" + path.dropFirst(fromFolder.count)
            : toFolder + "/imports/" + (path as NSString).lastPathComponent
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(newPath)
        guard !fm.fileExists(atPath: destination.path) else { throw ProjectCreatorError.alreadyExists(newPath) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: directory.appendingPathComponent(path), to: destination)
        if !covers(entries(of: target, in: project), newPath) {
            setEntries(entries(of: target, in: project) + [toFolder], of: target, in: &project)
        }
        renameDisabled(path, to: newPath, in: &project)
        fixTop(&project, root: directory)
        try project.save(to: directory)
        return newPath
    }

    // MARK: Set as Top

    /// Sets the design's top module, or the testbench to simulate when `set` is `.simulation`.
    public static func setTop(_ module: String, for set: SourceSet, in directory: URL) throws {
        var project = try Project.load(from: directory)
        switch set {
        case .design: project.top = module
        case .simulation: project.simulationTop = module
        case .constraints: throw ProjectOperationError.notAModule(module)
        }
        try project.validate()
        try project.save(to: directory)
    }

    /// The modules a file declares, for Set as Top on a file.
    public static func modules(in path: String, root: URL) -> [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return [] }
        return ProjectCreator.declaredModules(in: text)
    }

    /// A top that no longer exists (its file was removed, moved or disabled) is replaced the way a new project
    /// picks one: the module nothing instantiates.
    static func fixTop(_ project: inout Project, root: URL) {
        let texts = ((try? project.resolveSources(in: root)) ?? []).compactMap {
            try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }
        let declared = Set(texts.flatMap(ProjectCreator.declaredModules))
        if !declared.isEmpty, !declared.contains(project.top), let top = try? ProjectCreator.pickTop(from: texts) {
            project.top = top
        }
    }

    // MARK: Replace File

    /// Replaces a project file with another file from disk, keeping its set and enabled state. Returns the new
    /// project-relative path (the new file's name, in the old file's folder).
    @discardableResult
    public static func replace(_ path: String, with file: URL, in directory: URL, delete: Delete = moveToTrash) throws -> String {
        var project = try Project.load(from: directory)
        guard let set = set(of: path, in: project, root: directory) else { throw ProjectOperationError.notInProject(path) }
        guard set.extensions.contains(file.pathExtension.lowercased()) else {
            throw ProjectCreatorError.unsupportedFile(file.lastPathComponent, set)
        }
        let folder = (path as NSString).deletingLastPathComponent
        let newPath = folder.isEmpty ? file.lastPathComponent : folder + "/" + file.lastPathComponent
        let fm = FileManager.default
        let target = directory.appendingPathComponent(newPath)
        if newPath != path, fm.fileExists(atPath: target.path) { throw ProjectCreatorError.alreadyExists(newPath) }
        if file.standardizedFileURL == target.standardizedFileURL { return path }

        // Copy first, so a failed copy leaves the old file in place.
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do { try fm.copyItem(at: file, to: temporary) } catch { throw ProjectCreatorError.copyFailed(error.localizedDescription) }
        if newPath == path {
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: target)
            let byName = entries(of: set, in: project).contains(path)
            if byName {
                setEntries(entries(of: set, in: project).map { $0 == path ? newPath : $0 }, of: set, in: &project)
            }
            try delete(directory.appendingPathComponent(path))
            renameDisabled(path, to: newPath, in: &project)
        }
        if set == .design { fixTop(&project, root: directory) }
        try project.save(to: directory)
        return newPath
    }

    // MARK: Copy File Into Project

    /// Whether Copy File Into Project applies: a file listed by name that isn't already in `<name>.srcs`. Files in
    /// listed folders are in the project folder already.
    public static func canCopyIntoProject(_ path: String, in project: Project) -> Bool {
        isListedByName(path, in: project) && !path.hasPrefix(ProjectCreator.srcsDirectory(projectName: project.name) + "/")
    }

    /// Copies a file listed by name into `<name>.srcs/<set>/imports` and points the project at the copy, as Vivado
    /// does for a remote source. The original stays where it was. Returns the copy's path.
    @discardableResult
    public static func copyIntoProject(_ path: String, in directory: URL) throws -> String {
        var project = try Project.load(from: directory)
        guard let set = set(of: path, in: project, root: directory) else { throw ProjectOperationError.notInProject(path) }
        guard canCopyIntoProject(path, in: project) else { throw ProjectOperationError.alreadyLocal(path) }
        let newPath = ProjectCreator.relativeDirectory(for: set, projectName: project.name) + "/imports/" + (path as NSString).lastPathComponent
        let fm = FileManager.default
        let target = directory.appendingPathComponent(newPath)
        guard !fm.fileExists(atPath: target.path) else { throw ProjectCreatorError.alreadyExists(newPath) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try fm.copyItem(at: directory.appendingPathComponent(path), to: target) }
        catch { throw ProjectCreatorError.copyFailed(error.localizedDescription) }
        setEntries(entries(of: set, in: project).map { $0 == path ? newPath : $0 }, of: set, in: &project)
        renameDisabled(path, to: newPath, in: &project)
        try project.save(to: directory)
        return newPath
    }
}

public enum ProjectOperationError: DescribedError, Equatable {
    case notInProject(String)
    case mustDelete(String)
    case lastDesignEntry
    case cannotMove(String, SourceSet)
    case notAModule(String)
    case alreadyLocal(String)
    case insideItself
    case archiveFailed(String)

    public var description: String {
        switch self {
        case .notInProject(let path): return "\(path) isn't part of this project."
        case .mustDelete(let path):
            return "\(path) is in one of the project's source folders, so it is part of the project for as long as it is there. Remove it with \"Also delete the file from disk\" (it goes to the Trash)."
        case .lastDesignEntry: return "A project needs at least one design source entry."
        case .cannotMove(let path, let set): return "\(path) can't be moved to \(set.title). Only HDL files move between design and simulation sources."
        case .notAModule(let name): return "\(name) can't be a top: constraints have no modules."
        case .alreadyLocal(let path): return "\(path) is already inside the project folder."
        case .insideItself: return "A project can't be saved inside its own folder. Choose a location outside it."
        case .archiveFailed(let why): return "Couldn't create the archive: \(why.isEmpty ? "ditto failed" : why)"
        }
    }
}
