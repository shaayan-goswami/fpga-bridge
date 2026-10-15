import FPGABridgeCore
import Foundation

/// The example project ("Open Example Project") and the simulated runs used when no build machine is configured.
enum DemoData {
    static let projectName = "blinky"
    static let part = "xc7a35tcpg236-1"
    static let board = "basys3"

    /// File name -> source set, for creating the example project.
    static let files: [(String, SourceSet)] = [
        ("blinky.v", .design), ("clk_div.v", .design), ("debounce.v", .design),
        ("basys3.xdc", .constraints), ("blinky_tb.v", .simulation),
    ]

    static let contents: [String: String] = [
        "blinky.v": """
        `timescale 1ns / 1ps

        // Counts up on the LEDs once per second (100 MHz clock).
        module blinky (
            input  wire       clk,
            input  wire       btnC,   // center button = reset
            output wire [3:0] led
        );
            wire tick;
            wire rst;

            debounce u_debounce (.clk(clk), .in(btnC), .out(rst));
            clk_div #(.DIVIDE(100_000_000)) u_div (.clk(clk), .rst(rst), .tick(tick));

            reg [3:0] count;
            always @(posedge clk) begin
                if (rst)       count <= 4'd0;
                else if (tick) count <= count + 4'd1;
            end

            assign led = count;
        endmodule
        """,
        "clk_div.v": """
        `timescale 1ns / 1ps

        // Emits a one-cycle pulse every DIVIDE clock cycles.
        module clk_div #(
            parameter DIVIDE = 100_000_000
        ) (
            input  wire clk,
            input  wire rst,
            output reg  tick
        );
            reg [26:0] n;

            always @(posedge clk) begin
                if (rst || n == DIVIDE - 1) begin
                    n    <= 27'd0;
                    tick <= (n == DIVIDE - 1);
                end else begin
                    n    <= n + 27'd1;
                    tick <= 1'b0;
                end
            end
        endmodule
        """,
        "debounce.v": """
        `timescale 1ns / 1ps

        // Ignores a button until it has been stable for about 10 ms.
        module debounce (
            input  wire clk,
            input  wire in,
            output reg  out
        );
            reg [19:0] stable;
            reg        last;

            always @(posedge clk) begin
                last <= in;
                if (in != last) stable <= 20'd0;
                else if (stable == 20'd1_000_000) out <= in;
                else stable <= stable + 20'd1;
            end
        endmodule
        """,
        "basys3.xdc": """
        ## Clock (100 MHz)
        set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk]
        create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

        ## Center button
        set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports btnC]

        ## LEDs
        set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
        set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
        set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
        set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
        """,
        "blinky_tb.v": """
        `timescale 1ns / 1ps

        module blinky_tb;
            reg clk = 0;
            reg btnC = 1;
            wire [3:0] led;

            blinky dut (.clk(clk), .btnC(btnC), .led(led));

            always #5 clk = ~clk;

            initial begin
                #100 btnC = 0;
                #2_000_000 $finish;
            end
        endmodule
        """,
    ]

    // MARK: Reports (same layout as Vivado's, so the real parsers read them)

    static let timingReport = """
    Timing Summary Report

    ------------------------------------------------------------------------------------------------
    | Design Timing Summary
    | ---------------------
    ------------------------------------------------------------------------------------------------

        WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
        -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
          5.231        0.000                      0                   71        0.152        0.000                      0                   71        4.500        0.000                      0                   42


    All user specified timing constraints are met.
    """

    static let utilizationReport = """
    Utilization Design Information

    1. Slice Logic
    --------------

    +----------------------------+------+-------+------------+-----------+-------+
    |          Site Type         | Used | Fixed | Prohibited | Available | Util% |
    +----------------------------+------+-------+------------+-----------+-------+
    | Slice LUTs                 |   38 |     0 |          0 |     20800 |  0.18 |
    |   LUT as Logic             |   38 |     0 |          0 |     20800 |  0.18 |
    |   LUT as Memory            |    0 |     0 |          0 |      9600 |  0.00 |
    | Slice Registers           |   62 |     0 |          0 |     41600 |  0.15 |
    |   Register as Flip Flop    |   62 |     0 |          0 |     41600 |  0.15 |
    +----------------------------+------+-------+------------+-----------+-------+

    3. Memory
    ---------

    +-------------------+------+-------+------------+-----------+-------+
    |     Site Type     | Used | Fixed | Prohibited | Available | Util% |
    +-------------------+------+-------+------------+-----------+-------+
    | Block RAM Tile    |  2.5 |     0 |          0 |        50 |  5.00 |
    |   RAMB36/FIFO*    |    2 |     0 |          0 |        50 |  4.00 |
    |   RAMB18          |    1 |     0 |          0 |       100 |  1.00 |
    +-------------------+------+-------+------------+-----------+-------+

    4. DSP
    ------

    +----------------+------+-------+------------+-----------+-------+
    |    Site Type   | Used | Fixed | Prohibited | Available | Util% |
    +----------------+------+-------+------------+-----------+-------+
    | DSPs           |    0 |     0 |          0 |        90 |  0.00 |
    +----------------+------+-------+------------+-----------+-------+

    5. IO and GT Specific
    ---------------------

    +-----------------------------+------+-------+------------+-----------+-------+
    |          Site Type          | Used | Fixed | Prohibited | Available | Util% |
    +-----------------------------+------+-------+------------+-----------+-------+
    | Bonded IOB                  |    6 |     6 |          0 |       106 |  5.66 |
    +-----------------------------+------+-------+------------+-----------+-------+
    """

    /// Post-synthesis numbers are a little higher than post-implementation ones, as in real runs.
    static var synthUtilizationReport: String {
        utilizationReport.replacingOccurrences(of: "|   38 |", with: "|   41 |")
    }

    static func reports(for kind: RunKind) -> [ReportFile] {
        switch kind {
        case .synthesis:
            [ReportFile(run: .synthesis, name: "synth_utilization.rpt", text: synthUtilizationReport)]
        case .implementation:
            [ReportFile(run: .implementation, name: BuildSummary.timingReport, text: timingReport),
             ReportFile(run: .implementation, name: BuildSummary.utilizationReport, text: utilizationReport)]
        case .bitstream:
            []
        }
    }

    // MARK: Run logs: (seconds to wait before this chunk, text)

    /// The simulated log for a step. Synthesis lines are built from the real project so any project gets a
    /// believable run.
    static func log(for kind: RunKind, top: String, part: String, sources: [String], constraints: [String]) -> [(Double, String)] {
        switch kind {
        case .synthesis:
            var lines: [(Double, String)] = [
                (0.2, "Copying \(sources.count + constraints.count) files to buildbox...\n"),
                (0.5, "****** Vivado v2023.2 (64-bit)\n"),
                (0.1, "source synth.tcl\n"),
            ]
            for path in sources {
                let ext = (path as NSString).pathExtension.lowercased()
                let reader = ext.hasPrefix("vhd") ? "read_vhdl" : (ext.hasPrefix("sv") ? "read_verilog -sv" : "read_verilog")
                lines.append((0.1, "Command: \(reader) {\(path)}\n"))
            }
            lines += constraints.map { (0.1, "Command: read_xdc {\($0)}\n") }
            lines += [
                (0.4, "Command: synth_design -top \(top) -part \(part)\n"),
                (0.3, "INFO: [Synth 8-7078] Launching helper process for spawning children vivado processes\n"),
                (0.3, "INFO: [Synth 8-6157] synthesizing module '\(top)'\n"),
                (0.3, "WARNING: [Synth 8-6014] Unused sequential element last_reg was removed.\n"),
                (0.4, "Finished RTL Optimization Phase 2 : Time (s): cpu = 00:00:08 ; elapsed = 00:00:09\n"),
                (0.3, "INFO: [Synth 8-6155] done synthesizing module '\(top)' (0#1)\n"),
                (0.3, "Command: report_utilization -file synth_utilization.rpt\n"),
                (0.2, "synth_design completed successfully\n"),
            ]
            return lines
        case .implementation:
            return implementationLog
        case .bitstream:
            return bitstreamLog.map { ($0.0, $0.1.replacingOccurrences(of: "blinky.bit", with: "\(top).bit")) }
        }
    }

    static let implementationLog: [(Double, String)] = [
        (0.4, "****** Vivado v2023.2 (64-bit)\n"),
        (0.1, "source impl.tcl\n"),
        (0.3, "Command: open_checkpoint synth.dcp\n"),
        (0.4, "Command: opt_design\n"),
        (0.4, "INFO: [Opt 31-49] Retargeted 0 cell(s).\n"),
        (0.3, "Command: place_design\n"),
        (0.4, "INFO: [Place 30-611] Multithreading enabled for place_design using a maximum of 2 CPUs\n"),
        (0.5, "Phase 1 Placer Initialization\nPhase 2 Global Placement\nPhase 3 Detail Placement\n"),
        (0.3, "Command: route_design\n"),
        (0.4, "Phase 3 Initial Routing\nPhase 4 Rip-up And Reroute\nPhase 5 Post Hold Fix\n"),
        (0.3, "WARNING: [Timing 38-436] There are set_bus_skew constraint(s) in this design.\n"),
        (0.3, "Command: report_timing_summary -file timing_summary.rpt\n"),
        (0.2, "Command: report_utilization -file utilization.rpt\n"),
        (0.2, "route_design completed successfully\n"),
    ]

    static let bitstreamLog: [(Double, String)] = [
        (0.3, "Command: write_bitstream -force blinky.bit\n"),
        (0.4, "INFO: [DRC 23-27] Running DRC with 2 threads\n"),
        (0.5, "Loading data files...\nCreating bitmap...\nCreating bitstream...\n"),
        (0.4, "Writing bitstream ./blinky.bit...\n"),
        (0.3, "INFO: [Vivado 12-1842] Bitgen Completed Successfully.\n"),
        (0.2, "write_bitstream completed successfully\n"),
    ]
}
