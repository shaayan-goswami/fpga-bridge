import Foundation

/// One short key per run for everything its result depends on, so a later step can tell whether the checkpoint it
/// would open on the build machine was made from the files and settings as they are now.
///
/// - synth_1: the design sources and include files, the constraints, the top, part, language and synthesis settings,
///   the IP, and the Vivado install. Synthesis reads the constraints (Vivado marks constraint files "used in
///   synthesis" by default), so, as in Vivado, a constraint change makes synthesis out of date too.
/// - impl_1: synth_1's key and the implementation settings.
/// - write_bitstream: impl_1's key and the bitstream settings.
public struct RunKeys: Equatable, Sendable {
    public var synthesis: String
    public var implementation: String
    public var bitstream: String

    /// `design` and `constraints` are fingerprints (path to SHA-256), as `BuildManifest.fingerprint` makes them.
    public init(project: Project, design: [String: String], constraints: [String: String], vivadoPath: String) {
        let settings = project.settings ?? ProjectSettings()
        func files(_ set: [String: String]) -> String { set.keys.sorted().map { "\($0)\t\(set[$0] ?? "")" }.joined(separator: "\n") }
        func json<T: Encodable>(_ value: T) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        func key(_ parts: [String]) -> String {
            String(BuildManifest.sha256(Data(parts.joined(separator: "\n--\n").utf8)).prefix(16))
        }
        synthesis = key(["synth_1", project.top, project.part, vivadoPath, json(settings.language), json(settings.synthesis),
                         json(project.ips ?? []), files(design), files(constraints)])
        implementation = key(["impl_1", synthesis, json(settings.implementation)])
        bitstream = key(["write_bitstream", implementation, json(settings.bitstream)])
    }

    /// The keys of the project's files as they are on disk now.
    public init(project: Project, root: URL, vivadoPath: String) throws {
        let sources = try project.resolveSources(in: root)
        let design = sources + (try project.resolveIncludeFiles(in: root)).filter { !sources.contains($0) }
        self.init(project: project, design: BuildManifest.fingerprint(design, root: root),
                  constraints: BuildManifest.fingerprint(try project.resolveConstraints(in: root), root: root), vivadoPath: vivadoPath)
    }

    /// The runs a build recorded with these keys that are out of date now. The bitstream is the last step of impl_1,
    /// so a stale bitstream makes impl_1 out of date.
    public func outOfDate(_ recorded: [String: String]) -> Set<RunKind> {
        let current = current(in: recorded)
        var stale: Set<RunKind> = []
        if recorded[RunKind.synthesis.stepName] != nil, !current.contains(.synthesis) { stale.insert(.synthesis) }
        if recorded[RunKind.implementation.stepName] != nil, !current.contains(.implementation) { stale.insert(.implementation) }
        if recorded[RunKind.bitstream.stepName] != nil, !current.contains(.bitstream) { stale.insert(.implementation) }
        return stale
    }

    public func key(_ step: RunKind) -> String {
        switch step {
        case .synthesis: synthesis
        case .implementation: implementation
        case .bitstream: bitstream
        }
    }

    /// The keys of the steps up to and including `step`, by Vivado name, as manifests record them.
    public func recorded(through step: RunKind) -> [String: String] {
        let steps = RunKind.flow.prefix { $0 != step } + [step]
        return Dictionary(uniqueKeysWithValues: steps.map { ($0.stepName, key($0)) })
    }

    /// Which steps a manifest's keys show are still current: a step counts only when every step before it does too.
    public func current(in recorded: [String: String]) -> Set<RunKind> {
        var result: Set<RunKind> = []
        for step in RunKind.flow {
            guard recorded[step.stepName] == key(step) else { break }
            result.insert(step)
        }
        return result
    }
}

/// The project's `build/` folder on the Mac, which each step's results are merged into.
public enum BuildFolder {
    /// Written by RTL elaboration and synthesis. Everything else in `build/` comes from implementation or the bitstream.
    public static func isSynthesisOutput(_ name: String) -> Bool { name.hasPrefix("rtl_") || name.hasPrefix("synth_") }

    public static func isBitstreamOutput(_ name: String) -> Bool {
        ["bit", "bin"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Moves a step's results from `incoming` into `build`. A run that starts with synthesis replaces everything,
    /// since the implementation results were made from the old netlist; implementation replaces its own results
    /// and the bitstream, keeping synthesis's; the bitstream step replaces only the bitstream.
    public static func merge(_ incoming: URL, into build: URL, startingWith first: RunKind) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: build.path) {
            let stale: Bool
            switch first {
            case .synthesis: stale = true
            case .implementation: stale = !isSynthesisOutput(name)
            case .bitstream: stale = isBitstreamOutput(name)
            }
            if stale { try fm.removeItem(at: build.appendingPathComponent(name)) }
        }
        for name in try fm.contentsOfDirectory(atPath: incoming.path) {
            let dest = build.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: incoming.appendingPathComponent(name), to: dest)
        }
    }
}
