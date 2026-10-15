import Foundation

/// The three source sets of a Vivado project.
public enum SourceSet: String, CaseIterable, Identifiable {
    case design, constraints, simulation

    public var id: String { rawValue }

    /// Directory name inside `<project>.srcs`, as in Vivado.
    public var directoryName: String {
        switch self {
        case .design: "sources_1"
        case .constraints: "constrs_1"
        case .simulation: "sim_1"
        }
    }

    public var title: String {
        switch self {
        case .design: "Design Sources"
        case .constraints: "Constraints"
        case .simulation: "Simulation Sources"
        }
    }

    var extensions: Set<String> {
        switch self {
        case .design, .simulation: Project.sourceExtensions
        case .constraints: Project.constraintExtensions
        }
    }
}

/// A file the user asked to create from scratch.
public struct NewFile: Equatable {
    public var set: SourceSet
    /// File name; an extension is added from the project language when missing.
    public var name: String
    /// From the Define Module dialog. Without it the module is named after the file and has no ports.
    public var module: ModuleDefinition?

    public init(set: SourceSet, name: String, module: ModuleDefinition? = nil) {
        self.set = set
        self.name = name
        self.module = module
    }
}

/// Everything the New Project wizard collects.
public struct NewProjectRequest {
    public var name: String
    /// The folder the user picked. With `createSubdirectory` the project goes in `<location>/<name>`.
    public var location: URL
    public var createSubdirectory = true
    public var part: String
    public var board: String?
    public var language = "Verilog"
    public var designSources: [URL] = []
    public var constraints: [URL] = []
    public var simulationSources: [URL] = []
    /// Files to create empty (from a template), like the wizard's "Create File".
    public var newFiles: [NewFile] = []
    public var vivadoVersion: String?

    public init(name: String, location: URL, part: String, board: String? = nil) {
        self.name = name
        self.location = location
        self.part = part
        self.board = board
    }
}

public enum ProjectCreatorError: DescribedError, Equatable {
    case invalidName
    case locationMissing(String)
    case alreadyExists(String)
    case unsupportedFile(String, SourceSet)
    case copyFailed(String)

    public var description: String {
        switch self {
        case .invalidName:
            return "Project names can use letters, digits, '_' and '-' only. Vivado also advises against spaces."
        case .locationMissing(let path): return "The folder \(path) does not exist."
        case .alreadyExists(let path): return "\(path) already exists. Pick a different name or location."
        case .unsupportedFile(let name, let set): return "\(name) can't be added to \(set.title)."
        case .copyFailed(let why): return "Could not copy a file into the project: \(why)"
        }
    }
}

/// Creates and extends projects on disk using Vivado's folder layout:
///
///     <name>/
///       fpga-bridge.json            (Vivado's .xpr)
///       <name>.srcs/sources_1/{imports,new}
///       <name>.srcs/constrs_1/{imports,new}
///       <name>.srcs/sim_1/{imports,new}
///       <name>.runs/                (created by runs)
///
/// Added files are always copied into `imports`, like Vivado's "Copy sources into project". The project file
/// can only reference files inside the project folder.
public enum ProjectCreator {
    public static func srcsDirectory(projectName: String) -> String { "\(projectName).srcs" }

    /// Project-relative path of a source set's directory, e.g. `blinky.srcs/sources_1`.
    public static func relativeDirectory(for set: SourceSet, projectName: String) -> String {
        "\(srcsDirectory(projectName: projectName))/\(set.directoryName)"
    }

    /// Creates the project and returns its directory.
    @discardableResult
    public static func create(_ request: NewProjectRequest) throws -> URL {
        let fm = FileManager.default
        guard Project.isPlain(request.name) else { throw ProjectCreatorError.invalidName }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: request.location.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectCreatorError.locationMissing(request.location.path)
        }
        let directory = request.createSubdirectory
            ? request.location.appendingPathComponent(request.name) : request.location
        if request.createSubdirectory, fm.fileExists(atPath: directory.path) {
            throw ProjectCreatorError.alreadyExists(directory.path)
        }
        if fm.fileExists(atPath: directory.appendingPathComponent(Project.fileName).path) {
            throw ProjectCreatorError.alreadyExists(directory.appendingPathComponent(Project.fileName).path)
        }

        // Check the files before creating anything, so a bad file leaves no half-made project.
        let groups: [(SourceSet, [URL])] = [
            (.design, request.designSources), (.constraints, request.constraints), (.simulation, request.simulationSources),
        ]
        for (set, files) in groups {
            for file in files where !set.extensions.contains(file.pathExtension.lowercased()) {
                throw ProjectCreatorError.unsupportedFile(file.lastPathComponent, set)
            }
        }

        for file in request.newFiles { _ = try resolve(file, language: request.language) }

        // Anything still going wrong below (disk full, permissions) must not leave a half-made project behind.
        var succeeded = false
        defer {
            if !succeeded {
                let leftover = request.createSubdirectory
                    ? [directory] : [directory.appendingPathComponent(srcsDirectory(projectName: request.name))]
                for url in leftover { try? fm.removeItem(at: url) }
            }
        }

        for set in SourceSet.allCases {
            let base = directory.appendingPathComponent(relativeDirectory(for: set, projectName: request.name))
            for sub in ["imports", "new"] {
                try fm.createDirectory(at: base.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
        }
        for (set, files) in groups {
            try copy(files, into: set, projectName: request.name, directory: directory)
        }
        for file in request.newFiles {
            try createFile(file, language: request.language, projectName: request.name, directory: directory,
                           part: request.part)
        }

        let project = Project(
            name: request.name,
            top: (try? detectTop(in: directory, projectName: request.name)) ?? request.name,
            part: request.part,
            sources: [relativeDirectory(for: .design, projectName: request.name)],
            constraints: [relativeDirectory(for: .constraints, projectName: request.name)],
            board: request.board,
            vivadoVersion: request.vivadoVersion,
            simulationSources: [relativeDirectory(for: .simulation, projectName: request.name)],
            targetLanguage: request.language)
        try project.save(to: directory)
        succeeded = true
        return directory
    }

    /// Adds files to an existing project's source set (Flow Navigator > Add Sources). Returns the project-relative
    /// paths of the copies. A file with the same name replaces the old copy.
    @discardableResult
    public static func add(_ files: [URL], to set: SourceSet, projectDirectory: URL) throws -> [String] {
        let project = try Project.load(from: projectDirectory)
        for file in files where !set.extensions.contains(file.pathExtension.lowercased()) {
            throw ProjectCreatorError.unsupportedFile(file.lastPathComponent, set)
        }
        let copied = try copy(files, into: set, projectName: project.name, directory: projectDirectory)

        // Adding a design source can change which module is the top.
        if set == .design, let top = try? detectTop(in: projectDirectory, projectName: project.name),
           !project.top.isEmpty, top != project.top {
            // Keep a top the user chose if it still exists; only fix a top that no longer does.
            let known = (try? moduleNames(in: projectDirectory, project: project)) ?? []
            if !known.contains(project.top) {
                var updated = project
                updated.top = top
                try updated.save(to: projectDirectory)
            }
        }
        return copied
    }

    @discardableResult
    private static func copy(_ files: [URL], into set: SourceSet, projectName: String, directory: URL) throws -> [String] {
        let fm = FileManager.default
        let relative = "\(relativeDirectory(for: set, projectName: projectName))/imports"
        let dest = directory.appendingPathComponent(relative)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var result: [String] = []
        for file in files {
            let target = dest.appendingPathComponent(file.lastPathComponent)
            do {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: file, to: target)
            } catch { throw ProjectCreatorError.copyFailed(error.localizedDescription) }
            result.append("\(relative)/\(file.lastPathComponent)")
        }
        return result
    }

    /// Writes a starter file into `<set>/new`, like Vivado's "Create File".
    /// Checks a new file's name and works out its base name and extension.
    static func resolve(_ file: NewFile, language: String) throws -> (base: String, ext: String) {
        let base = (file.name as NSString).deletingPathExtension
        guard Project.isPlain(base) else { throw ProjectCreatorError.invalidName }
        var ext = (file.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = file.set == .constraints ? "xdc" : (language == "VHDL" ? "vhd" : "v") }
        guard file.set.extensions.contains(ext) else { throw ProjectCreatorError.unsupportedFile(file.name, file.set) }
        if file.set != .constraints {
            if let module = file.module {
                try module.validate()
            } else if HDLTemplate.isReservedWord(base) {
                // Without a Define Module step the module is named after the file.
                throw ModuleDefinitionError.reservedWord(base)
            }
        }
        return (base, ext)
    }

    /// Writes a new file into `<set>/new`, like Vivado's Create Source File followed by Define Module.
    @discardableResult
    public static func createFile(_ file: NewFile, language: String, projectName: String, directory: URL,
                                  part: String = "") throws -> String {
        let (base, ext) = try resolve(file, language: language)

        let relative = "\(relativeDirectory(for: file.set, projectName: projectName))/new/\(base).\(ext)"
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = HDLTemplate.Context(projectName: projectName, part: part)
        let module = file.module ?? ModuleDefinition(name: HDLTemplate.isIdentifier(base) ? base : "\(base)_module")
        let text: String
        switch (file.set, ext) {
        case (.constraints, _): text = HDLTemplate.constraints(context: context)
        case (_, "vhd"), (_, "vhdl"): text = HDLTemplate.vhdl(module, context: context)
        default: text = HDLTemplate.verilog(module, context: context)
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw ProjectCreatorError.copyFailed(error.localizedDescription) }
        return relative
    }

    // MARK: Top module detection

    static func moduleNames(in directory: URL, project: Project) throws -> [String] {
        try project.resolveSources(in: directory).flatMap { path -> [String] in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) else { return [] }
            return declaredModules(in: text)
        }
    }

    /// Picks the module nothing else instantiates, like Vivado's automatic top. With several candidates the first
    /// by name wins; with none (a cycle) the first module does.
    public static func detectTop(in directory: URL, projectName: String) throws -> String {
        let probe = Project(name: projectName, top: "x", part: "x", sources: [relativeDirectory(for: .design, projectName: projectName)],
                            constraints: [])
        let files = try probe.resolveSources(in: directory)
        let texts = files.compactMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
        return try pickTop(from: texts)
    }

    static func pickTop(from texts: [String]) throws -> String {
        let declared = texts.flatMap(declaredModules)
        guard !declared.isEmpty else { throw ProjectCreatorError.copyFailed("no Verilog or SystemVerilog modules found") }
        let all = texts.map(stripComments).joined(separator: "\n")
        let instantiated = Set(declared.filter { name in
            let pattern = "(?<![A-Za-z0-9_$])\(NSRegularExpression.escapedPattern(for: name))\\s*(#\\s*\\(|[A-Za-z_][A-Za-z0-9_$]*\\s*\\()"
            // Instantiations look like `name inst (` or `name #(...)`. The declaration `module name (` is excluded below.
            let matches = (try? NSRegularExpression(pattern: pattern))?
                .matches(in: all, range: NSRange(all.startIndex..., in: all)) ?? []
            return matches.contains { match in
                let start = all.index(all.startIndex, offsetBy: match.range.location)
                let before = all[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
                return !before.hasSuffix("module") && !before.hasSuffix("macromodule")
            }
        })
        let roots = declared.filter { !instantiated.contains($0) }
        return roots.sorted().first ?? declared[0]
    }

    public static func declaredModules(in text: String) -> [String] {
        let source = stripComments(text)
        guard let regex = try? NSRegularExpression(pattern: "\\bmodule\\s+([A-Za-z_][A-Za-z0-9_$]*)") else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    public static func stripComments(_ text: String) -> String {
        var result = text
        for pattern in ["//[^\\n]*", "/\\*[\\s\\S]*?\\*/"] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }
}
