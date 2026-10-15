import Foundation

/// One row of the Define Module dialog's I/O Port Definitions table.
public struct PortDefinition: Equatable, Identifiable, Sendable {
    public enum Direction: String, CaseIterable, Identifiable, Sendable {
        case input, output, `inout`
        public var id: String { rawValue }

        var vhdl: String {
            switch self {
            case .input: "in"
            case .output: "out"
            case .inout: "inout"
            }
        }
    }

    public let id: UUID
    public var name: String
    public var direction: Direction
    /// MSB and LSB are ignored unless this is set, as in Vivado.
    public var isBus: Bool
    public var msb: Int
    public var lsb: Int

    public init(name: String = "", direction: Direction = .input, isBus: Bool = false, msb: Int = 0, lsb: Int = 0) {
        self.id = UUID()
        self.name = name
        self.direction = direction
        self.isBus = isBus
        self.msb = msb
        self.lsb = lsb
    }

    public static func == (a: PortDefinition, b: PortDefinition) -> Bool {
        a.name == b.name && a.direction == b.direction && a.isBus == b.isBus
            && (!a.isBus || (a.msb == b.msb && a.lsb == b.lsb))
    }
}

/// What the Define Module dialog collects for one new source file.
public struct ModuleDefinition: Equatable, Sendable {
    /// Module name (Verilog) or entity name (VHDL).
    public var name: String
    /// VHDL architecture name.
    public var architecture: String
    public var ports: [PortDefinition]

    public init(name: String, architecture: String = "Behavioral", ports: [PortDefinition] = []) {
        self.name = name
        self.architecture = architecture
        self.ports = ports
    }

    /// Ports with blank names are not written, as in Vivado.
    public var writtenPorts: [PortDefinition] {
        ports.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func validate() throws {
        guard HDLTemplate.isIdentifier(name) else { throw ModuleDefinitionError.invalidModuleName(name) }
        guard !HDLTemplate.isReservedWord(name) else { throw ModuleDefinitionError.reservedWord(name) }
        guard HDLTemplate.isIdentifier(architecture) else { throw ModuleDefinitionError.invalidArchitectureName(architecture) }
        guard !HDLTemplate.isReservedWord(architecture) else { throw ModuleDefinitionError.reservedWord(architecture) }
        var seen = Set<String>()
        for port in writtenPorts {
            let portName = port.name.trimmingCharacters(in: .whitespaces)
            guard HDLTemplate.isIdentifier(portName) else { throw ModuleDefinitionError.invalidPortName(portName) }
            guard !HDLTemplate.isReservedWord(portName) else { throw ModuleDefinitionError.reservedWord(portName) }
            // Verilog is case-sensitive but VHDL is not; reject both kinds of clash so either language works.
            guard seen.insert(portName.lowercased()).inserted else { throw ModuleDefinitionError.duplicatePort(portName) }
        }
    }
}

public enum ModuleDefinitionError: DescribedError, Equatable {
    case invalidModuleName(String)
    case invalidArchitectureName(String)
    case invalidPortName(String)
    case duplicatePort(String)
    case reservedWord(String)

    public var description: String {
        switch self {
        case .invalidModuleName(let n):
            "'\(n)' isn't a valid module name. Use a letter or '_' followed by letters, digits or '_'."
        case .invalidArchitectureName(let n): "'\(n)' isn't a valid architecture name."
        case .invalidPortName(let n): "'\(n)' isn't a valid port name. Use a letter or '_' followed by letters, digits or '_'."
        case .duplicatePort(let n): "The port '\(n)' is defined more than once."
        case .reservedWord(let n): "'\(n)' is a reserved word in Verilog, SystemVerilog or VHDL, so it can't be used as a name."
        }
    }
}

/// Writes new source files the way Vivado's Create Source File + Define Module does: a header block, then the
/// module (or entity and architecture) with the ports from the dialog.
public enum HDLTemplate {
    public struct Context {
        public var projectName: String
        public var part: String
        public var date: Date

        public init(projectName: String, part: String, date: Date = Date()) {
            self.projectName = projectName
            self.part = part
            self.date = date
        }
    }

    public static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first.isASCII,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    /// Verilog (IEEE 1364-2005), SystemVerilog (IEEE 1800) and VHDL (IEEE 1076) keywords, lowercase. A name from any of
    /// the three is refused whatever the file's language: the project may switch language, and VHDL ignores case.
    private static let reservedWords: Set<String> = Set("""
        abs abstract accept access after alias all always and architecture array assert assign assume assume_property \
        attribute automatic before begin bind bins binsof bit block break buf bufif0 bufif1 body byte case casex casez \
        cell chandle class clocking cmos component config configuration const constraint context continue cover \
        covergroup coverpoint cross deassign default defparam design disable disconnect dist do downto edge else elsif \
        end endcase endchecker endclass endclocking endconfig endfunction endgenerate endgroup endinterface endmodule \
        endpackage endprimitive endprogram endproperty endsequence endspecify endtable endtask entity enum event \
        eventually exit expect export extends extern file final first_match for force foreach forever fork forkjoin \
        function generate generic genvar group guarded highz0 highz1 if iff ifnone ignore_bins illegal_bins import \
        impure in incdir include initial inout input inside instance int integer interface intersect is join join_any \
        join_none label large let liblist library linkage literal localparam logic longint loop macromodule map matches \
        medium mod modport module nand negedge new next nmos nor noshowcancelled not notif0 notif1 null of on or others \
        out output package packed parameter pmos port posedge primitive priority process program property protected \
        pull0 pull1 pulldown pullup pulsestyle_ondetect pulsestyle_onevent pure rand randc randcase randsequence range \
        rcmos real realtime record ref reg register reject rem release repeat report restrict return rnmos rol ror rpmos \
        rtran rtranif0 rtranif1 scalared select sequence severity shared shortint shortreal showcancelled signal sla sll \
        small solve specify specparam sra srl static string strong strong0 strong1 struct subtype super supply0 supply1 \
        sync_accept_on table tagged task then this throughout time timeprecision timeunit tran tranif0 tranif1 transport \
        tri tri0 tri1 triand trior trireg type typedef union unique unique0 units unsigned until until_with untyped use \
        uwire var variable vectored virtual void wait wait_order wand wait weak weak0 weak1 when while wildcard wire with \
        within wor xnor xor
        """.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\\" }).map(String.init))

    public static func isReservedWord(_ name: String) -> Bool { reservedWords.contains(name.lowercased()) }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy hh:mm:ss a"
        return f.string(from: date)
    }

    /// Verilog and SystemVerilog share a layout; only the file extension differs.
    public static func verilog(_ module: ModuleDefinition, context: Context) -> String {
        let rule = "//" + String(repeating: "/", count: 80)
        var lines = [
            "`timescale 1ns / 1ps",
            rule,
            "// Company: ",
            "// Engineer: ",
            "// ",
            "// Create Date: \(dateString(context.date))",
            "// Design Name: ",
            "// Module Name: \(module.name)",
            "// Project Name: \(context.projectName)",
            "// Target Devices: \(context.part)",
            "// Tool Versions: ",
            "// Description: ",
            "// ",
            "// Dependencies: ",
            "// ",
            "// Revision:",
            "// Revision 0.01 - File Created",
            "// Additional Comments:",
            "// ",
            rule,
            "",
            "",
            "module \(module.name)(",
        ]
        let ports = module.writtenPorts
        if ports.isEmpty {
            lines.append("")
        } else {
            for (index, port) in ports.enumerated() {
                let range = port.isBus ? " [\(port.msb):\(port.lsb)]" : ""
                let comma = index < ports.count - 1 ? "," : ""
                lines.append("    \(port.direction.rawValue)\(range) \(port.name.trimmingCharacters(in: .whitespaces))\(comma)")
            }
        }
        lines += ["    );", "endmodule", ""]
        return lines.joined(separator: "\n")
    }

    public static func vhdl(_ module: ModuleDefinition, context: Context) -> String {
        let rule = String(repeating: "-", count: 82)
        var lines = [
            rule,
            "-- Company: ",
            "-- Engineer: ",
            "-- ",
            "-- Create Date: \(dateString(context.date))",
            "-- Design Name: ",
            "-- Module Name: \(module.name) - \(module.architecture)",
            "-- Project Name: \(context.projectName)",
            "-- Target Devices: \(context.part)",
            "-- Tool Versions: ",
            "-- Description: ",
            "-- ",
            "-- Dependencies: ",
            "-- ",
            "-- Revision:",
            "-- Revision 0.01 - File Created",
            "-- Additional Comments:",
            "-- ",
            rule,
            "",
            "",
            "library IEEE;",
            "use IEEE.STD_LOGIC_1164.ALL;",
            "",
            "entity \(module.name) is",
        ]
        let ports = module.writtenPorts
        if !ports.isEmpty {
            for (index, port) in ports.enumerated() {
                let name = port.name.trimmingCharacters(in: .whitespaces)
                let type = port.isBus
                    ? "STD_LOGIC_VECTOR (\(port.msb) \(port.msb >= port.lsb ? "downto" : "to") \(port.lsb))"
                    : "STD_LOGIC"
                let prefix = index == 0 ? "    Port ( " : "           "
                let end = index == ports.count - 1 ? ");" : ";"
                lines.append("\(prefix)\(name) : \(port.direction.vhdl) \(type)\(end)")
            }
        }
        lines += [
            "end \(module.name);",
            "",
            "architecture \(module.architecture) of \(module.name) is",
            "",
            "begin",
            "",
            "",
            "end \(module.architecture);",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    public static func constraints(context: Context) -> String {
        "## Constraints for \(context.projectName) (\(context.part))\n"
    }
}
