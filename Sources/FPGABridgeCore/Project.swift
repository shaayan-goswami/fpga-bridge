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
    /// Synthesis, implementation, bitstream, language and simulation settings. Missing means Vivado's defaults.
    public var settings: ProjectSettings?
    /// IP from Vivado's catalog that the design uses. Recreated by every build.
    public var ips: [ProjectIP]?
    /// Files (project-relative) that stay in the project but aren't used: Vivado's Disable File. Left out by every
    /// `resolve…` call unless asked for, so builds and simulation skip them.
    public var disabled: [String]?
    /// Files (project-relative) taken out of the project with Remove File but left on disk. A project lists source
    /// folders, so a file in one stays out only by being named here. Never resolved, disabled or not.
    public var excluded: [String]?

    public static let fileName = "fpga-bridge.json"

    public init(name: String, top: String, part: String, sources: [String], constraints: [String], board: String? = nil,
                vivadoVersion: String? = nil, simulationSources: [String]? = nil, targetLanguage: String? = nil,
                simulationTop: String? = nil, settings: ProjectSettings? = nil, ips: [ProjectIP]? = nil,
                disabled: [String]? = nil, excluded: [String]? = nil) {
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
        self.settings = settings
        self.ips = ips
        self.disabled = disabled
        self.excluded = excluded
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

    /// The name becomes a directory on the build machine and part of a shell line there, so keep it plain.
    /// `top` and `part` go straight into Tcl, so they get the same treatment.
    public func validate() throws {
        guard Project.isPlain(name) else { throw ProjectError.invalid("name must use only letters, digits, '_' and '-'") }
        guard Project.isPlain(top) else { throw ProjectError.invalid("top must use only letters, digits, '_' and '-'") }
        guard Project.isPlain(part) else { throw ProjectError.invalid("part must use only letters, digits, '_' and '-'") }
        guard !sources.isEmpty else { throw ProjectError.invalid("sources must list at least one file or directory") }
        if let simulationTop, !Project.isPlain(simulationTop) {
            throw ProjectError.invalid("simulationTop must use only letters, digits, '_' and '-'")
        }
        try settings?.validate()
        var seen = Set<String>()
        for ip in ips ?? [] {
            try ip.validate()
            guard seen.insert(ip.name).inserted else { throw ProjectError.invalid("two IP are both named '\(ip.name)'") }
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

    /// Expands entries to files relative to `root`, sorted for a stable build. Disabled files are left out unless
    /// `includingDisabled` (the Sources window still lists them, greyed); excluded files are always left out.
    public func resolveSources(in root: URL, includingDisabled: Bool = false) throws -> [String] {
        enabled(try Project.expand(sources, extensions: Project.sourceExtensions, root: root), includingDisabled)
    }

    public func resolveConstraints(in root: URL, includingDisabled: Bool = false) throws -> [String] {
        enabled(try Project.expand(constraints, extensions: Project.constraintExtensions, root: root), includingDisabled)
    }

    public func resolveSimulationSources(in root: URL, includingDisabled: Bool = false) throws -> [String] {
        enabled(try Project.expand(simulationSources ?? [], extensions: Project.sourceExtensions, root: root), includingDisabled)
    }

    private func enabled(_ files: [String], _ includingDisabled: Bool) -> [String] {
        var off = Set(excluded ?? [])
        if !includingDisabled { off.formUnion(disabled ?? []) }
        return off.isEmpty ? files : files.filter { !off.contains($0) }
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

    /// The whole flow in one Vivado session, as `fpga-bridge build` runs it: synthesis, implementation and the
    /// bitstream (see `flowScript`).
    public func buildScript(sources: [String], constraints: [String]) -> String {
        flowScript(steps: RunKind.flow, sources: sources, constraints: constraints)
    }

    /// Options from the Launch Runs dialog that change the script but not the design.
    public struct FlowOptions: Equatable, Sendable {
        /// Vivado's `general.maxThreads` (Launch Runs' "Number of jobs"). Nil leaves Vivado's default.
        public var maxThreads: Int?
        public init(maxThreads: Int? = nil) { self.maxThreads = maxThreads }

        /// What `general.maxThreads` accepts.
        public static let threadRange = 1...32
    }

    /// The folder next to the job folder where each run keeps its checkpoint between builds, as the scripts (which
    /// run in the job folder) name it: `../<name>.runs`, like Vivado's `<project>.runs`.
    public var runsFolder: String { "../\(name).runs" }

    /// Non-project-mode Vivado script for consecutive steps of the flow, laid out like Vivado's own runs. Outputs
    /// go to `out/` next to the script; each run also leaves a checkpoint in its folder under `runsFolder`.
    ///
    /// - synth_1 reads the sources and constraints, synthesizes, and writes `post_synth.dcp`. As in Vivado's
    ///   synthesis run, the constraints are marked not to be used in implementation, so the checkpoint holds the
    ///   netlist without them; they are then applied to the open netlist for the synthesis reports.
    /// - impl_1 opts, places and routes, and writes `post_route.dcp`. On its own it opens `post_synth.dcp` and reads
    ///   the constraints as they are now.
    /// - write_bitstream writes the bitstream. On its own it opens `post_route.dcp`.
    ///
    /// When steps follow each other in one script, the later ones carry on with the design already open. Unless
    /// turned off, each stage also writes what the design views need (see `DesignDump`), with an RTL elaboration pass
    /// before synthesis. Settings add flags and steps.
    public func flowScript(steps: [RunKind], sources: [String], constraints: [String], options: FlowOptions = FlowOptions()) -> String {
        let settings = self.settings ?? ProjectSettings()
        let views = settings.collectDesignData
        var lines = ["# Generated by fpga-bridge. Overwritten on every build.",
                     "file mkdir out"]
        if let threads = options.maxThreads { lines.append("set_param general.maxThreads \(threads)") }
        // The bitstream step writes no design data.
        if views && steps != [.bitstream] { lines.append(DesignDump.procedures) }
        lines.append(runProcedures)
        if let vivadoVersion { lines.append(Project.versionCheck(vivadoVersion)) }
        let reapply = constraints.map { "read_xdc {\($0)}" }
        let first = steps.first

        if steps.contains(.synthesis) {
            // A new netlist makes the implementation checkpoint stale too, so neither is left behind.
            lines.append("fpgabridge_begin synth_1 impl_1")
            lines += designSetupLines
            lines += Project.readLines(sources: sources, constraints: constraints)
            lines += constraints.map { "set_property used_in_implementation false [get_files {\($0)}]" }
            let includes = Project.includeFolders(sources: sources, settings: settings)
            if views {
                // Elaborate on its own first, for the Elaborated Design view, then close it for the real synthesis.
                lines.append(Project.line("synth_design -rtl -name rtl_1 -top \(top) -part \(part)", languageOnly(settings, includes)))
                lines.append("fpgabridge_dump rtl")
                lines.append("close_design")
            }
            lines.append(Project.line("synth_design -top \(top) -part \(part)", settings.synthesis.flags(language: settings.language, includeFolders: includes)))
            lines.append("fpgabridge_checkpoint synth_1 post_synth")
            // What Open Synthesized Design shows: the netlist with the constraints applied.
            lines += reapply
            if views { lines.append("fpgabridge_dump synth") }
        }
        if steps.contains(.implementation) {
            if first == .implementation {
                lines.append("fpgabridge_begin impl_1")
                lines.append("open_checkpoint \(runsFolder)/synth_1/post_synth.dcp")
                lines += reapply
            }
            let i = settings.implementation
            lines.append(Project.line("opt_design", Project.directive(i.optDirective) + Project.words(i.optMoreOptions)))
            lines.append(Project.line("place_design", Project.directive(i.placeDirective) + Project.words(i.placeMoreOptions)))
            if i.physOpt { lines.append(Project.line("phys_opt_design", Project.directive(i.physOptDirective))) }
            lines.append(Project.line("route_design", Project.directive(i.routeDirective) + Project.words(i.routeMoreOptions)))
            if i.postRoutePhysOpt { lines.append(Project.line("phys_opt_design", Project.directive(i.physOptDirective))) }
            lines.append("fpgabridge_checkpoint impl_1 post_route")
            lines += [
                "report_timing_summary -file out/timing_summary.rpt",
                "report_utilization -file out/utilization.rpt",
            ]
            if views { lines.append("fpgabridge_dump impl") }
        }
        if steps.contains(.bitstream) {
            if first == .bitstream { lines.append("open_checkpoint \(runsFolder)/impl_1/post_route.dcp") }
            lines += settings.bitstream.properties.map { "set_property \($0.0) \($0.1) [current_design]" }
            lines.append(Project.line("write_bitstream -force", settings.bitstream.flags) + " out/\(top).bit")
        }
        lines.append("fpgabridge_done " + steps.map(\.stepName).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// What has to exist before the design's sources are read: today the IP, which is created and synthesized first
    /// (the part must be set before it is created, and its sources must exist before the design reads it). A block
    /// design would be generated here too.
    var designSetupLines: [String] {
        guard let ips, !ips.isEmpty else { return [] }
        var lines = ["set_part \(part)", "file mkdir ip"]
        for ip in ips {
            lines += ip.tclLines()
            lines.append("generate_target all [get_ips \(ip.name)]")
            lines.append("synth_ip [get_ips \(ip.name)]")
        }
        return lines
    }

    /// The staged copy of a run's manifest, which `fpgabridge_checkpoint` keeps next to the checkpoint.
    public static func stagedManifest(_ step: RunKind) -> String { "runs/\(step.runName).json" }

    /// `fpgabridge_done` marks the job finished, naming its steps, for `fpga-bridge fetch` after a lost connection.
    /// `fpgabridge_begin` clears run folders before a run starts, so a run that is stopped or fails never leaves an
    /// older checkpoint that looks current. `fpgabridge_checkpoint` writes a run's checkpoint under a temporary name
    /// and renames it (a Vivado stopped halfway through writing leaves no broken checkpoint), then puts the run's
    /// manifest next to it: the manifest's presence says the checkpoint is complete.
    var runProcedures: String {
        """
        # fpga-bridge: each run keeps its checkpoint in its own folder, so a later run can start from it.
        set fpgabridge_runs {\(runsFolder)}
        proc fpgabridge_begin {args} {
            global fpgabridge_runs
            foreach run $args { file delete -force $fpgabridge_runs/$run }
        }
        proc fpgabridge_checkpoint {run name} {
            global fpgabridge_runs
            set dir $fpgabridge_runs/$run
            file mkdir $dir
            write_checkpoint -force $dir/$name.dcp.tmp
            file rename -force $dir/$name.dcp.tmp $dir/$name.dcp
            file copy -force runs/$run.json $dir/manifest.json
        }
        proc fpgabridge_done {args} {
            set f [open done.txt w]
            puts $f $args
            close $f
        }
        """
    }

    /// Warns in the log when the Vivado that runs isn't the one the project is pinned to. Read from Vivado itself,
    /// so it holds whatever the install path looks like.
    static func versionCheck(_ pinned: String) -> String {
        "if {[version -short] ne {\(pinned)}} { puts \"WARNING: \\[FPGA Bridge\\] This project is pinned to Vivado \(pinned), but this is Vivado [version -short].\" }"
    }

    /// Header files: brought in by `include, never read on their own (Vivado's project mode marks them "Verilog Header").
    static let headerExtensions: Set<String> = ["vh", "svh"]

    /// The lines that read the design's sources and constraints into Vivado.
    static func readLines(sources: [String], constraints: [String]) -> [String] {
        var lines: [String] = []
        for file in sources {
            switch (file as NSString).pathExtension.lowercased() {
            case "vhd", "vhdl": lines.append("read_vhdl {\(file)}")
            case "sv": lines.append("read_verilog -sv {\(file)}")
            case let ext where headerExtensions.contains(ext): continue
            default: lines.append("read_verilog {\(file)}")
            }
        }
        for file in constraints { lines.append("read_xdc {\(file)}") }
        return lines
    }

    /// The script for Run Linter: the design read as a build reads it (same defines, include folders and generics),
    /// then Vivado's RTL linter. IP isn't generated, so the linter sees IP instances as black boxes.
    public func lintScript(sources: [String], constraints: [String]) -> String {
        let settings = self.settings ?? ProjectSettings()
        var lines = ["# Generated by fpga-bridge for Run Linter.", "file mkdir out"]
        lines += Project.readLines(sources: sources, constraints: constraints)
        let includes = Project.includeFolders(sources: sources, settings: settings)
        lines.append(Project.line("synth_design -lint -top \(top) -part \(part)", languageOnly(settings, includes)))
        return lines.joined(separator: "\n") + "\n"
    }

    private func languageOnly(_ settings: ProjectSettings, _ includes: [String]) -> [String] {
        ProjectSettings.Synthesis().flags(language: settings.language, includeFolders: includes)
    }

    /// Where `include looks besides the including file's own folder (Vivado looks there itself): the folders holding
    /// the project's header files, so a header can be included from anywhere, then the project's include folders.
    static func includeFolders(sources: [String], settings: ProjectSettings) -> [String] {
        var seen = Set<String>()
        let headerFolders = sources.filter { headerExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { ($0 as NSString).deletingLastPathComponent }.map { $0.isEmpty ? "." : $0 }.sorted()
        return (headerFolders + settings.language.includeDirectories).filter { seen.insert($0).inserted }
    }

    /// Everything in the project's include folders, uploaded with the sources so `include finds it on the build machine.
    public func resolveIncludeFiles(in root: URL) throws -> [String] {
        try Project.expand(settings?.language.includeDirectories ?? [], extensions: Project.sourceExtensions.union(["h", "inc"]), root: root)
    }

    /// `command` followed by each flag, space separated.
    static func line(_ command: String, _ flags: [String]) -> String { ([command] + flags).joined(separator: " ") }

    static func directive(_ name: String) -> [String] { name == "Default" ? [] : ["-directive", name] }

    static func words(_ options: String) -> [String] { options.split(separator: " ").map(String.init) }
}

extension ProjectSettings.Synthesis {
    /// The `synth_design` flags that differ from Vivado's defaults, with the language settings and where `include looks.
    func flags(language: ProjectSettings.Language, includeFolders: [String]) -> [String] {
        var f = Project.directive(directive)
        if flattenHierarchy != .rebuilt { f += ["-flatten_hierarchy", flattenHierarchy.rawValue] }
        if fsmExtraction != .auto { f += ["-fsm_extraction", fsmExtraction.rawValue] }
        if retiming { f.append("-retiming") }
        if resourceSharing != .auto { f += ["-resource_sharing", resourceSharing.rawValue] }
        if keepEquivalentRegisters { f.append("-keep_equivalent_registers") }
        if let maxBlockRAM { f += ["-max_bram", String(maxBlockRAM)] }
        if let maxDSP { f += ["-max_dsp", String(maxDSP)] }
        if noLUTCombining { f.append("-no_lc") }
        if let shregMinSize { f += ["-shreg_min_size", String(shregMinSize)] }
        if let controlSetOptThreshold { f += ["-control_set_opt_threshold", String(controlSetOptThreshold)] }
        for define in language.defines { f += ["-verilog_define", define] }
        for generic in language.generics { f += ["-generic", generic] }
        // A Tcl list, each folder braced so one with a space stays one folder.
        if !includeFolders.isEmpty { f += ["-include_dirs", "{\(includeFolders.map { "{\($0)}" }.joined(separator: " "))}"] }
        return f + Project.words(moreOptions)
    }
}

extension ProjectSettings.Bitstream {
    /// `set_property` lines (name, value) that go before `write_bitstream`.
    var properties: [(String, String)] {
        var p: [(String, String)] = []
        if compress { p.append(("BITSTREAM.GENERAL.COMPRESS", "TRUE")) }
        if let configRate { p.append(("BITSTREAM.CONFIG.CONFIGRATE", String(configRate))) }
        if let spiBusWidth { p.append(("BITSTREAM.CONFIG.SPI_BUSWIDTH", String(spiBusWidth))) }
        if unusedPin != .pulldown { p.append(("BITSTREAM.CONFIG.UNUSEDPIN", unusedPin.rawValue.capitalized)) }
        return p
    }

    var flags: [String] { (binFile ? ["-bin_file"] : []) + Project.words(moreOptions) }
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
