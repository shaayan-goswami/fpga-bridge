import Foundation

/// File > Project > Write Tcl. Two scripts from one project:
///
/// - the **build script** FPGA Bridge runs on the build machine (Vivado's non-project mode), to run by hand;
/// - a **project-mode script** that recreates the project in Vivado (`create_project`, `add_files`, the top, the
///   settings as run properties), so it can be opened in Vivado's own window on the PC, like `write_project_tcl`.
public enum ProjectScripts {
    /// The build script, with a note on how to run it by hand.
    public static func buildScript(project: Project, root: URL) throws -> String {
        let sources = try project.resolveSources(in: root)
        let constraints = try project.resolveConstraints(in: root)
        return """
        # The script FPGA Bridge runs for "\(project.name)" (Vivado non-project mode). To run it by hand, copy the project
        # folder to the build machine and, from that folder:
        #   vivado -mode batch -source \(project.name)_build.tcl
        # Results are written to out/.

        """ + project.buildScript(sources: sources, constraints: constraints)
    }

    /// A Tcl script that recreates the project in Vivado's project mode. It is meant to sit in the project folder,
    /// next to `fpga-bridge.json`: it finds the sources relative to itself and creates the Vivado project in a
    /// `<name>_vivado` folder beside the project folder (not inside it, so a project whose sources entry is `.` doesn't
    /// pick up Vivado's generated files).
    public static func projectModeScript(project: Project, root: URL) throws -> String {
        let design = try project.resolveSources(in: root, includingDisabled: true)
        let constraints = try project.resolveConstraints(in: root, includingDisabled: true)
        let simulation = try project.resolveSimulationSources(in: root, includingDisabled: true)
        let settings = project.settings ?? ProjectSettings()
        let disabled = Set(project.disabled ?? [])

        var lines = [
            "# Recreates the FPGA Bridge project \"\(project.name)\" as a Vivado project (project mode), so it opens in Vivado's",
            "# own window. Written by FPGA Bridge's File > Project > Write Tcl.",
            "#",
            "# Keep this file in the project folder, next to fpga-bridge.json, and run it in Vivado's Tcl Console:",
            "#   source {<project folder>/\(project.name).tcl}",
            "# or from a command prompt in the project folder:",
            "#   vivado -mode batch -source \(project.name).tcl",
            "# The Vivado project is created in \(project.name)_vivado beside the project folder. Sources are added, not",
            "# copied, so Vivado and FPGA Bridge edit the same files. Set ::origin_dir_loc first to read them from elsewhere.",
            "",
            "set origin_dir [file dirname [file normalize [info script]]]",
            "if {[info exists ::origin_dir_loc]} { set origin_dir $::origin_dir_loc }",
            "set proj_dir [file join [file dirname $origin_dir] \(project.name)_vivado]",
            "",
            "create_project \(project.name) $proj_dir -part \(project.part) -force",
            "set_property target_language \(project.targetLanguage == "VHDL" ? "VHDL" : "Verilog") [current_project]",
            "set_property simulator_language Mixed [current_project]",
            "set_property default_lib xil_defaultlib [current_project]",
        ]
        if let board = project.board {
            lines.append("# Board: \(BoardCatalog.lookup(board)?.displayName ?? board). Set board_part here if its board files are installed.")
        }

        func addFiles(_ files: [String], fileset: String, title: String) {
            guard !files.isEmpty else { return }
            lines += ["", "# \(title)", "add_files -norecurse -fileset \(fileset) [list \\"]
            lines += files.map { "  \(path($0)) \\" }
            lines.append("]")
            for file in files where Project.headerExtensions.contains((file as NSString).pathExtension.lowercased()) {
                lines.append("set_property file_type {Verilog Header} [get_files \(path(file))]")
            }
        }
        addFiles(design, fileset: "sources_1", title: "Design sources")
        addFiles(constraints, fileset: "constrs_1", title: "Constraints")
        addFiles(simulation, fileset: "sim_1", title: "Simulation sources")

        let off = (design + constraints + simulation).filter(disabled.contains)
        if !off.isEmpty {
            lines += ["", "# Disabled in FPGA Bridge"]
            lines += off.map { "set_property is_enabled false [get_files \(path($0))]" }
        }

        lines += ["", "# Tops", "set_property top \(project.top) [get_filesets sources_1]"]
        if let tb = project.simulationTop {
            lines += ["set_property top \(tb) [get_filesets sim_1]", "set_property top_lib xil_defaultlib [get_filesets sim_1]"]
        }

        // How HDL is read, for synthesis and simulation alike (FPGA Bridge's simulation uses the same settings).
        let language = settings.language
        let includes = Project.includeFolders(sources: design, settings: settings)
        var languageLines: [String] = []
        for fileset in ["sources_1", "sim_1"] {
            if !language.defines.isEmpty { languageLines.append("set_property verilog_define {\(language.defines.joined(separator: " "))} [get_filesets \(fileset)]") }
            if !includes.isEmpty { languageLines.append("set_property include_dirs [list \(includes.map(path).joined(separator: " "))] [get_filesets \(fileset)]") }
            if !language.generics.isEmpty { languageLines.append("set_property generic {\(language.generics.joined(separator: " "))} [get_filesets \(fileset)]") }
        }
        if !languageLines.isEmpty { lines += ["", "# Language options (Settings > General / Elaboration)"] + languageLines }

        for ip in project.ips ?? [] {
            guard let p = ip.vlnvParts else { continue }
            lines += ["", "# IP \(ip.name)",
                      "create_ip -name \(p[2]) -vendor \(p[0]) -library \(p[1]) -version \(p[3]) -module_name \(ip.name)"]
            if !ip.config.isEmpty {
                let pairs = ip.config.keys.sorted().map { "\($0) {\(ip.config[$0] ?? "")}" }.joined(separator: " ")
                lines.append("set_property -dict [list \(pairs)] [get_ips \(ip.name)]")
            }
            lines.append("generate_target all [get_ips \(ip.name)]")
        }

        let runs = runProperties(settings)
        if !runs.isEmpty { lines += ["", "# Run settings (Settings > Synthesis / Implementation / Bitstream)"] + runs }

        // Bitstream properties belong to the design, not the run: Vivado's own Edit Device Properties writes them to a
        // constraints file, so do the same, for implementation only.
        let properties = settings.bitstream.properties
        if !properties.isEmpty {
            lines += ["", "# Bitstream properties, in a constraints file used by implementation only",
                      "file mkdir $proj_dir",
                      "set xdc [file join $proj_dir bitstream_settings.xdc]",
                      "set f [open $xdc w]"]
            lines += properties.map { "puts $f {set_property \($0.0) \($0.1) [current_design]}" }
            lines += ["close $f",
                      "add_files -norecurse -fileset constrs_1 $xdc",
                      "set_property used_in_synthesis false [get_files $xdc]"]
        }

        lines += ["", "puts \"INFO: \\[FPGA Bridge\\] created project \(project.name) in $proj_dir\""]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `set_property` lines for synth_1 and impl_1 that match the settings FPGA Bridge's own build uses.
    static func runProperties(_ settings: ProjectSettings) -> [String] {
        var lines: [String] = []
        func set(_ property: String, _ value: String, _ run: String) {
            lines.append(property.contains(" ")
                ? "set_property -name {\(property)} -value {\(value)} -objects [get_runs \(run)]"
                : "set_property \(property) \(value) [get_runs \(run)]")
        }
        let s = settings.synthesis
        if s.directive != "Default" { set("STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE", s.directive, "synth_1") }
        if s.flattenHierarchy != .rebuilt { set("STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY", s.flattenHierarchy.rawValue, "synth_1") }
        if s.fsmExtraction != .auto { set("STEPS.SYNTH_DESIGN.ARGS.FSM_EXTRACTION", s.fsmExtraction.rawValue, "synth_1") }
        if s.retiming { set("STEPS.SYNTH_DESIGN.ARGS.RETIMING", "true", "synth_1") }
        if s.resourceSharing != .auto { set("STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING", s.resourceSharing.rawValue, "synth_1") }
        if s.keepEquivalentRegisters { set("STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS", "true", "synth_1") }
        if let n = s.maxBlockRAM { set("STEPS.SYNTH_DESIGN.ARGS.MAX_BRAM", String(n), "synth_1") }
        if let n = s.maxDSP { set("STEPS.SYNTH_DESIGN.ARGS.MAX_DSP", String(n), "synth_1") }
        if !s.moreOptions.isEmpty { set("STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS", s.moreOptions, "synth_1") }

        let i = settings.implementation
        if i.optDirective != "Default" { set("STEPS.OPT_DESIGN.ARGS.DIRECTIVE", i.optDirective, "impl_1") }
        if !i.optMoreOptions.isEmpty { set("STEPS.OPT_DESIGN.ARGS.MORE OPTIONS", i.optMoreOptions, "impl_1") }
        if i.placeDirective != "Default" { set("STEPS.PLACE_DESIGN.ARGS.DIRECTIVE", i.placeDirective, "impl_1") }
        if !i.placeMoreOptions.isEmpty { set("STEPS.PLACE_DESIGN.ARGS.MORE OPTIONS", i.placeMoreOptions, "impl_1") }
        // Vivado's own default enables phys_opt_design after placement, so only turning it off needs a line.
        if i.physOpt {
            if i.physOptDirective != "Default" { set("STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE", i.physOptDirective, "impl_1") }
        } else {
            set("STEPS.PHYS_OPT_DESIGN.IS_ENABLED", "false", "impl_1")
        }
        if i.routeDirective != "Default" { set("STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE", i.routeDirective, "impl_1") }
        if !i.routeMoreOptions.isEmpty { set("STEPS.ROUTE_DESIGN.ARGS.MORE OPTIONS", i.routeMoreOptions, "impl_1") }
        if i.postRoutePhysOpt {
            set("STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED", "true", "impl_1")
            if i.physOptDirective != "Default" { set("STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE", i.physOptDirective, "impl_1") }
        }

        let b = settings.bitstream
        if b.binFile { set("STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE", "true", "impl_1") }
        if !b.moreOptions.isEmpty { set("STEPS.WRITE_BITSTREAM.ARGS.MORE OPTIONS", b.moreOptions, "impl_1") }
        return lines
    }

    /// A project file's path for Tcl: `[file normalize "$origin_dir/<path>"]`. Inside double quotes only `$`, `[`,
    /// `\` and `"` are special; the project never allows `\`, and the rest are escaped.
    static func path(_ relative: String) -> String {
        var escaped = ""
        for ch in relative {
            if "$[]\"".contains(ch) { escaped.append("\\") }
            escaped.append(ch)
        }
        return relative == "." ? "[file normalize \"$origin_dir\"]" : "[file normalize \"$origin_dir/\(escaped)\"]"
    }
}
