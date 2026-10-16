import Foundation

/// One IP in Vivado's catalog.
public struct IPDefinition: Equatable, Sendable, Identifiable {
    /// Vendor, library, name and version: `xilinx.com:ip:c_counter_binary:12.0`.
    public let vlnv: String
    public let name: String
    public let displayName: String
    /// The category path Vivado files it under, e.g. `/Basic_Elements/Counters`.
    public let taxonomy: String
    public let description: String
    public let requiresLicense: Bool
    /// Whether it supports the project's device family.
    public let supported: Bool

    public var id: String { vlnv }

    public init(vlnv: String, name: String, displayName: String, taxonomy: String, description: String,
                requiresLicense: Bool, supported: Bool) {
        self.vlnv = vlnv
        self.name = name
        self.displayName = displayName
        self.taxonomy = taxonomy
        self.description = description
        self.requiresLicense = requiresLicense
        self.supported = supported
    }

    private var parts: [String] { vlnv.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
    public var vendor: String { parts.count == 4 ? parts[0] : "" }
    public var library: String { parts.count == 4 ? parts[1] : "" }
    public var version: String { parts.count == 4 ? parts[3] : "" }

    /// Every category the IP is filed under. The taxonomy is a space-separated list of paths, and one IP can be in
    /// several: `/Foundational_Elements/Basic /Foundational_Elements/Clock_and_Reset`.
    public var categoryPaths: [[String]] {
        taxonomy.split(separator: " ").map { $0.split(separator: "/").map(String.init) }.filter { !$0.isEmpty }
    }

    /// The first category's names from outermost in: `["Basic_Elements", "Counters"]`.
    public var categories: [String] { categoryPaths.first ?? [] }
}

/// A node of the category tree.
public struct IPCategory: Identifiable, Equatable, Sendable {
    public let id: String       // the path, "/Basic_Elements/Counters"
    public let name: String     // "Counters"
    public var children: [IPCategory]
    /// Definitions filed directly under this category.
    public var definitions: [IPDefinition]

    /// Everything in this category and below.
    public var allDefinitions: [IPDefinition] { definitions + children.flatMap(\.allDefinitions) }
    public var title: String { name.replacingOccurrences(of: "_", with: " ") }
}

/// The IP catalog of a build machine's Vivado for a device: what can be added to a design.
public struct IPCatalog: Equatable, Sendable {
    public let definitions: [IPDefinition]
    /// The device the support flags are for, when the catalog was made.
    public let part: String
    public let vivado: String

    public init(definitions: [IPDefinition], part: String, vivado: String) {
        self.definitions = definitions
        self.part = part
        self.vivado = vivado
    }

    /// The marker every line of data starts with, so the data can be picked out of Vivado's own output.
    public static let marker = "FPGABRIDGE-IP"

    // MARK: Getting the data

    /// The Tcl that lists the catalog for `part`. Each IP is one tab-separated line starting with the marker.
    public static func listScript(part: String) -> String {
        """
        create_project -in_memory -part {\(part)}
        set arch [get_property ARCHITECTURE [get_parts {\(part)}]]
        puts "\(marker)\\tVIVADO\\t[version -short]\\t\\t\\t\\t\\t"
        foreach d [get_ipdefs] {
            set clean [list]
            foreach p {VLNV NAME DISPLAY_NAME TAXONOMY DESCRIPTION} {
                lappend clean [string map [list "\\t" " " "\\n" " " "\\r" ""] [get_property -quiet $p $d]]
            }
            set lic [expr {[get_property -quiet REQUIRES_LICENSE $d] ne "" && [get_property -quiet REQUIRES_LICENSE $d] ne "0"}]
            set sup [expr {[string first $arch [get_property -quiet SUPPORTED_FAMILIES $d]] >= 0}]
            puts "\(marker)\\tIP\\t[join $clean "\\t"]\\t$lic\\t$sup"
        }
        """
    }

    /// Reads the marker lines out of Vivado's output.
    public static func parse(output: String, part: String) -> IPCatalog {
        var vivado = ""
        var definitions: [IPDefinition] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker + "\t") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.count >= 3, f[1] == "VIVADO" { vivado = f[2]; continue }
            // marker, "IP", vlnv, name, display, taxonomy, description, license, supported
            guard f.count >= 9, f[1] == "IP", !f[2].isEmpty else { continue }
            // Interface and signal definitions (`interface.param`, `signal.param`, ...) are in Vivado's list but are not IP
            // you can add, and its own catalog doesn't show them.
            if f[2].split(separator: ":").dropFirst().first?.hasSuffix(".param") == true { continue }
            definitions.append(IPDefinition(vlnv: f[2], name: f[3], displayName: f[4].isEmpty ? f[3] : f[4], taxonomy: f[5],
                                            description: f[6], requiresLicense: f[7] == "1", supported: f[8] == "1"))
        }
        return IPCatalog(definitions: definitions.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
                         part: part, vivado: vivado)
    }

    // MARK: Cache

    /// Where the catalog for this build machine and device is kept between runs.
    public static func cacheURL(host: String, part: String) -> URL {
        let safe = { (s: String) in String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/fpga-bridge/ip-catalog-\(safe(host))-\(safe(part)).txt")
    }

    /// The marker lines `parse` reads, so a catalog can be saved and loaded without asking Vivado again.
    public var serialized: String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["\(IPCatalog.marker)\tVIVADO\t\(vivado)\t\t\t\t\t"]
        for d in definitions {
            lines.append(["\(IPCatalog.marker)", "IP", d.vlnv, d.name, d.displayName, d.taxonomy, clean(d.description),
                          d.requiresLicense ? "1" : "0", d.supported ? "1" : "0"].map(clean).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Nil if there is no cache or it holds no IP.
    public static func load(from url: URL) -> IPCatalog? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let catalog = parse(output: text, part: "")
        return catalog.definitions.isEmpty ? nil : catalog
    }

    // MARK: Browsing

    /// Definitions matching `query` (every word in the name, title or description), optionally only supported ones.
    public func search(_ query: String, onlySupported: Bool) -> [IPDefinition] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return definitions.filter { def in
            (!onlySupported || def.supported)
                && (words.isEmpty || words.allSatisfy { w in
                    def.displayName.lowercased().contains(w) || def.name.lowercased().contains(w) || def.description.lowercased().contains(w)
                })
        }
    }

    /// The category tree of the given definitions.
    public static func categories(of definitions: [IPDefinition]) -> [IPCategory] {
        var roots: [IPCategory] = []

        func insert(_ def: IPDefinition, _ path: ArraySlice<String>, prefix: String, into nodes: inout [IPCategory]) {
            guard let head = path.first else { return }
            let id = prefix + "/" + head
            let index: Int
            if let found = nodes.firstIndex(where: { $0.id == id }) { index = found }
            else { nodes.append(IPCategory(id: id, name: head, children: [], definitions: [])); index = nodes.count - 1 }
            if path.count == 1 { nodes[index].definitions.append(def) }
            else { insert(def, path.dropFirst(), prefix: id, into: &nodes[index].children) }
        }

        for def in definitions {
            let paths = def.categoryPaths.isEmpty ? [["Uncategorized"]] : def.categoryPaths
            for path in paths { insert(def, path[...], prefix: "", into: &roots) }
        }
        func sorted(_ nodes: [IPCategory]) -> [IPCategory] {
            nodes.sorted { $0.title < $1.title }.map { var n = $0; n.children = sorted(n.children); return n }
        }
        return sorted(roots)
    }
}
