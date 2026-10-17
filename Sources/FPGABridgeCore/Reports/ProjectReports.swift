import Foundation

/// `report_power`: the summary table, the on-chip breakdown, and the ambient temperature it assumed.
public struct PowerSummary: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public let name: String
        /// As Vivado prints it (`<0.001` stays as text).
        public let watts: String
        /// Indented rows (LUT as Logic under Slice Logic) are parts of the row above.
        public let isPart: Bool
    }

    public var totalOnChip: Double?
    public var dynamic: Double?
    public var deviceStatic: Double?
    public var effectiveThetaJA: Double?
    public var maxAmbient: Double?
    public var junctionTemperature: Double?
    public var ambient: Double?
    public var confidence: String?
    public var components: [Component] = []

    /// How far the ambient can rise before the junction overheats, in °C and in watts, as Vivado's Project Summary
    /// shows it. Negative means the design is already too hot.
    public var thermalMargin: (celsius: Double, watts: Double)? {
        guard let maxAmbient, let ambient, let theta = effectiveThetaJA, theta > 0 else { return nil }
        let margin = maxAmbient - ambient
        return (margin, margin / theta)
    }

    public static func parse(_ text: String) -> PowerSummary? {
        let tables = ReportTable.parseAll(text)
        var summary = PowerSummary()
        var found = false
        func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)) }
        for table in tables where table.header.count == 2 || table.header.first == "On-Chip" {
            if table.header.first == "On-Chip" {
                summary.components = table.rows.compactMap { row in
                    guard row.cells.count >= 2, !row.cells[0].isEmpty else { return nil }
                    return Component(name: row.cells[0], watts: row.cells[1], isPart: row.indent > 1)
                }
                continue
            }
            for row in [table.header] + table.rows.map(\.cells) where row.count == 2 {
                switch row[0] {
                case "Total On-Chip Power (W)": summary.totalOnChip = number(row[1]); found = true
                case "Dynamic (W)": summary.dynamic = number(row[1])
                case "Device Static (W)": summary.deviceStatic = number(row[1])
                case "Effective TJA (C/W)": summary.effectiveThetaJA = number(row[1])
                case "Max Ambient (C)": summary.maxAmbient = number(row[1])
                case "Junction Temperature (C)": summary.junctionTemperature = number(row[1])
                case "Confidence Level": summary.confidence = row[1]
                case "Ambient Temp (C)": summary.ambient = number(row[1])
                default: break
                }
            }
        }
        return found ? summary : nil
    }
}

/// The summary of `report_drc` or `report_methodology`: which rules found something, how severe, how often.
public struct CheckSummary: Equatable, Sendable {
    public struct Rule: Equatable, Sendable, Identifiable {
        public var id: String { rule }
        public let rule: String
        public let severity: String
        public let description: String
        public let checks: Int
    }

    public var rules: [Rule] = []

    public var total: Int { rules.reduce(0) { $0 + $1.checks } }

    /// How many checks there are of a severity (`Warning`, `Critical Warning`, `Error`, `Advisory`), ignoring case.
    public func count(_ severity: String) -> Int {
        rules.filter { $0.severity.caseInsensitiveCompare(severity) == .orderedSame }.reduce(0) { $0 + $1.checks }
    }

    public static func parse(_ text: String) -> CheckSummary? {
        guard let table = ReportTable.parseAll(text).first(where: { $0.column("Rule") != nil && $0.column("Checks") != nil }),
              let rule = table.column("Rule"), let severity = table.column("Severity"), let checks = table.column("Checks") else { return nil }
        let description = table.column("Description")
        var summary = CheckSummary()
        for row in table.rows where row.cells.count > max(rule, severity, checks) {
            summary.rules.append(Rule(rule: row.cells[rule], severity: row.cells[severity],
                                      description: description.map { row.cells[$0] } ?? "", checks: Int(row.cells[checks]) ?? 0))
        }
        return summary
    }
}

/// `report_route_status`: how many nets needed routing and how many made it.
public struct RouteStatus: Equatable, Sendable {
    public var logicalNets = 0
    public var routableNets = 0
    public var fullyRouted = 0
    public var routingErrors = 0

    /// Vivado's "Failed Routes": nets that didn't route, or routed with errors.
    public var failedRoutes: Int { max(routableNets - fullyRouted, 0) + routingErrors }

    public static func parse(_ text: String) -> RouteStatus? {
        var status = RouteStatus()
        var found = false
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let value = Int(parts[1]) else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            switch label {
            case "# of logical nets": status.logicalNets = value; found = true
            case "# of routable nets": status.routableNets = value
            case "# of fully routed nets": status.fullyRouted = value
            case "# of nets with routing errors": status.routingErrors = value
            default: break
            }
        }
        return found ? status : nil
    }
}
