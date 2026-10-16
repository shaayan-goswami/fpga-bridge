import Foundation

/// A design to build, described by `fpga-bridge.json` in the project directory.
public struct Project: Codable, Equatable, Sendable {
    public var name: String
    public var top: String
    /// Vivado part number, e.g. "xc7a35tcpg236-1" for a Basys 3.
    public var part: String
    /// Source files or directories (searched recursively for .v/.sv/.vh/.svh/.vhd).
    public var sources: [String]
    /// Constraint files or directories (searched recursively for .xdc).
    public var constraints: [String]
    /// Board id from `BoardCatalog`, recorded when the project was created with `new --board`.
    public var board: String?
    /// Vivado version this project is meant to build with, e.g. "2023.2". Different versions give different results.
    public var vivadoVersion: String?
    /// Testbench files or directories. Never sent to synthesis; used by simulation.
    public var simulationSources: [String]?
    /// Target language, "Verilog" or "VHDL" (what new files are created as).
    public var targetLanguage: String?
    /// The testbench module to simulate. Left out, the simulator picks the one nothing instantiates.
    public var simulationTop: String?

    public static let fileName = "fpga-bridge.json"

    public init(name: String, top: String, part: String, sources: [String], constraints: [String], board: String? = nil,
                vivadoVersion: String? = nil, simulationSources: [String]? = nil, targetLanguage: String? = nil,
                simulationTop: String? = nil) {
        self.name = name
        self.top = top
        self.part = part
        self.sources = sources
        self.constraints = constraints
        self.board = board
        self.vivadoVersion = vivadoVersion
        self.simulationSources = simulationSources
        self.targetLanguage = targetLanguage
        self.simulationTop = simulationTop
    }

    public static func load(from directory: URL) throws -> Project {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { throw ProjectError.missing(url.path) }
        let project = try JSONDecoder().decode(Project.self, from: data)
        try project.validate()
        return project
    }

    public func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Project.fileName), options: .atomic)
    }

    /// The name becomes a directory on Windows and part of a cmd.exe line, so keep it plain.
    /// `top` and `part` go straight into Tcl, so they get the same treatment.
    public func validate() throws {
        guard Project.isPlain(name) else { throw ProjectError.invalid("name must use only letters, digits, '_' and '-'") }
        guard Project.isPlain(top) else { throw ProjectError.invalid("top must use only letters, digits, '_' and '-'") }
        guard Project.isPlain(part) else { throw ProjectError.invalid("part must use only letters, digits, '_' and '-'") }
        guard !sources.isEmpty else { throw ProjectError.invalid("sources must list at least one file or directory") }
        if let simulationTop, !Project.isPlain(simulationTop) {
            throw ProjectError.invalid("simulationTop must use only letters, digits, '_' and '-'")
        }
        if let vivadoVersion, Project.version(in: "/Vivado/\(vivadoVersion)/") == nil {
            throw ProjectError.invalid("vivadoVersion must look like 2023.2")
        }
    }

    /// Warns when the project pins a Vivado version and the configured install is a different one. The version is
    /// read from the install path (`...\Vivado\2023.2\bin\vivado.bat`), which is how AMD lays installs out.
    public func versionWarning(vivadoPath: String) -> String? {
        guard let pinned = vivadoVersion else { return nil }
        guard let actual = Project.version(in: vivadoPath) else {
            return "this project is pinned to Vivado \(pinned), but the version can't be read from \(vivadoPath)"
        }
        return actual == pinned ? nil
            : "this project is pinned to Vivado \(pinned), but the build machine is set up for \(actual) (\(vivadoPath))"
    }

    /// Reads the version from either layout: `...\Vivado\2023.2\bin\vivado.bat` (up to 2024) or
    /// `...\2025.2\Vivado\bin\vivado.bat` (2025 on).
    public static func version(in path: String) -> String? {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        func isVersion(_ s: String) -> Bool { s.range(of: #"^\d{4}\.\d+$"#, options: .regularExpression) != nil }
        for (index, part) in parts.enumerated() where isVersion(part) {
            if index > 0, parts[index - 1] == "Vivado" { return part }
            if index + 1 < parts.count, parts[index + 1] == "Vivado" { return part }
        }
        return nil
    }

    /// Letters, digits, '_' and '-' only. No spaces: Vivado itself misbehaves on them.
    public static func isPlain(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    static let sourceExtensions: Set<String> = ["v", "sv", "vh", "svh", "vhd", "vhdl"]
    static let constraintExtensions: Set<String> = ["xdc"]

    /// Expands entries to files relative to `root`, sorted for a stable build.
    public func resolveSources(in root: URL) throws -> [String] {
        try Project.expand(sources, extensions: Project.sourceExtensions, root: root)
    }

    public func resolveConstraints(in root: URL) throws -> [String] {
        try Project.expand(constraints, extensions: Project.constraintExtensions, root: root)
    }

    public func resolveSimulationSources(in root: URL) throws -> [String] {
        try Project.expand(simulationSources ?? [], extensions: Project.sourceExtensions, root: root)
    }

    static func expand(_ entries: [String], extensions: Set<String>, root: URL) throws -> [String] {
        var result = Set<String>()
        for entry in entries {
            guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
                throw ProjectError.invalid("\(entry) must be a relative path inside the project directory")
            }
            let url = root.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw ProjectError.invalid("\(entry) does not exist")
            }
            // A symlink inside the project can point anywhere; don't send what it points at to the build machine.
            guard isInside(url, root: root) else {
                throw ProjectError.invalid("\(entry) points outside the project directory (a symlink?)")
            }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                while let item = walker?.nextObject() as? URL {
                    guard extensions.contains(item.pathExtension.lowercased()) else { continue }
                    guard isInside(item, root: root) else {
                        throw ProjectError.invalid("\(relative(item, to: root)) points outside the project directory (a symlink?)")
                    }
                    result.insert(relative(item, to: root))
                }
            } else {
                result.insert(relative(url, to: root))
            }
        }
        // File names are written into Tcl braces, so these would break (or inject into) the script.
        if let bad = result.first(where: { $0.contains("{") || $0.contains("}") || $0.contains("\\") }) {
            throw ProjectError.invalid("\(bad) has a character ({, } or \\) that can't be used in a build file name")
        }
        return result.sorted()
    }

    /// True if the file, with symlinks followed, is the project directory or under it. The project directory itself
    /// counts: "." is the default source entry.
    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base + "/")
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    /// Non-project-mode Vivado flow. Outputs go to `out/` next to the script.
    public func buildScript(sources: [String], constraints: [String]) -> String {
        var lines = ["# Generated by fpga-bridge. Overwritten on every build.",
                     "file mkdir out"]
        for file in sources {
            switch (file as NSString).pathExtension.lowercased() {
            case "vhd", "vhdl": lines.append("read_vhdl {\(file)}")
            case "sv", "svh": lines.append("read_verilog -sv {\(file)}")
            default: lines.append("read_verilog {\(file)}")
            }
        }
        for file in constraints { lines.append("read_xdc {\(file)}") }
        lines += [
            "synth_design -top \(top) -part \(part)",
            "opt_design",
            "place_design",
            "route_design",
            "report_timing_summary -file out/timing_summary.rpt",
            "report_utilization -file out/utilization.rpt",
            "write_bitstream -force out/\(top).bit",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum ProjectError: DescribedError {
    case missing(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .missing(let path): return "No \(Project.fileName) at \(path). Run `fpga-bridge new` in your project directory."
        case .invalid(let why): return "Invalid \(Project.fileName): \(why)"
        }
    }
}
