import Foundation

/// A snippet from the Language Templates window: common HDL structures and XDC constraints to insert into a file.
public struct LanguageTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let language: TemplateLanguage
    /// The group it sits in, e.g. "Counters".
    public let group: String
    public let summary: String
    public let text: String
}

public enum TemplateLanguage: String, CaseIterable, Sendable {
    case verilog = "Verilog"
    case systemVerilog = "SystemVerilog"
    case vhdl = "VHDL"
    case xdc = "XDC"

    /// How the editor colors it.
    public var highlighting: HDLLanguage {
        switch self {
        case .verilog, .systemVerilog: .verilog
        case .vhdl: .vhdl
        case .xdc: .constraints
        }
    }
}

/// One row of the template tree: a language, a group, or a template.
public struct TemplateNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let template: LanguageTemplate?
    public let children: [TemplateNode]?

    public static func == (a: TemplateNode, b: TemplateNode) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum LanguageTemplates {
    public static let all: [LanguageTemplate] = verilog + systemVerilog + vhdl + xdc

    public static func template(id: String) -> LanguageTemplate? { all.first { $0.id == id } }

    /// Language > group > template, in catalog order.
    public static let tree: [TemplateNode] = TemplateLanguage.allCases.map { language in
        let templates = all.filter { $0.language == language }
        var groups: [String] = []
        for template in templates where !groups.contains(template.group) { groups.append(template.group) }
        return TemplateNode(
            id: language.rawValue, title: language.rawValue, template: nil,
            children: groups.map { group in
                TemplateNode(
                    id: "\(language.rawValue)/\(group)", title: group, template: nil,
                    children: templates.filter { $0.group == group }.map {
                        TemplateNode(id: $0.id, title: $0.name, template: $0, children: nil)
                    })
            })
    }

    /// Templates whose name, group, language or description contain every word of `query`.
    public static func search(_ query: String) -> [LanguageTemplate] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { template in
            let haystack = [template.name, template.group, template.language.rawValue, template.summary].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func make(_ language: TemplateLanguage, _ group: String, _ name: String, _ summary: String, _ text: String) -> LanguageTemplate {
        LanguageTemplate(id: "\(language.rawValue)/\(group)/\(name)", name: name, language: language, group: group,
                         summary: summary, text: text.trimmingCharacters(in: .newlines) + "\n")
    }

    // MARK: Verilog

    private static func v(_ group: String, _ name: String, _ summary: String, _ text: String) -> LanguageTemplate {
        make(.verilog, group, name, summary, text)
    }

    private static let verilog: [LanguageTemplate] = [
        v("Flip-Flops and Registers", "D Flip-Flop with Synchronous Reset", "Resets only on a clock edge. Maps to the slice flip-flop's sync reset.", """
        module dff_sync_reset (
            input  wire clk,
            input  wire rst,   // active high
            input  wire d,
            output reg  q
        );
            always @(posedge clk) begin
                if (rst)
                    q <= 1'b0;
                else
                    q <= d;
            end
        endmodule
        """),
        v("Flip-Flops and Registers", "D Flip-Flop with Asynchronous Reset", "Resets the moment rst rises, without waiting for a clock.", """
        module dff_async_reset (
            input  wire clk,
            input  wire rst,   // active high
            input  wire d,
            output reg  q
        );
            always @(posedge clk or posedge rst) begin
                if (rst)
                    q <= 1'b0;
                else
                    q <= d;
            end
        endmodule
        """),
        v("Flip-Flops and Registers", "Register with Clock Enable", "Loads d only while ce is high; otherwise keeps its value.", """
        module register_ce #(
            parameter WIDTH = 8
        ) (
            input  wire             clk,
            input  wire             rst,
            input  wire             ce,
            input  wire [WIDTH-1:0] d,
            output reg  [WIDTH-1:0] q
        );
            always @(posedge clk) begin
                if (rst)
                    q <= {WIDTH{1'b0}};
                else if (ce)
                    q <= d;
            end
        endmodule
        """),
        v("Flip-Flops and Registers", "Shift Register (Serial In, Parallel Out)", "Shifts one bit in per clock; every stage is readable.", """
        module shift_register #(
            parameter WIDTH = 8
        ) (
            input  wire             clk,
            input  wire             shift_en,
            input  wire             serial_in,
            output reg  [WIDTH-1:0] parallel_out
        );
            always @(posedge clk) begin
                if (shift_en)
                    parallel_out <= {parallel_out[WIDTH-2:0], serial_in};
            end
        endmodule
        """),
        v("Counters", "Binary Up Counter", "Counts up and wraps. Bit WIDTH-1 gives a slow blink from a fast clock.", """
        module counter #(
            parameter WIDTH = 8
        ) (
            input  wire             clk,
            input  wire             rst,
            input  wire             en,
            output reg  [WIDTH-1:0] count
        );
            always @(posedge clk) begin
                if (rst)
                    count <= {WIDTH{1'b0}};
                else if (en)
                    count <= count + 1'b1;
            end
        endmodule
        """),
        v("Counters", "Up/Down Counter with Load", "Counts either way and can be loaded with a value.", """
        module updown_counter #(
            parameter WIDTH = 8
        ) (
            input  wire             clk,
            input  wire             rst,
            input  wire             load,
            input  wire [WIDTH-1:0] load_value,
            input  wire             up,   // 1 counts up, 0 counts down
            output reg  [WIDTH-1:0] count
        );
            always @(posedge clk) begin
                if (rst)
                    count <= {WIDTH{1'b0}};
                else if (load)
                    count <= load_value;
                else if (up)
                    count <= count + 1'b1;
                else
                    count <= count - 1'b1;
            end
        endmodule
        """),
        v("Counters", "Clock Enable Pulse Generator", "One-cycle pulse every DIVIDE clocks. Prefer this to dividing the clock itself.", """
        module tick_generator #(
            parameter DIVIDE = 100_000_000   // clock cycles between pulses (1 s at 100 MHz)
        ) (
            input  wire clk,
            input  wire rst,
            output reg  tick
        );
            reg [$clog2(DIVIDE)-1:0] count;

            always @(posedge clk) begin
                if (rst || count == DIVIDE - 1) begin
                    count <= 0;
                    tick  <= (count == DIVIDE - 1);
                end else begin
                    count <= count + 1'b1;
                    tick  <= 1'b0;
                end
            end
        endmodule
        """),
        v("Finite State Machines", "Moore FSM (Two Always Blocks)", "State register in one block, next-state and outputs in another.", """
        module fsm_moore (
            input  wire clk,
            input  wire rst,
            input  wire start,
            input  wire done,
            output reg  busy
        );
            localparam [1:0] IDLE = 2'd0,
                             RUN  = 2'd1,
                             STOP = 2'd2;

            reg [1:0] state, next_state;

            // State register
            always @(posedge clk) begin
                if (rst)
                    state <= IDLE;
                else
                    state <= next_state;
            end

            // Next state and outputs
            always @(*) begin
                next_state = state;
                busy       = 1'b0;
                case (state)
                    IDLE: if (start) next_state = RUN;
                    RUN: begin
                        busy = 1'b1;
                        if (done) next_state = STOP;
                    end
                    STOP: next_state = IDLE;
                    default: next_state = IDLE;
                endcase
            end
        endmodule
        """),
        v("Multiplexers and Decoders", "4-to-1 Multiplexer", "Selects one of four inputs with a case statement.", """
        module mux4 #(
            parameter WIDTH = 8
        ) (
            input  wire [WIDTH-1:0] a, b, c, d,
            input  wire [1:0]       sel,
            output reg  [WIDTH-1:0] y
        );
            always @(*) begin
                case (sel)
                    2'd0:    y = a;
                    2'd1:    y = b;
                    2'd2:    y = c;
                    default: y = d;
                endcase
            end
        endmodule
        """),
        v("Multiplexers and Decoders", "3-to-8 Decoder", "One output high, chosen by a 3-bit input.", """
        module decoder3to8 (
            input  wire [2:0] in,
            input  wire       en,
            output reg  [7:0] out
        );
            always @(*) begin
                out = 8'b0000_0000;
                if (en)
                    out[in] = 1'b1;
            end
        endmodule
        """),
        v("Multiplexers and Decoders", "Seven-Segment Decoder", "Hex digit to segment pattern. Segments are active low, as on Digilent boards.", """
        module seven_segment (
            input  wire [3:0] digit,
            output reg  [6:0] segments   // {g, f, e, d, c, b, a}, active low
        );
            always @(*) begin
                case (digit)
                    4'h0: segments = 7'b100_0000;
                    4'h1: segments = 7'b111_1001;
                    4'h2: segments = 7'b010_0100;
                    4'h3: segments = 7'b011_0000;
                    4'h4: segments = 7'b001_1001;
                    4'h5: segments = 7'b001_0010;
                    4'h6: segments = 7'b000_0010;
                    4'h7: segments = 7'b111_1000;
                    4'h8: segments = 7'b000_0000;
                    4'h9: segments = 7'b001_0000;
                    4'hA: segments = 7'b000_1000;
                    4'hB: segments = 7'b000_0011;
                    4'hC: segments = 7'b100_0110;
                    4'hD: segments = 7'b010_0001;
                    4'hE: segments = 7'b000_0110;
                    default: segments = 7'b000_1110;
                endcase
            end
        endmodule
        """),
        v("Memories", "Single-Port RAM (Block RAM)", "Written in this style, Vivado infers a block RAM.", """
        module single_port_ram #(
            parameter DATA_WIDTH = 8,
            parameter ADDR_WIDTH = 10
        ) (
            input  wire                  clk,
            input  wire                  we,
            input  wire [ADDR_WIDTH-1:0] addr,
            input  wire [DATA_WIDTH-1:0] din,
            output reg  [DATA_WIDTH-1:0] dout
        );
            reg [DATA_WIDTH-1:0] mem [0:(2**ADDR_WIDTH)-1];

            always @(posedge clk) begin
                if (we)
                    mem[addr] <= din;
                dout <= mem[addr];   // read-first: dout gets the old value
            end
        endmodule
        """),
        v("Memories", "Simple Dual-Port RAM (Block RAM)", "One port writes, the other reads, on separate clocks if needed.", """
        module simple_dual_port_ram #(
            parameter DATA_WIDTH = 8,
            parameter ADDR_WIDTH = 10
        ) (
            input  wire                  wclk,
            input  wire                  we,
            input  wire [ADDR_WIDTH-1:0] waddr,
            input  wire [DATA_WIDTH-1:0] din,
            input  wire                  rclk,
            input  wire [ADDR_WIDTH-1:0] raddr,
            output reg  [DATA_WIDTH-1:0] dout
        );
            reg [DATA_WIDTH-1:0] mem [0:(2**ADDR_WIDTH)-1];

            always @(posedge wclk) begin
                if (we)
                    mem[waddr] <= din;
            end

            always @(posedge rclk) begin
                dout <= mem[raddr];
            end
        endmodule
        """),
        v("Memories", "ROM Initialized from a File", "Contents come from a hex file at build time ($readmemh).", """
        module rom #(
            parameter DATA_WIDTH = 8,
            parameter ADDR_WIDTH = 8,
            parameter INIT_FILE  = "rom.mem"
        ) (
            input  wire                  clk,
            input  wire [ADDR_WIDTH-1:0] addr,
            output reg  [DATA_WIDTH-1:0] dout
        );
            reg [DATA_WIDTH-1:0] mem [0:(2**ADDR_WIDTH)-1];

            initial $readmemh(INIT_FILE, mem);

            always @(posedge clk)
                dout <= mem[addr];
        endmodule
        """),
        v("Arithmetic", "Multiply-Accumulate (DSP48)", "Registered multiplier and accumulator; Vivado places it in a DSP slice.", """
        module mac #(
            parameter A_WIDTH = 16,
            parameter B_WIDTH = 16,
            parameter P_WIDTH = 40
        ) (
            input  wire                       clk,
            input  wire                       rst,
            input  wire signed [A_WIDTH-1:0]  a,
            input  wire signed [B_WIDTH-1:0]  b,
            output reg  signed [P_WIDTH-1:0]  acc
        );
            reg signed [A_WIDTH-1:0]         a_reg;
            reg signed [B_WIDTH-1:0]         b_reg;
            reg signed [A_WIDTH+B_WIDTH-1:0] product;

            always @(posedge clk) begin
                a_reg   <= a;
                b_reg   <= b;
                product <= a_reg * b_reg;
                if (rst)
                    acc <= 0;
                else
                    acc <= acc + product;
            end
        endmodule
        """),
        v("Input and Output", "Tri-State Buffer", "Drives a shared line, or releases it (high impedance).", """
        module tristate_buffer (
            input  wire data_in,
            input  wire enable,
            inout  wire pad
        );
            assign pad = enable ? data_in : 1'bz;
        endmodule
        """),
        v("Input and Output", "Two-Flop Synchronizer", "Brings an asynchronous input (a button, another clock domain) safely into clk.", """
        module synchronizer (
            input  wire clk,
            input  wire async_in,
            output wire sync_out
        );
            (* ASYNC_REG = "TRUE" *) reg [1:0] stages = 2'b00;

            always @(posedge clk)
                stages <= {stages[0], async_in};

            assign sync_out = stages[1];
        endmodule
        """),
        v("Input and Output", "Button Debouncer", "Output follows the input only after it has stayed the same for a while.", """
        module debouncer #(
            parameter STABLE_CYCLES = 1_000_000   // 10 ms at 100 MHz
        ) (
            input  wire clk,
            input  wire noisy_in,   // already synchronized to clk
            output reg  clean_out
        );
            reg [$clog2(STABLE_CYCLES)-1:0] count = 0;

            always @(posedge clk) begin
                if (noisy_in == clean_out)
                    count <= 0;
                else if (count == STABLE_CYCLES - 1) begin
                    clean_out <= noisy_in;
                    count     <= 0;
                end else
                    count <= count + 1'b1;
            end
        endmodule
        """),
        v("Testbench", "Clock, Reset and Stimulus", "A simulation-only file: generates a clock, pulses reset, then drives inputs.", """
        `timescale 1ns / 1ps

        module tb;
            reg  clk = 0;
            reg  rst = 1;
            wire out;

            // Device under test: replace with your module.
            // dut u_dut (.clk(clk), .rst(rst), .out(out));

            // 100 MHz clock
            always #5 clk = ~clk;

            initial begin
                $dumpfile("tb.vcd");
                $dumpvars(0, tb);

                #100 rst = 0;
                // Drive inputs here.

                #1000;
                $finish;
            end
        endmodule
        """),
    ]

    // MARK: SystemVerilog

    private static func sv(_ group: String, _ name: String, _ summary: String, _ text: String) -> LanguageTemplate {
        make(.systemVerilog, group, name, summary, text)
    }

    private static let systemVerilog: [LanguageTemplate] = [
        sv("Flip-Flops and Registers", "always_ff with Synchronous Reset", "The SystemVerilog form of a clocked register.", """
        module register #(
            parameter int WIDTH = 8
        ) (
            input  logic             clk,
            input  logic             rst,
            input  logic [WIDTH-1:0] d,
            output logic [WIDTH-1:0] q
        );
            always_ff @(posedge clk) begin
                if (rst) q <= '0;
                else     q <= d;
            end
        endmodule
        """),
        sv("Combinational Logic", "always_comb Multiplexer", "always_comb finds missing branches at compile time.", """
        module mux4 #(
            parameter int WIDTH = 8
        ) (
            input  logic [WIDTH-1:0] a, b, c, d,
            input  logic [1:0]       sel,
            output logic [WIDTH-1:0] y
        );
            always_comb begin
                unique case (sel)
                    2'd0: y = a;
                    2'd1: y = b;
                    2'd2: y = c;
                    2'd3: y = d;
                endcase
            end
        endmodule
        """),
        sv("Finite State Machines", "FSM with an Enumerated State", "Named states and a typed state variable.", """
        module fsm (
            input  logic clk,
            input  logic rst,
            input  logic start,
            input  logic done,
            output logic busy
        );
            typedef enum logic [1:0] {IDLE, RUN, STOP} state_t;
            state_t state, next_state;

            always_ff @(posedge clk) begin
                if (rst) state <= IDLE;
                else     state <= next_state;
            end

            always_comb begin
                next_state = state;
                busy       = 1'b0;
                unique case (state)
                    IDLE: if (start) next_state = RUN;
                    RUN: begin
                        busy = 1'b1;
                        if (done) next_state = STOP;
                    end
                    STOP: next_state = IDLE;
                endcase
            end
        endmodule
        """),
        sv("Memories", "Single-Port RAM", "Block RAM with always_ff.", """
        module single_port_ram #(
            parameter int DATA_WIDTH = 8,
            parameter int ADDR_WIDTH = 10
        ) (
            input  logic                  clk,
            input  logic                  we,
            input  logic [ADDR_WIDTH-1:0] addr,
            input  logic [DATA_WIDTH-1:0] din,
            output logic [DATA_WIDTH-1:0] dout
        );
            logic [DATA_WIDTH-1:0] mem [2**ADDR_WIDTH];

            always_ff @(posedge clk) begin
                if (we) mem[addr] <= din;
                dout <= mem[addr];
            end
        endmodule
        """),
        sv("Interfaces", "Interface with Modports", "Bundles related signals so a connection is one port.", """
        interface stream_if #(
            parameter int WIDTH = 8
        ) (
            input logic clk
        );
            logic [WIDTH-1:0] data;
            logic             valid;
            logic             ready;

            modport source (output data, valid, input  ready);
            modport sink   (input  data, valid, output ready);
        endinterface
        """),
        sv("Testbench", "Self-Checking Testbench", "Drives inputs, compares with expected values, and reports pass or fail.", """
        `timescale 1ns / 1ps

        module tb;
            logic clk = 0;
            logic rst = 1;
            int   errors = 0;

            // dut u_dut (.clk, .rst);

            always #5 clk = ~clk;

            task automatic check(input logic actual, input logic expected, input string what);
                if (actual !== expected) begin
                    errors++;
                    $error("%s: got %b, expected %b", what, actual, expected);
                end
            endtask

            initial begin
                repeat (10) @(posedge clk);
                rst = 0;
                // Drive inputs and call check(...) here.
                repeat (100) @(posedge clk);

                if (errors == 0) $display("PASS");
                else             $display("FAIL: %0d errors", errors);
                $finish;
            end
        endmodule
        """),
    ]

    // MARK: VHDL

    private static func vh(_ group: String, _ name: String, _ summary: String, _ text: String) -> LanguageTemplate {
        make(.vhdl, group, name, summary, text)
    }

    private static let vhdl: [LanguageTemplate] = [
        vh("Flip-Flops and Registers", "D Flip-Flop with Synchronous Reset", "Resets only on a clock edge.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity dff_sync_reset is
            port (
                clk : in  std_logic;
                rst : in  std_logic;   -- active high
                d   : in  std_logic;
                q   : out std_logic
            );
        end entity dff_sync_reset;

        architecture rtl of dff_sync_reset is
        begin
            process (clk)
            begin
                if rising_edge(clk) then
                    if rst = '1' then
                        q <= '0';
                    else
                        q <= d;
                    end if;
                end if;
            end process;
        end architecture rtl;
        """),
        vh("Flip-Flops and Registers", "D Flip-Flop with Asynchronous Reset", "Resets the moment rst is high, without waiting for a clock.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity dff_async_reset is
            port (
                clk : in  std_logic;
                rst : in  std_logic;   -- active high
                d   : in  std_logic;
                q   : out std_logic
            );
        end entity dff_async_reset;

        architecture rtl of dff_async_reset is
        begin
            process (clk, rst)
            begin
                if rst = '1' then
                    q <= '0';
                elsif rising_edge(clk) then
                    q <= d;
                end if;
            end process;
        end architecture rtl;
        """),
        vh("Counters", "Binary Up Counter", "Counts up and wraps around.", """
        library ieee;
        use ieee.std_logic_1164.all;
        use ieee.numeric_std.all;

        entity counter is
            generic (
                WIDTH : positive := 8
            );
            port (
                clk   : in  std_logic;
                rst   : in  std_logic;
                en    : in  std_logic;
                count : out std_logic_vector(WIDTH - 1 downto 0)
            );
        end entity counter;

        architecture rtl of counter is
            signal value : unsigned(WIDTH - 1 downto 0) := (others => '0');
        begin
            process (clk)
            begin
                if rising_edge(clk) then
                    if rst = '1' then
                        value <= (others => '0');
                    elsif en = '1' then
                        value <= value + 1;
                    end if;
                end if;
            end process;

            count <= std_logic_vector(value);
        end architecture rtl;
        """),
        vh("Counters", "Clock Enable Pulse Generator", "One-cycle pulse every DIVIDE clocks.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity tick_generator is
            generic (
                DIVIDE : positive := 100_000_000   -- clock cycles between pulses
            );
            port (
                clk  : in  std_logic;
                rst  : in  std_logic;
                tick : out std_logic
            );
        end entity tick_generator;

        architecture rtl of tick_generator is
            signal count : natural range 0 to DIVIDE - 1 := 0;
        begin
            process (clk)
            begin
                if rising_edge(clk) then
                    tick <= '0';
                    if rst = '1' then
                        count <= 0;
                    elsif count = DIVIDE - 1 then
                        count <= 0;
                        tick  <= '1';
                    else
                        count <= count + 1;
                    end if;
                end if;
            end process;
        end architecture rtl;
        """),
        vh("Finite State Machines", "Moore FSM (Two Processes)", "State register in one process, next state and outputs in another.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity fsm_moore is
            port (
                clk   : in  std_logic;
                rst   : in  std_logic;
                start : in  std_logic;
                done  : in  std_logic;
                busy  : out std_logic
            );
        end entity fsm_moore;

        architecture rtl of fsm_moore is
            type state_type is (IDLE, RUN, STOP);
            signal state, next_state : state_type := IDLE;
        begin
            -- State register
            process (clk)
            begin
                if rising_edge(clk) then
                    if rst = '1' then
                        state <= IDLE;
                    else
                        state <= next_state;
                    end if;
                end if;
            end process;

            -- Next state and outputs
            process (state, start, done)
            begin
                next_state <= state;
                busy       <= '0';
                case state is
                    when IDLE =>
                        if start = '1' then next_state <= RUN; end if;
                    when RUN =>
                        busy <= '1';
                        if done = '1' then next_state <= STOP; end if;
                    when STOP =>
                        next_state <= IDLE;
                end case;
            end process;
        end architecture rtl;
        """),
        vh("Multiplexers and Decoders", "4-to-1 Multiplexer", "Selects one of four inputs.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity mux4 is
            generic (
                WIDTH : positive := 8
            );
            port (
                a, b, c, d : in  std_logic_vector(WIDTH - 1 downto 0);
                sel        : in  std_logic_vector(1 downto 0);
                y          : out std_logic_vector(WIDTH - 1 downto 0)
            );
        end entity mux4;

        architecture rtl of mux4 is
        begin
            with sel select
                y <= a when "00",
                     b when "01",
                     c when "10",
                     d when others;
        end architecture rtl;
        """),
        vh("Memories", "Single-Port RAM (Block RAM)", "Written in this style, Vivado infers a block RAM.", """
        library ieee;
        use ieee.std_logic_1164.all;
        use ieee.numeric_std.all;

        entity single_port_ram is
            generic (
                DATA_WIDTH : positive := 8;
                ADDR_WIDTH : positive := 10
            );
            port (
                clk  : in  std_logic;
                we   : in  std_logic;
                addr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
                din  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
                dout : out std_logic_vector(DATA_WIDTH - 1 downto 0)
            );
        end entity single_port_ram;

        architecture rtl of single_port_ram is
            type ram_type is array (0 to 2 ** ADDR_WIDTH - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
            signal ram : ram_type;
        begin
            process (clk)
            begin
                if rising_edge(clk) then
                    if we = '1' then
                        ram(to_integer(unsigned(addr))) <= din;
                    end if;
                    dout <= ram(to_integer(unsigned(addr)));
                end if;
            end process;
        end architecture rtl;
        """),
        vh("Input and Output", "Tri-State Buffer", "Drives a shared line, or releases it.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity tristate_buffer is
            port (
                data_in : in    std_logic;
                enable  : in    std_logic;
                pad     : inout std_logic
            );
        end entity tristate_buffer;

        architecture rtl of tristate_buffer is
        begin
            pad <= data_in when enable = '1' else 'Z';
        end architecture rtl;
        """),
        vh("Input and Output", "Two-Flop Synchronizer", "Brings an asynchronous input safely into clk.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity synchronizer is
            port (
                clk      : in  std_logic;
                async_in : in  std_logic;
                sync_out : out std_logic
            );
        end entity synchronizer;

        architecture rtl of synchronizer is
            signal stages : std_logic_vector(1 downto 0) := "00";
            attribute ASYNC_REG : string;
            attribute ASYNC_REG of stages : signal is "TRUE";
        begin
            process (clk)
            begin
                if rising_edge(clk) then
                    stages <= stages(0) & async_in;
                end if;
            end process;

            sync_out <= stages(1);
        end architecture rtl;
        """),
        vh("Testbench", "Clock, Reset and Stimulus", "A simulation-only file: generates a clock, pulses reset, then drives inputs.", """
        library ieee;
        use ieee.std_logic_1164.all;

        entity tb is
        end entity tb;

        architecture sim of tb is
            constant CLK_PERIOD : time := 10 ns;   -- 100 MHz
            signal clk : std_logic := '0';
            signal rst : std_logic := '1';
        begin
            -- Device under test: replace with your entity.
            -- u_dut : entity work.dut port map (clk => clk, rst => rst);

            clk <= not clk after CLK_PERIOD / 2;

            stimulus : process
            begin
                wait for 10 * CLK_PERIOD;
                rst <= '0';
                -- Drive inputs here.
                wait for 100 * CLK_PERIOD;
                std.env.finish;
            end process stimulus;
        end architecture sim;
        """),
    ]

    // MARK: XDC

    private static func x(_ group: String, _ name: String, _ summary: String, _ text: String) -> LanguageTemplate {
        make(.xdc, group, name, summary, text)
    }

    private static let xdc: [LanguageTemplate] = [
        x("Clocks", "Primary Clock", "Describes an input clock so timing can be checked. Without one the design is unconstrained.", """
        create_clock -period 10.000 -name sys_clk [get_ports clk]
        """),
        x("Clocks", "Generated Clock", "A clock made by logic from another clock, such as a divider.", """
        create_generated_clock -name clk_div2 -source [get_ports clk] -divide_by 2 [get_pins clk_div_reg/Q]
        """),
        x("Clocks", "Asynchronous Clock Groups", "Tells timing analysis that two clocks have nothing to do with each other.", """
        set_clock_groups -asynchronous -group [get_clocks clk_a] -group [get_clocks clk_b]
        """),
        x("Clocks", "Input Jitter", "How noisy the input clock is. Raises the timing margin Vivado asks for.", """
        set_input_jitter [get_clocks sys_clk] 0.100
        """),
        x("Pin Assignments", "Pin and I/O Standard", "Puts a port on a package pin at a voltage level. Pin names are in your board's manual.", """
        set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports clk]
        """),
        x("Pin Assignments", "Bus of Pins", "One line per bit of a vector port.", """
        set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
        set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
        set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
        set_property -dict { PACKAGE_PIN W17 IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]
        """),
        x("Pin Assignments", "Pull-Up, Drive Strength and Slew", "Extra pad settings for a pin.", """
        set_property PULLUP true [get_ports btn]
        set_property DRIVE 12 [get_ports led]
        set_property SLEW FAST [get_ports led]
        """),
        x("I/O Timing", "Input Delay", "How long after the clock edge an external device's data arrives.", """
        set_input_delay -clock [get_clocks sys_clk] -max 2.000 [get_ports data_in]
        set_input_delay -clock [get_clocks sys_clk] -min 0.500 [get_ports data_in]
        """),
        x("I/O Timing", "Output Delay", "How much of the clock period the external device needs to capture data.", """
        set_output_delay -clock [get_clocks sys_clk] -max 2.000 [get_ports data_out]
        set_output_delay -clock [get_clocks sys_clk] -min -0.500 [get_ports data_out]
        """),
        x("Timing Exceptions", "False Path", "Excludes a path from timing, such as a button or LED that has no timing requirement.", """
        set_false_path -from [get_ports btn]
        set_false_path -to [get_ports led]
        """),
        x("Timing Exceptions", "Multicycle Path", "A path that is allowed more than one clock cycle. Set the hold as well.", """
        set_multicycle_path 2 -setup -from [get_cells src_reg*] -to [get_cells dst_reg*]
        set_multicycle_path 1 -hold  -from [get_cells src_reg*] -to [get_cells dst_reg*]
        """),
        x("Timing Exceptions", "Maximum Delay Between Clocks", "Bounds a clock-crossing path without fully ignoring it.", """
        set_max_delay -datapath_only 5.000 -from [get_clocks clk_a] -to [get_clocks clk_b]
        """),
        x("Configuration", "Configuration Voltage and Bank Voltage", "Needed on 7 series boards to silence a bitstream warning. Check the board manual for the values.", """
        set_property CFGBVS VCCO [current_design]
        set_property CONFIG_VOLTAGE 3.3 [current_design]
        """),
        x("Configuration", "Bitstream Options for Quad SPI Flash", "Faster, smaller bitstream for writing the board's flash.", """
        set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
        set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
        set_property CONFIG_MODE SPIx4 [current_design]
        """),
    ]
}
