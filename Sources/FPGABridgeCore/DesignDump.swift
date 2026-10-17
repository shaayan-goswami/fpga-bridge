import Foundation

/// The Tcl that makes Vivado write out what the app's design views show. It is added to the build script and runs
/// inside the same Vivado session, with the design open at three points: after RTL elaboration (`rtl`), after
/// synthesis (`synth`) and after routing (`impl`). Everything the views show is saved on the Mac this way, so an
/// opened design never needs the build machine to be awake.
///
/// Each stage writes into `out/`:
///   `<stage>_cells.tsv`   one line per cell: name, cell type, 1 if it is a primitive, source file, source line
///   `<stage>_ports.tsv`   one line per port: name, direction, package pin, I/O standard, slew, drive, pull type
///   `<stage>_pins.tsv`    one line per cell pin: name, direction, 1 if it is a clock pin
///   `<stage>_conn.tsv`    one line per connection: net, net type, the pin or port it reaches, `pin` or `port`
///   `<stage>_props.tsv`   every property with a value: object kind (cell, net, port), name, property, value
///   `<stage>_info.tsv`    key and value lines: stage, design, part, top, Vivado version, and what was left out
/// and a few reports for the stage (see `reports`). Source files are written relative to the project, as the Mac
/// knows them. Everything is wrapped in `catch`: a failure here must never fail the build, so the worst case is a
/// view with less in it.
public enum DesignDump {
    /// File names written for a stage, so the app and the script agree.
    public static func cellsFile(_ stage: String) -> String { "\(stage)_cells.tsv" }
    public static func portsFile(_ stage: String) -> String { "\(stage)_ports.tsv" }
    public static func infoFile(_ stage: String) -> String { "\(stage)_info.tsv" }
    public static func pinsFile(_ stage: String) -> String { "\(stage)_pins.tsv" }
    public static func connectionsFile(_ stage: String) -> String { "\(stage)_conn.tsv" }
    public static func propertiesFile(_ stage: String) -> String { "\(stage)_props.tsv" }

    /// Above these sizes the per-object files are left out, so a huge design still builds in reasonable time and the
    /// download stays small. The hierarchy and ports are always written.
    public static let maxConnectivityCells = 150_000
    public static let maxPropertyObjects = 40_000

    /// Properties never written: routing strings can be megabytes per net, and these are long or meaningless here.
    public static let skippedProperties = ["ROUTE", "FIXED_ROUTE", "RELATIVE_ROUTE", "HIERARCHICALNAME", "XLNX_LINE_COL", "FILE_NAMES"]

    /// Reports written per stage: (file name, Tcl command that writes `out/<file>`). Optional extras are skipped by
    /// Vivado versions that lack them.
    public static let reports: [String: [(file: String, command: String)]] = [
        "rtl": [
            ("rtl_drc.rpt", "report_drc -file out/rtl_drc.rpt"),
            ("rtl_methodology.rpt", "report_methodology -file out/rtl_methodology.rpt"),
        ],
        "synth": [
            ("synth_utilization.rpt", "report_utilization -file out/synth_utilization.rpt"),
            ("synth_timing_summary.rpt", "report_timing_summary -file out/synth_timing_summary.rpt"),
            ("synth_clocks.rpt", "report_clocks -file out/synth_clocks.rpt"),
            ("synth_clock_networks.rpt", "report_clock_networks -file out/synth_clock_networks.rpt"),
            ("synth_clock_interaction.rpt", "report_clock_interaction -file out/synth_clock_interaction.rpt"),
            ("synth_methodology.rpt", "report_methodology -file out/synth_methodology.rpt"),
            ("synth_drc.rpt", "report_drc -file out/synth_drc.rpt"),
            ("synth_power.rpt", "report_power -file out/synth_power.rpt"),
            ("synth_noise.rpt", "report_ssn -format txt -file out/synth_noise.rpt"),
        ],
        "impl": [
            ("timing_paths.rpt", "report_timing -max_paths 10 -nworst 1 -sort_by group -file out/timing_paths.rpt"),
            ("clocks.rpt", "report_clocks -file out/clocks.rpt"),
            ("clock_utilization.rpt", "report_clock_utilization -file out/clock_utilization.rpt"),
            ("clock_networks.rpt", "report_clock_networks -file out/clock_networks.rpt"),
            ("clock_interaction.rpt", "report_clock_interaction -file out/clock_interaction.rpt"),
            ("io.rpt", "report_io -file out/io.rpt"),
            ("route_status.rpt", "report_route_status -file out/route_status.rpt"),
            ("drc.rpt", "report_drc -file out/drc.rpt"),
            ("methodology.rpt", "report_methodology -file out/methodology.rpt"),
            ("power.rpt", "report_power -file out/power.rpt"),
            ("noise.rpt", "report_ssn -format txt -file out/noise.rpt"),
        ],
    ]

    /// The procedure the build script calls as `fpgabridge_dump <stage>`.
    public static var procedures: String {
        func reportLines(_ stage: String) -> String {
            (reports[stage] ?? []).map { "        catch { \($0.command) }" }.joined(separator: "\n")
        }
        let skipped = skippedProperties.joined(separator: " ")
        return """
        # fpga-bridge: write the netlist, connections, properties and reports the app's design views show.
        # Never fails the build.
        proc fpgabridge_clean {v} { return [string map [list "\\t" " " "\\n" " " "\\r" ""] [string range $v 0 1999]] }
        proc fpgabridge_relative {path} {
            set here "[pwd]/"
            # Windows paths may differ in the case of the drive letter, so compare without case.
            if {[string first [string tolower $here] [string tolower $path]] == 0} { return [string range $path [string length $here] end] }
            return $path
        }
        # One query per property for a whole group of objects at once: cells are grouped by type, since each type has
        # its own list of properties. Vivado leaves empty values out of a bulk get_property, so when some objects have
        # no value the query is repeated on just the ones that do, keeping names and values in line. (A filter can't
        # be used alone: it treats a boolean that is 0 as empty.)
        proc fpgabridge_props_of {f kind objs} {
            if {[llength $objs] == 0} { return }
            set skip {\(skipped)}
            set all_names [get_property NAME $objs]
            set first [lindex $objs 0]
            foreach p [list_property $first] {
                if {[lsearch -exact $skip $p] >= 0} { continue }
                if {[llength $objs] == 1} {
                    # One object: the value is a plain string, which a list split would break at its spaces.
                    set v [get_property -quiet $p $first]
                    if {$v ne ""} { puts $f "$kind\t$all_names\t$p\t[fpgabridge_clean $v]" }
                    continue
                }
                set values [get_property -quiet $p $objs]
                set these $all_names
                set v0 [get_property -quiet $p $first]
                if {[llength $values] == 0 && $v0 eq ""} { continue }
                if {[llength $values] == [llength $objs] && [lindex $values 0] eq $v0} {
                    # The bulk answer lines up with the objects.
                } elseif {[llength $objs] <= 5000} {
                    # Vivado leaves some values out of a bulk answer (empty ones, and defaults such as IS_LOC_FIXED
                    # on unplaced cells), so ask each object. A filter would also drop a boolean that is 0.
                    set values {}
                    foreach o $objs { lappend values [get_property -quiet $p $o] }
                } else {
                    # Too many to ask one by one: keep only the objects that have a value.
                    if {[catch { set with [filter -quiet $objs "$p != \\"\\""] }]} { continue }
                    set values [get_property -quiet $p $with]
                    set these [get_property NAME $with]
                    if {[llength $values] != [llength $these]} { continue }
                }
                foreach n $these v $values {
                    if {$v eq ""} { continue }
                    puts $f "$kind\t$n\t$p\t[fpgabridge_clean $v]"
                }
            }
        }
        proc fpgabridge_props {f kind objs} {
            if {[llength $objs] == 0} { return }
            if {$kind ne "cell"} { fpgabridge_props_of $f $kind $objs; return }
            foreach ref [lsort -unique [get_property REF_NAME $objs]] {
                fpgabridge_props_of $f cell [filter $objs "REF_NAME == \\"$ref\\""]
            }
        }
        proc fpgabridge_dump {stage} {
            set started [clock milliseconds]
            set left_out {}
            if {[catch {
                set cells [get_cells -hierarchical -quiet]
                set f [open "out/${stage}_cells.tsv" w]
                fconfigure $f -translation lf
                foreach c $cells {
                    set file [get_property -quiet FILE_NAME $c]
                    if {$file ne ""} { set file [fpgabridge_relative $file] }
                    puts $f "[get_property NAME $c]\t[get_property REF_NAME $c]\t[get_property IS_PRIMITIVE $c]\t$file\t[get_property -quiet LINE_NUMBER $c]"
                }
                close $f
                set f [open "out/${stage}_ports.tsv" w]
                fconfigure $f -translation lf
                foreach p [get_ports -quiet] {
                    puts $f "[get_property NAME $p]\t[get_property DIRECTION $p]\t[get_property PACKAGE_PIN $p]\t[get_property IOSTANDARD $p]\t[get_property SLEW $p]\t[get_property DRIVE $p]\t[get_property PULLTYPE $p]"
                }
                close $f
                if {[llength $cells] <= \(maxConnectivityCells)} {
                    set f [open "out/${stage}_pins.tsv" w]
                    fconfigure $f -translation lf
                    set pins [get_pins -hierarchical -quiet]
                    if {[llength $pins] > 0} {
                        foreach n [get_property NAME $pins] d [get_property DIRECTION $pins] k [get_property IS_CLOCK $pins] {
                            puts $f "$n\t$d\t$k"
                        }
                    }
                    close $f
                    set f [open "out/${stage}_conn.tsv" w]
                    fconfigure $f -translation lf
                    foreach n [get_nets -hierarchical -quiet] {
                        set name [get_property NAME $n]
                        set type [get_property TYPE $n]
                        foreach p [get_pins -quiet -of_objects $n] { puts $f "$name\t$type\t$p\tpin" }
                        foreach p [get_ports -quiet -of_objects $n] { puts $f "$name\t$type\t$p\tport" }
                    }
                    close $f
                } else {
                    lappend left_out connectivity
                }
                set props_started [clock milliseconds]
                set f [open "out/${stage}_props.tsv" w]
                fconfigure $f -translation lf
                fpgabridge_props $f port [get_ports -quiet]
                if {[llength $cells] <= \(maxPropertyObjects)} {
                    fpgabridge_props $f cell $cells
                    fpgabridge_props $f net [get_nets -hierarchical -quiet]
                } else {
                    lappend left_out properties
                }
                close $f
                set props_ms [expr {[clock milliseconds] - $props_started}]
                set f [open "out/${stage}_info.tsv" w]
                fconfigure $f -translation lf
                puts $f "stage\t$stage"
                puts $f "design\t[current_design]"
                puts $f "part\t[get_property PART [current_design]]"
                puts $f "top\t[get_property TOP [current_design]]"
                puts $f "vivado\t[version -short]"
                puts $f "left_out\t[join $left_out ,]"
                puts $f "seconds\t[expr {([clock milliseconds] - $started) / 1000.0}]"
                puts $f "seconds_props\t[expr {$props_ms / 1000.0}]"
                close $f
            } err]} {
                puts "WARNING: fpga-bridge could not write the $stage design data: $err"
            }
            switch $stage {
                rtl {
        \(reportLines("rtl"))
                }
                synth {
        \(reportLines("synth"))
                }
                impl {
        \(reportLines("impl"))
                }
            }
        }
        """
    }
}
