import Foundation

/// The languages the editor knows about, chosen from the file extension.
public enum HDLLanguage: Equatable {
    case verilog      // Verilog and SystemVerilog
    case vhdl
    case constraints  // XDC

    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "vhd", "vhdl": self = .vhdl
        case "xdc": self = .constraints
        default: self = .verilog
        }
    }

    public var lineComment: String {
        switch self {
        case .verilog: "//"
        case .vhdl: "--"
        case .constraints: "#"
        }
    }

    public var displayName: String {
        switch self {
        case .verilog: "Verilog"
        case .vhdl: "VHDL"
        case .constraints: "XDC"
        }
    }

    var keywords: [String] {
        switch self {
        case .verilog:
            ["module", "endmodule", "input", "output", "inout", "wire", "reg", "logic", "always", "always_ff",
             "always_comb", "assign", "begin", "end", "if", "else", "case", "endcase", "default", "posedge", "negedge",
             "parameter", "localparam", "initial", "for", "generate", "endgenerate", "genvar", "integer", "function",
             "endfunction", "task", "endtask", "typedef", "enum", "struct", "interface", "endinterface"]
        case .vhdl:
            ["library", "use", "entity", "is", "port", "end", "architecture", "of", "begin", "signal", "process", "if",
             "then", "else", "elsif", "in", "out", "inout", "std_logic", "std_logic_vector", "rising_edge", "case",
             "when", "others", "generic", "map", "component", "package", "variable", "constant", "loop", "for"]
        case .constraints:
            ["set_property", "create_clock", "get_ports", "get_pins", "get_clocks", "get_cells", "set_input_delay",
             "set_output_delay", "set_false_path", "set_multicycle_path", "create_generated_clock", "set_clock_groups"]
        }
    }
}
