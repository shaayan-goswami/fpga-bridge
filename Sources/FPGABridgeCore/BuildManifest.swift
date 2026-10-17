import CryptoKit
import Foundation

/// What a build was made from, saved next to its bitstream (`build/build-manifest.json`): a fingerprint of every file
/// sent to the build machine, the git commit, Vivado's version, and the board and part. Programming shows it, and
/// warns when the files on disk no longer match the ones that were built.
public struct BuildManifest: Codable, Equatable, Sendable {
    public static let fileName = "build-manifest.json"

    public struct Git: Codable, Equatable, Sendable {
        public var commit: String
        /// The project folder had changes not yet committed, so the commit alone doesn't describe what was built.
        public var uncommittedChanges: Bool
    }

    public var project: String
    public var top: String
    public var part: String
    public var board: String?
    public var vivadoVersion: String?
    public var buildMachine: String
    public var builtAt: Date
    /// Each file sent, relative to the project, with the SHA-256 of what was sent. The project file is included: its
    /// settings change the build.
    public var files: [String: String]
    public var git: Git?

    public init(project: String, top: String, part: String, board: String?, vivadoVersion: String?, buildMachine: String,
                builtAt: Date, files: [String: String], git: Git?) {
        self.project = project
        self.top = top
        self.part = part
        self.board = board
        self.vivadoVersion = vivadoVersion
        self.buildMachine = buildMachine
        self.builtAt = builtAt
        self.files = files
        self.git = git
    }

    /// One fingerprint for the whole set of files, short enough to show.
    public var sourceID: String {
        let joined = files.keys.sorted().map { "\($0)\t\(files[$0] ?? "")" }.joined(separator: "\n")
        return String(Self.sha256(Data(joined.utf8)).prefix(12))
    }

    // MARK: Files

    /// Every file a build sends for this project: sources, constraints, include folders, and the project file.
    public static func inputs(of project: Project, root: URL) throws -> [String] {
        let sources = try project.resolveSources(in: root)
        let constraints = try project.resolveConstraints(in: root)
        let includes = try project.resolveIncludeFiles(in: root)
        return Array(Set(sources + constraints + includes + [Project.fileName])).sorted()
    }

    /// SHA-256 of each file, by its path relative to `root`. A file that can't be read is left out.
    public static func fingerprint(_ files: [String], root: URL) -> [String: String] {
        var result: [String: String] = [:]
        for file in files {
            if let data = try? Data(contentsOf: root.appendingPathComponent(file)) { result[file] = sha256(data) }
        }
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The files that differ from what was built: changed, added or removed since. Empty means the build is current.
    public func changes(project: Project, root: URL) -> [String] {
        let now = BuildManifest.fingerprint((try? BuildManifest.inputs(of: project, root: root)) ?? [], root: root)
        return Set(files.keys).union(now.keys).filter { files[$0] != now[$0] }.sorted()
    }

    // MARK: Reading and writing

    public static func load(from directory: URL) -> BuildManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode(BuildManifest.self, from: data)
    }

    public func save(to directory: URL) throws {
        try BuildManifest.encoder.encode(self).write(to: directory.appendingPathComponent(BuildManifest.fileName), options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Vivado's version as the build reported it (in the design data), or as the install path says.
    static func vivadoVersion(out: URL, vivadoPath: String) -> String? {
        for stage in ["impl", "synth", "rtl"] {
            if let text = try? String(contentsOf: out.appendingPathComponent("\(stage)_info.tsv"), encoding: .utf8) {
                let version = DesignSnapshot.parseInfo(text).vivado
                if !version.isEmpty { return version }
            }
        }
        return Project.version(in: vivadoPath)
    }

    // MARK: Git

    /// The commit the project folder is at, and whether it has uncommitted changes. Nil when it isn't in a git
    /// repository, or when git isn't set up: on a Mac without the developer tools, `/usr/bin/git` would ask to
    /// install them in a dialog, so this checks first and stays quiet.
    public static func gitState(of root: URL) -> Git? {
        var folder = root.standardizedFileURL
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            // The parent of "/" comes back as "/..", so stop at the top explicitly.
            if folder.path == "/" { return nil }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        guard let tools = try? Shell.run("/usr/bin/xcode-select", ["-p"]), tools.succeeded,
              let head = try? Shell.run("/usr/bin/git", ["-C", root.path, "rev-parse", "HEAD"]), head.succeeded,
              // The project folder, without the build folder: that is output, not input.
              let status = try? Shell.run("/usr/bin/git", ["-C", root.path, "status", "--porcelain", "--", ".",
                                                           ":(exclude)\(Remote.localOutputDir)"]), status.succeeded
        else { return nil }
        let commit = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else { return nil }
        return Git(commit: commit, uncommittedChanges: !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: Describing it

    /// What to show before programming: the build, what it was made from, and anything that no longer matches.
    public struct Summary: Equatable, Sendable {
        public var lines: [String]
        public var warnings: [String]
    }

    /// `changes` is from `changes(project:root:)`; `devicePart` is the connected FPGA ("xc7a35t"), when known.
    public func summary(changes: [String], project: Project?, devicePart: String?) -> Summary {
        var lines = ["Built \(builtAt.formatted(date: .abbreviated, time: .shortened)) on \(buildMachine)"
                     + (vivadoVersion.map { " with Vivado \($0)" } ?? "")]
        let boardName = board.flatMap { BoardCatalog.lookup($0)?.displayName } ?? board
        lines.append("For \(boardName.map { "the \($0) (\(part))" } ?? part), top module \(top)")
        var from = "From sources \(sourceID)"
        if let git { from += ", git commit \(git.commit.prefix(8))\(git.uncommittedChanges ? " plus uncommitted changes" : "")" }
        lines.append(from)

        var warnings: [String] = []
        if !changes.isEmpty {
            let named = changes.prefix(3).joined(separator: ", ") + (changes.count > 3 ? " and \(changes.count - 3) more" : "")
            warnings.append("Changed since this build: \(named). The bitstream doesn't include those changes; build again to get them.")
        }
        if let devicePart, !part.lowercased().hasPrefix(devicePart.lowercased()) {
            warnings.append("This bitstream is for \(part), but the connected FPGA is \(devicePart).")
        }
        if let project, project.top != top || project.part != part {
            warnings.append("The project is now set to \(project.top) on \(project.part), not what this bitstream was built for.")
        }
        return Summary(lines: lines, warnings: warnings)
    }
}
