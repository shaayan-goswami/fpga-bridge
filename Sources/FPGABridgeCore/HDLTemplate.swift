import Foundation

/// One row of the Define Module dialog's I/O Port Definitions table.
public struct PortDefinition: Equatable, Identifiable {
    public enum Direction: String, CaseIterable, Identifiable {
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
public struct ModuleDefinition: Equatable {
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
        guard HDLTemplate.isIdentifier(architecture) else { throw ModuleDefinitionError.invalidArchitectureName(architecture) }
        var seen = Set<String>()
        for port in writtenPorts {
            let portName = port.name.trimmingCharacters(in: .whitespaces)
            guard HDLTemplate.isIdentifier(portName) else { throw ModuleDefinitionError.invalidPortName(portName) }
            // Verilog is case-sensitive but VHDL is not; reject both kinds of clash so either language works.
            guard seen.insert(portName.lowercased()).inserted else { throw ModuleDefinitionError.duplicatePort(portName) }
        }
    }
}

public enum ModuleDefinitionError: Error, CustomStringConvertible, Equatable {
    case invalidModuleName(String)
    case invalidArchitectureName(String)
    case invalidPortName(String)
    case duplicatePort(String)

    public var description: String {
        switch self {
        case .invalidModuleName(let n):
            "'\(n)' isn't a valid module name. Use a letter or '_' followed by letters, digits or '_'."
        case .invalidArchitectureName(let n): "'\(n)' isn't a valid architecture name."
        case .invalidPortName(let n): "'\(n)' isn't a valid port name. Use a letter or '_' followed by letters, digits or '_'."
        case .duplicatePort(let n): "The port '\(n)' is defined more than once."
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
