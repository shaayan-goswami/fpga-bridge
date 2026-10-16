import Foundation

/// An IP in a project: which IP it is, what it is called in the design, and the settings that differ from its defaults.
/// The build recreates it from this each time (`create_ip`, `set_property`, `generate_target`, `synth_ip`), so there is no
/// `.xci` file to keep in step: the project file is the whole truth.
public struct ProjectIP: Codable, Equatable, Sendable, Identifiable {
    /// The module name to instantiate in HDL: `cnt8`.
    public var name: String
    /// Vendor, library, name and version: `xilinx.com:ip:c_counter_binary:12.0`.
    public var vlnv: String
    /// Settings that differ from the defaults, keyed `CONFIG.Output_Width`.
    public var config: [String: String]

    public var id: String { name }

    public init(name: String, vlnv: String, config: [String: String] = [:]) {
        self.name = name
        self.vlnv = vlnv
        self.config = config
    }

    public enum IPError: DescribedError, Equatable {
        case invalid(String)
        public var description: String {
            if case .invalid(let why) = self { return "Invalid IP: \(why)" }
            return ""
        }
    }

    /// `[vendor, library, name, version]`, or nil if the VLNV isn't in that form.
    public var vlnvParts: [String]? {
        let parts = vlnv.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 4 ? parts : nil
    }

    /// Everything here ends up in a Tcl script on the build machine, so it has to be plain.
    public func validate() throws {
        guard Project.isPlain(name), name.first.map({ !$0.isNumber && $0 != "-" }) == true, !name.contains("-") else {
            throw IPError.invalid("the instance name '\(name)' must be a plain module name (letters, digits and _, not starting with a digit)")
        }
        guard !HDLTemplate.isReservedWord(name) else { throw IPError.invalid("'\(name)' is a reserved word in Verilog or VHDL") }
        guard let parts = vlnvParts, parts.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil }) else {
            throw IPError.invalid("'\(vlnv)' isn't a vendor:library:name:version identifier")
        }
        for key in config.keys.sorted() {
            if key == "CONFIG.Component_Name" { throw IPError.invalid("the instance name is set separately; CONFIG.Component_Name can't be set") }
            guard key.range(of: #"^CONFIG\.[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil else {
                throw IPError.invalid("'\(key)' isn't a CONFIG property name")
            }
        }
        for key in config.keys.sorted() where !ProjectIP.isPlainValue(config[key] ?? "") {
            throw IPError.invalid("the value '\(config[key] ?? "")' for \(key) may only contain letters, digits and _ . + - : , / and spaces")
        }
    }

    /// Values go inside Tcl braces: nothing that could close them or start a substitution.
    static func isPlainValue(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_.+\-:,/ ]*$"#, options: .regularExpression) != nil
    }

    /// The Tcl that creates and builds this IP in non-project mode. `set_part` must come first, or Vivado treats the IP as locked.
    func tclLines(directory: String = "ip") -> [String] {
        guard let p = vlnvParts else { return [] }
        var lines = ["create_ip -name \(p[2]) -vendor \(p[0]) -library \(p[1]) -version \(p[3]) -module_name \(name) -dir \(directory)"]
        if !config.isEmpty {
            let pairs = config.keys.sorted().map { "\($0) {\(config[$0] ?? "")}" }.joined(separator: " ")
            lines.append("set_property -dict [list \(pairs)] [get_ips \(name)]")
        }
        return lines
    }
}
