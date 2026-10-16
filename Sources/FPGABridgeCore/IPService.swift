import Foundation

/// One configurable setting of an IP, as Vivado reports it when the IP is created with its defaults.
public struct IPProperty: Equatable, Sendable, Identifiable {
    /// `CONFIG.Output_Width`
    public let name: String
    public let value: String

    public var id: String { name }
    /// The name without the prefix: `Output_Width`.
    public var title: String { name.hasPrefix("CONFIG.") ? String(name.dropFirst("CONFIG.".count)) : name }
    public var isBoolean: Bool { value == "true" || value == "false" }
}

/// What a run of one of the IP scripts printed, read from its marker lines.
public struct IPScriptOutput: Equatable, Sendable {
    public var properties: [IPProperty] = []
    public var verilogTemplate: [String] = []
    public var vhdlTemplate: [String] = []
    /// A failure the script caught, in Vivado's words.
    public var error: String?
}

/// The Tcl and the parsing for the IP features that run on the build machine: listing an IP's settings and fetching its
/// instantiation template. (The catalog itself is `IPCatalog`.)
public enum IPScripts {
    static let marker = IPCatalog.marker

    /// Creates `ip` in a scratch folder, inside a `catch` so a failure is reported instead of aborting, and cleans up.
    private static func wrapped(_ ip: ProjectIP, part: String, token: String, body: String) -> String {
        let work = "ipwork_\(token)"
        return """
        set_part {\(part)}
        file mkdir \(work)
        if {[catch {
        \(ip.tclLines(directory: work).joined(separator: "\n"))
        \(body)
        } err]} {
            puts "\(marker)\\tERROR\\t[string map [list "\\t" " " "\\n" " " "\\r" ""] $err]"
        }
        catch { file delete -force \(work) }
        """
    }

    /// Lists every `CONFIG.*` setting of the IP with its default value (`CONFIG.Component_Name` excluded: it is the instance name).
    public static func propertiesScript(vlnv: String, part: String, token: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        let ip = ProjectIP(name: "fpgabridge_probe", vlnv: vlnv)
        return wrapped(ip, part: part, token: token, body: """
            foreach p [lsort [list_property [get_ips fpgabridge_probe] CONFIG.*]] {
                if {$p eq "CONFIG.Component_Name"} { continue }
                puts "\(marker)\\tCFG\\t$p\\t[string map [list "\\t" " " "\\n" " " "\\r" ""] [get_property $p [get_ips fpgabridge_probe]]]"
            }
        """)
    }

    /// Generates the instantiation templates of the IP as configured and prints them line by line.
    public static func templateScript(ip: ProjectIP, part: String, token: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        let work = "ipwork_\(token)"
        return wrapped(ip, part: part, token: token, body: """
            generate_target {instantiation_template} [get_ips \(ip.name)]
            foreach {ext tag} {veo VERILOG vho VHDL} {
                set f "\(work)/\(ip.name)/\(ip.name).$ext"
                if {[file exists $f]} {
                    set fh [open $f]
                    foreach line [split [read $fh] "\\n"] {
                        puts "\(marker)\\tTEMPLATE_$tag\\t[string map [list "\\t" "    " "\\r" ""] $line]"
                    }
                    close $fh
                }
            }
        """)
    }

    /// Reads the marker lines of either script.
    public static func parse(output: String) -> IPScriptOutput {
        var result = IPScriptOutput()
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker + "\t") {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            switch f[1] {
            case "CFG": if f.count >= 4 { result.properties.append(IPProperty(name: f[2], value: f[3])) }
            case "TEMPLATE_VERILOG": result.verilogTemplate.append(f[2])
            case "TEMPLATE_VHDL": result.vhdlTemplate.append(f[2])
            case "ERROR": result.error = f[2...].joined(separator: " ")
            default: break
            }
        }
        return result
    }

    /// The parts of a `.veo` or `.vho` that are meant to be copied into a design: each stretch between a "Begin Cut here"
    /// line and its `_TAG_END` line, without the licence text. Verilog has one (the instance); VHDL has two (the
    /// component declaration and the instance), which are joined with a blank line.
    public static func cutSection(of lines: [String]) -> String {
        var sections: [[String]] = []
        var current: [String]?
        for line in lines {
            if line.contains("Begin Cut here for") { current = []; continue }
            if line.contains("_TAG_END") {
                if let done = current { sections.append(done) }
                current = nil
                continue
            }
            current?.append(line)
        }
        let texts = sections.map { section -> String in
            var body = section
            while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
            while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            return body.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        return texts.isEmpty ? "" : texts.joined(separator: "\n\n") + "\n"
    }
}

/// Runs the IP scripts on the build machine.
public struct IPService: Sendable {
    public let remote: Remote

    public init(remote: Remote) { self.remote = remote }

    /// Runs a script and returns everything it printed.
    func run(_ script: String) throws -> String {
        let box = OutputBox()
        let status = try remote.runTcl(script: script) { box.append($0) }
        let text = box.value
        guard status == 0 || text.contains(IPScripts.marker) else { throw IPServiceError.vivadoFailed(status, String(text.suffix(600))) }
        return text
    }

    /// The catalog for `part`: from the cache if it has one (unless `refresh`), else from the build machine, and then cached.
    public func catalog(part: String, refresh: Bool = false) throws -> IPCatalog {
        let cache = IPCatalog.cacheURL(host: remote.config.host, part: part)
        if !refresh, let cached = IPCatalog.load(from: cache) { return cached }
        let output = try run(IPCatalog.listScript(part: part))
        let catalog = IPCatalog.parse(output: output, part: part)
        guard !catalog.definitions.isEmpty else { throw IPServiceError.noCatalog }
        try? catalog.save(to: cache)
        return catalog
    }

    public func properties(of ip: IPDefinition, part: String) throws -> [IPProperty] {
        let parsed = IPScripts.parse(output: try run(IPScripts.propertiesScript(vlnv: ip.vlnv, part: part)))
        if let error = parsed.error { throw IPServiceError.vivado(error) }
        return parsed.properties
    }

    public func template(for ip: ProjectIP, part: String) throws -> IPScriptOutput {
        let parsed = IPScripts.parse(output: try run(IPScripts.templateScript(ip: ip, part: part)))
        if let error = parsed.error { throw IPServiceError.vivado(error) }
        return parsed
    }
}

/// Collects text written from another thread.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) { lock.withLock { text += chunk } }
    var value: String { lock.withLock { text } }
}

public enum IPServiceError: DescribedError {
    case vivadoFailed(Int32, String)
    case vivado(String)
    case noCatalog

    public var description: String {
        switch self {
        case .vivadoFailed(let status, let tail): return "Vivado exited with status \(status).\n\(tail)"
        case .vivado(let message): return "Vivado said: \(message)"
        case .noCatalog: return "Vivado didn't list any IP. Is the part number right, and is Vivado's IP catalog installed?"
        }
    }
}
