import Foundation

/// The "Design Timing Summary" from `report_timing_summary`.
/// WNS/WHS are the worst setup/hold slack in ns (negative means a violation); TNS/THS are the totals of violations.
public struct TimingSummary: Equatable {
    public var wns: Double?
    public var tns: Double?
    public var tnsFailingEndpoints: Int?
    public var tnsTotalEndpoints: Int?
    public var whs: Double?
    public var ths: Double?
    public var thsFailingEndpoints: Int?
    public var thsTotalEndpoints: Int?
    public var tpwsFailingEndpoints: Int?
    /// True when Vivado reports every constraint as met.
    public var constraintsMet: Bool

    /// False when the design has no clocks or constraints, so Vivado had nothing to time ("NA" everywhere).
    public var isTimed: Bool { wns != nil || whs != nil }

    /// Parses the text of a `report_timing_summary` file.
    ///
    /// The table is whitespace-aligned rather than `|`-bordered: headers are separated by two or more spaces
    /// ("TNS Failing Endpoints" is one header) and each value sits under one header. "NA" means not applicable.
    public static func parse(_ text: String) throws -> TimingSummary {
        let lines = text.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("WNS(ns)") }) else {
            throw ReportError.unparseable("timing summary", "no \"WNS(ns)\" table found")
        }
        guard let valueLine = lines[(headerIndex + 1)...].first(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.allSatisfy { $0 == "-" || $0 == " " }
        }) else {
            throw ReportError.unparseable("timing summary", "the table has no values")
        }

        let headers = lines[headerIndex].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let values = valueLine.split(whereSeparator: { $0 == " " }).map(String.init)
        guard headers.count == values.count else {
            throw ReportError.unparseable("timing summary", "found \(headers.count) headers but \(values.count) values")
        }
        let byHeader = Dictionary(uniqueKeysWithValues: zip(headers, values))

        func number(_ key: String) -> Double? { byHeader[key].flatMap(Double.init) }
        func count(_ key: String) -> Int? { byHeader[key].flatMap(Int.init) }

        var summary = TimingSummary(
            wns: number("WNS(ns)"), tns: number("TNS(ns)"),
            tnsFailingEndpoints: count("TNS Failing Endpoints"), tnsTotalEndpoints: count("TNS Total Endpoints"),
            whs: number("WHS(ns)"), ths: number("THS(ns)"),
            thsFailingEndpoints: count("THS Failing Endpoints"), thsTotalEndpoints: count("THS Total Endpoints"),
            tpwsFailingEndpoints: count("TPWS Failing Endpoints"),
            constraintsMet: true)

        if text.contains("Timing constraints are not met") {
            summary.constraintsMet = false
        } else if text.contains("All user specified timing constraints are met") {
            summary.constraintsMet = true
        } else {
            // Fall back to the numbers when Vivado's verdict line is missing. No numbers means nothing was timed.
            let failing = (summary.tnsFailingEndpoints ?? 0) + (summary.thsFailingEndpoints ?? 0) + (summary.tpwsFailingEndpoints ?? 0)
            summary.constraintsMet = summary.isTimed && failing == 0 && (summary.wns ?? 0) >= 0 && (summary.whs ?? 0) >= 0
        }
        return summary
    }
}

public enum ReportError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case unparseable(String, String)

    public var description: String {
        switch self {
        case .notFound: return "not found"
        case .unparseable(let name, let why): return "couldn't read \(name): \(why)"
        }
    }
}
