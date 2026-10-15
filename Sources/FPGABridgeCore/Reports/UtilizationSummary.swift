import Foundation

public struct ResourceUsage: Equatable {
    public enum Kind: String, CaseIterable {
        case lut = "LUT"
        case ff = "FF"
        case bram = "BRAM"
        case dsp = "DSP"
        case io = "IO"
    }

    public let kind: Kind
    /// Doubles because Block RAM is counted in half tiles ("2.5").
    public let used: Double
    public let available: Double

    /// Computed rather than read from the report, which prints "<0.01" for tiny values.
    public var percent: Double { available > 0 ? used * 100 / available : 0 }
}

/// Top-level resource counts from `report_utilization`.
public struct UtilizationSummary: Equatable {
    public var resources: [ResourceUsage]

    public func usage(_ kind: ResourceUsage.Kind) -> ResourceUsage? {
        resources.first { $0.kind == kind }
    }

    /// Row names differ by device family and Vivado version ("Slice LUTs" vs "CLB LUTs"), so map them to kinds.
    static func kind(forRowName name: String) -> ResourceUsage.Kind? {
        switch name.trimmingCharacters(in: CharacterSet(charactersIn: "* ")).lowercased() {
        case "slice luts", "clb luts": return .lut
        case "slice registers", "clb registers": return .ff
        case "block ram tile": return .bram
        case "dsps": return .dsp
        case "bonded iob": return .io
        default: return nil
        }
    }

    public static func parse(_ text: String) throws -> UtilizationSummary {
        var found: [ResourceUsage.Kind: ResourceUsage] = [:]

        for table in ReportTable.parseAll(text) {
            guard let usedColumn = table.column("Used"), let availableColumn = table.column("Available") else { continue }
            for row in table.rows where row.indent <= 1 {
                // Sub-rows such as "LUT as Logic" are indented deeper and are parts of a top-level row.
                guard row.cells.count > max(usedColumn, availableColumn),
                      let kind = kind(forRowName: row.cells[0]), found[kind] == nil,
                      let used = Double(row.cells[usedColumn]), let available = Double(row.cells[availableColumn])
                else { continue }
                found[kind] = ResourceUsage(kind: kind, used: used, available: available)
            }
        }

        guard !found.isEmpty else {
            throw ReportError.unparseable("utilization report", "no resource tables found")
        }
        let ordered = ResourceUsage.Kind.allCases.compactMap { found[$0] }
        return UtilizationSummary(resources: ordered)
    }
}
