import Foundation

/// The Tcl that makes Vivado write out what the app's design views show. It is added to the build script and runs
/// inside the same Vivado session, with the design open at three points: after RTL elaboration (`rtl`), after
/// synthesis (`synth`) and after routing (`impl`).
///
/// Each stage writes into `out/`:
///   `<stage>_cells.tsv`   one line per cell: name, cell type, 1 if it is a primitive
///   `<stage>_ports.tsv`   one line per port: name, direction, package pin, I/O standard, slew, drive, pull type
///   `<stage>_info.tsv`    key and value lines: stage, design, part, top, Vivado version
/// and a few reports for the stage (see `reports`). Everything is wrapped in `catch`: a failure here must never fail
/// the build, so the worst case is a view with nothing in it.
public enum DesignDump {
    /// File names written for a stage, so the app and the script agree.
    public static func cellsFile(_ stage: String) -> String { "\(stage)_cells.tsv" }
    public static func portsFile(_ stage: String) -> String { "\(stage)_ports.tsv" }
    public static func infoFile(_ stage: String) -> String { "\(stage)_info.tsv" }

    /// Reports written per stage: (file name, Tcl command that writes `out/<file>`). Optional extras are skipped by
    /// Vivado versions that lack them.
    public static let reports: [String: [(file: String, command: String)]] = [
        "rtl": [],
        "synth": [
            ("synth_utilization.rpt", "report_utilization -file out/synth_utilization.rpt"),
            ("synth_timing_summary.rpt", "report_timing_summary -file out/synth_timing_summary.rpt"),
            ("synth_clocks.rpt", "report_clocks -file out/synth_clocks.rpt"),
        ],
        "impl": [
            ("timing_paths.rpt", "report_timing -max_paths 10 -nworst 1 -sort_by group -file out/timing_paths.rpt"),
            ("clocks.rpt", "report_clocks -file out/clocks.rpt"),
            ("clock_utilization.rpt", "report_clock_utilization -file out/clock_utilization.rpt"),
            ("io.rpt", "report_io -file out/io.rpt"),
            ("route_status.rpt", "report_route_status -file out/route_status.rpt"),
            ("drc.rpt", "report_drc -file out/drc.rpt"),
            ("methodology.rpt", "report_methodology -file out/methodology.rpt"),
            ("power.rpt", "report_power -file out/power.rpt"),
        ],
    ]

    /// The procedure the build script calls as `fpgabridge_dump <stage>`.
    public static var procedures: String {
        func reportLines(_ stage: String) -> String {
            (reports[stage] ?? []).map { "        catch { \($0.command) }" }.joined(separator: "\n")
        }
        return """
        # fpga-bridge: write the netlist, ports and reports the app's design views show. Never fails the build.
        proc fpgabridge_dump {stage} {
            if {[catch {
                set f [open "out/${stage}_cells.tsv" w]
                fconfigure $f -translation lf
                set cells [get_cells -hierarchical -quiet]
                if {[llength $cells] > 0} {
                    foreach n [get_property NAME $cells] r [get_property REF_NAME $cells] p [get_property IS_PRIMITIVE $cells] {
                        puts $f "$n\\t$r\\t$p"
                    }
                }
                close $f
                set f [open "out/${stage}_ports.tsv" w]
                fconfigure $f -translation lf
                foreach p [get_ports -quiet] {
                    puts $f "[get_property NAME $p]\\t[get_property DIRECTION $p]\\t[get_property PACKAGE_PIN $p]\\t[get_property IOSTANDARD $p]\\t[get_property SLEW $p]\\t[get_property DRIVE $p]\\t[get_property PULLTYPE $p]"
                }
                close $f
                set f [open "out/${stage}_info.tsv" w]
                fconfigure $f -translation lf
                puts $f "stage\\t$stage"
                puts $f "design\\t[current_design]"
                puts $f "part\\t[get_property PART [current_design]]"
                puts $f "top\\t[get_property TOP [current_design]]"
                puts $f "vivado\\t[version -short]"
                close $f
            } err]} {
                puts "WARNING: fpga-bridge could not write the $stage design data: $err"
            }
            switch $stage {
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
