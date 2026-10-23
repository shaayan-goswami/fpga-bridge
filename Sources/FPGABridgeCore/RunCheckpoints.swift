import Foundation

/// One short key per run for everything its result depends on, so a later step can tell whether the checkpoint it
/// would open on the build machine was made from the files and settings as they are now.
///
/// - synth_1: the design sources and include files, the top, part, language and synthesis settings, the IP, and the
///   Vivado install.
/// - impl_1: synth_1's key, the constraints and the implementation settings. Implementation reads the constraints
///   afresh on top of the synthesized netlist (as Vivado's own implementation run does), so a constraint change
///   reruns implementation only.
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
                         json(project.ips ?? []), files(design)])
        implementation = key(["impl_1", synthesis, json(settings.implementation), files(constraints)])
        bitstream = key(["write_bitstream", implementation, json(settings.bitstream)])
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
