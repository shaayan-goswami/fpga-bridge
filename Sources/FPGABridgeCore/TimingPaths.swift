import Foundation

/// The two checks Vivado's timing paths are for: setup (the `max` delay) and hold (the `min` delay).
public enum TimingCheck: String, CaseIterable, Sendable {
    case setup, hold

    public var title: String { self == .setup ? "Setup" : "Hold" }

    /// Vivado's `DELAY_TYPE` for the check.
    public var delayType: String { self == .setup ? "max" : "min" }

    init?(delayType: String) {
        switch delayType.lowercased() {
        case "max", "max_rise", "max_fall": self = .setup
        case "min", "min_rise", "min_fall": self = .hold
        default: return nil
        }
    }
}

/// One timing path as `get_timing_paths` describes it, with the ports, pins, nets and cells it goes through.
public struct TimingPath: Identifiable, Equatable, Sendable {
    /// The path's number in the build's list. Vivado's Timing window calls it "Path <id>".
    public let id: Int
    public let check: TimingCheck
    /// The path group, usually the destination clock (`sys_clk`), or a group such as `**async_default**`.
    public let group: String
    /// Nil for a path without a requirement (unconstrained), which Vivado shows as an infinite slack.
    public let slack: Double?
    public let requirement: Double?
    public let dataPathDelay: Double?
    public let logicDelay: Double?
    public let netDelay: Double?
    public let logicLevels: Int?
    public let maxFanout: Int?
    /// Where the path starts and ends: a cell pin (`u_tick/count_reg[21]/C`) or a top-level port (`sw[8]`).
    public let startPoint: String
    public let endPoint: String
    public let startClock: String
    public let endClock: String
    public let skew: Double?
    public let uncertainty: Double?
    public let exception: String
    public let corner: String
    public let arrivalTime: Double?
    public let requiredTime: Double?
    /// The start and end points that are top-level ports, start first.
    public var ports: [String]
    /// The data path's pins in order. Vivado starts them at the startpoint cell's output (`Q`), not its clock pin.
    public var pins: [String]
    public var nets: [String]
    public var cells: [String]

    public init(id: Int, check: TimingCheck, group: String, slack: Double?, requirement: Double? = nil, dataPathDelay: Double? = nil,
                logicDelay: Double? = nil, netDelay: Double? = nil, logicLevels: Int? = nil, maxFanout: Int? = nil,
                startPoint: String, endPoint: String, startClock: String = "", endClock: String = "", skew: Double? = nil,
                uncertainty: Double? = nil, exception: String = "", corner: String = "", arrivalTime: Double? = nil,
                requiredTime: Double? = nil, ports: [String] = [], pins: [String] = [], nets: [String] = [], cells: [String] = []) {
        self.id = id
        self.check = check
        self.group = group
        self.slack = slack
        self.requirement = requirement
        self.dataPathDelay = dataPathDelay
        self.logicDelay = logicDelay
        self.netDelay = netDelay
        self.logicLevels = logicLevels
        self.maxFanout = maxFanout
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.startClock = startClock
        self.endClock = endClock
        self.skew = skew
        self.uncertainty = uncertainty
        self.exception = exception
        self.corner = corner
        self.arrivalTime = arrivalTime
        self.requiredTime = requiredTime
        self.ports = ports
        self.pins = pins
        self.nets = nets
        self.cells = cells
    }

    public var name: String { "Path \(id)" }

    public var isFailing: Bool { (slack ?? 0) < 0 }

    /// How many nets the data path crosses (Vivado's "Routes" column).
    public var routes: Int { nets.count }

    public var startIsPort: Bool { ports.contains(startPoint) }
    public var endIsPort: Bool { ports.contains(endPoint) }

    /// Every pin in path order, the startpoint's clock pin first.
    public var pinsInOrder: [String] {
        guard !startIsPort, !startPoint.isEmpty, pins.first != startPoint else { return pins }
        return [startPoint] + pins
    }

    /// What selecting the path selects in the design windows: its start port, then each cell and the net out of it
    /// in path order, then its end port.
    public var objects: [DesignObjectRef] {
        var refs: [DesignObjectRef] = []
        if startIsPort { refs.append(.port(startPoint)) }
        for k in 0..<max(cells.count, nets.count) {
            if k < cells.count { refs.append(.cell(cells[k])) }
            if k < nets.count { refs.append(.net(nets[k])) }
        }
        if endIsPort, endPoint != startPoint { refs.append(.port(endPoint)) }
        return refs
    }
}

/// Where a path group sits in Vivado's Timing window: paths within one clock, between two clocks, or in a group of
/// their own (`**async_default**`, or a user's `group_path`).
public enum TimingPathCategory: String, CaseIterable, Sendable {
    case intraClock = "Intra-Clock Paths"
    case interClock = "Inter-Clock Paths"
    case otherGroups = "Other Path Groups"
}

/// One branch of the Timing window's tree: a path group between two clocks.
public struct TimingPathGroup: Hashable, Identifiable, Sendable {
    public let category: TimingPathCategory
    public let group: String
    public let fromClock: String
    public let toClock: String

    public var id: String { "\(category.rawValue)|\(group)|\(fromClock)|\(toClock)" }

    /// As Vivado labels it: `sys_clk`, `clk_a to clk_b`, or `**async_default**: clk_a to clk_b`.
    public var title: String {
        switch category {
        case .intraClock: return group
        case .interClock: return "\(fromClock) to \(toClock)"
        case .otherGroups:
            let clocks = fromClock.isEmpty && toClock.isEmpty ? "" : ": \(fromClock.isEmpty ? "(none)" : fromClock) to \(toClock.isEmpty ? "(none)" : toClock)"
            return group + clocks
        }
    }

    static func of(_ path: TimingPath) -> TimingPathGroup {
        let category: TimingPathCategory
        if path.group.hasPrefix("**") || path.group != path.endClock {
            category = .otherGroups
        } else if path.startClock == path.endClock {
            category = .intraClock
        } else {
            category = .interClock
        }
        return TimingPathGroup(category: category, group: path.group, fromClock: path.startClock, toClock: path.endClock)
    }
}

/// The worst timing paths a build saved for one design (see `DesignDump`), and Vivado's report of each.
public struct TimingPathSet: Equatable, Sendable {
    public let paths: [TimingPath]
    /// Vivado's `report_timing` text for each path, by path number. The build writes it for the first few hundred.
    public let reports: [Int: String]
    private let byID: [Int: Int]

    public init(paths: [TimingPath] = [], reports: [Int: String] = [:]) {
        self.paths = paths
        self.reports = reports
        self.byID = Dictionary(paths.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public var isEmpty: Bool { paths.isEmpty }

    public func path(_ id: Int) -> TimingPath? { byID[id].map { paths[$0] } }

    public func paths(_ check: TimingCheck) -> [TimingPath] { paths.filter { $0.check == check } }

    /// Failing paths of a check, worst first.
    public func failing(_ check: TimingCheck) -> [TimingPath] {
        paths(check).filter(\.isFailing).sorted { ($0.slack ?? 0, $0.id) < ($1.slack ?? 0, $1.id) }
    }

    /// The path groups in each category, in the order the build listed them.
    public func groups(in category: TimingPathCategory) -> [TimingPathGroup] {
        var seen: Set<TimingPathGroup> = []
        return paths.map(TimingPathGroup.of).filter { $0.category == category && seen.insert($0).inserted }
    }

    public func paths(in group: TimingPathGroup, check: TimingCheck) -> [TimingPath] {
        paths.filter { $0.check == check && TimingPathGroup.of($0) == group }
    }

    /// Vivado's report of one path, read into its summary and its tables.
    public func report(for id: Int) -> TimingPathReport? { reports[id].map(TimingPathReport.parse) }

    // MARK: Loading

    /// Reads `<stage>_timing_paths.tsv`, `_timing_elements.tsv` and `_timing_reports.txt` from a build output folder.
    /// Empty when the build didn't write them (an older build, the elaborated design, or design data turned off).
    public static func load(stage: DesignStage, from directory: URL) -> TimingPathSet {
        func read(_ name: String) -> String? { try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) }
        guard let paths = read(DesignDump.timingPathsFile(stage.rawValue)) else { return TimingPathSet() }
        return parse(paths: paths, elements: read(DesignDump.timingElementsFile(stage.rawValue)) ?? "",
                     reports: read(DesignDump.timingReportsFile(stage.rawValue)) ?? "")
    }

    /// The paths file starts with `#ID` and Vivado's property names, which say which column is which; the elements file
    /// has one line per object (path number, `port`, `pin`, `net` or `cell`, name) in path order.
    public static func parse(paths text: String, elements: String = "", reports: String = "") -> TimingPathSet {
        let rows = DesignSnapshot.rows(text)
        var columns: [String: Int] = [:]
        if let header = rows.first, header.first?.hasPrefix("#") == true {
            for (k, name) in header.enumerated() { columns[name.trimmingCharacters(in: CharacterSet(charactersIn: "#"))] = k }
        } else {
            // No header: the order the build writes.
            columns["ID"] = 0
            for (k, name) in DesignDump.timingPathProperties.enumerated() { columns[name] = k + 1 }
        }

        var ports: [Int: [String]] = [:], pins: [Int: [String]] = [:], nets: [Int: [String]] = [:], cells: [Int: [String]] = [:]
        for f in DesignSnapshot.rows(elements) where f.count >= 3 {
            guard let id = Int(f[0]) else { continue }
            switch f[1] {
            case "port": ports[id, default: []].append(f[2])
            case "pin": pins[id, default: []].append(f[2])
            case "net": nets[id, default: []].append(f[2])
            case "cell": cells[id, default: []].append(f[2])
            default: break
            }
        }

        var paths: [TimingPath] = []
        for f in rows where f.first?.hasPrefix("#") != true {
            func field(_ name: String) -> String {
                guard let k = columns[name], k < f.count else { return "" }
                return f[k].trimmingCharacters(in: .whitespaces)
            }
            func number(_ name: String) -> Double? { Double(field(name)) }
            guard let id = Int(field("ID")), let check = TimingCheck(delayType: field("DELAY_TYPE")) else { continue }
            let start = field("STARTPOINT_PIN"), end = field("ENDPOINT_PIN")
            // Only the start and end can be ports of the data path; keep them in that order.
            let pathPorts = Set(ports[id] ?? [])
            paths.append(TimingPath(
                id: id, check: check, group: field("GROUP"), slack: number("SLACK"), requirement: number("REQUIREMENT"),
                dataPathDelay: number("DATAPATH_DELAY"), logicDelay: number("DATAPATH_LOGIC_DELAY"), netDelay: number("DATAPATH_NET_DELAY"),
                logicLevels: Int(field("LOGIC_LEVELS")), maxFanout: Int(field("MAX_FANOUT")),
                startPoint: start, endPoint: end, startClock: field("STARTPOINT_CLOCK"), endClock: field("ENDPOINT_CLOCK"),
                skew: number("SKEW"), uncertainty: number("UNCERTAINTY"), exception: field("EXCEPTION"), corner: field("CORNER"),
                arrivalTime: number("ARRIVAL_TIME"), requiredTime: number("REQUIRED_TIME"),
                ports: [start, end].filter { pathPorts.contains($0) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
                pins: pins[id] ?? [], nets: nets[id] ?? [], cells: cells[id] ?? []))
        }
        return TimingPathSet(paths: paths, reports: parseReports(reports))
    }

    /// The reports file is each path's `report_timing` text after a `#fpga-bridge path <id>` line.
    public static func parseReports(_ text: String) -> [Int: String] {
        var reports: [Int: String] = [:]
        var current: Int?
        var lines: [Substring] = []
        func flush() {
            if let current { reports[current] = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) }
            lines = []
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix(reportMarker) {
                flush()
                current = Int(line.dropFirst(reportMarker.count).trimmingCharacters(in: .whitespaces))
            } else if current != nil {
                lines.append(line)
            }
        }
        flush()
        return reports
    }

    static let reportMarker = "#fpga-bridge path "
}

// MARK: One path's report

/// Vivado's `report_timing` of one path, read the way its Path Properties window shows it: the summary lines, then
/// the source clock path, the data path and the destination clock path as tables.
public struct TimingPathReport: Equatable, Sendable {
    /// A summary line (`Source`, `Path Type`...). Indented lines (`Source Clock Delay (SCD)`) belong to the one above.
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let value: String
        public let isDetail: Bool
    }

    /// One line of a path table.
    public struct Step: Equatable, Sendable {
        /// The site (`SLICE_X3Y16`, `W5`), or empty.
        public let location: String
        /// `FDRE (Prop_fdre_C_Q)`, `net (fo=2, routed)`, `clock pessimism`... Empty on a line that only names a pin.
        public let delayType: String
        public let increment: Double?
        public let total: Double?
        /// `r` or `f` for a rising or falling transition, else empty.
        public let edge: String
        /// The pin, net, cell or port (`clk (IN)`) the line is about.
        public let resource: String

        /// The object the line names, as the design windows know it: a net on a net line, a port for `(IN)`/`(OUT)`,
        /// a pin when the name has a slash and isn't a net line, otherwise a cell (the setup/hold check's line).
        public var object: DesignObjectRef? {
            guard !resource.isEmpty else { return nil }
            if resource.hasSuffix(" (IN)") || resource.hasSuffix(" (OUT)") || resource.hasSuffix(" (INOUT)") {
                return .port(String(resource[..<resource.lastIndex(of: " ")!]))
            }
            if delayType.hasPrefix("net") { return .net(resource) }
            if increment == nil || delayType.contains("(Prop_") || delayType.isEmpty { return .pin(resource) }
            return .cell(resource)
        }
    }

    public var title = ""
    public var summary: [Item] = []
    public var sourceClockPath: [Step] = []
    public var dataPath: [Step] = []
    public var destinationClockPath: [Step] = []
    public var requiredTime: Double?
    public var arrivalTime: Double?
    public var slack: Double?
    /// The report as Vivado wrote it.
    public var text = ""

    public init() {}

    public static func parse(_ text: String) -> TimingPathReport {
        var report = TimingPathReport()
        report.text = text
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let tableHeader = lines.firstIndex(where: { $0.contains("Delay type") && $0.contains("Incr(ns)") }) else {
            report.summary = summaryItems(lines)
            return report
        }
        report.summary = summaryItems(Array(lines[..<tableHeader]))

        // Blocks between the dashed lines: the clock path to the startpoint, the data path, the destination clock path
        // (after a blank line), then required and arrival time, then the slack. A path from an input port has no
        // source clock block, and an unconstrained one has only its data path.
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines[(tableHeader + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("-----") {
                blocks.append(current)
                current = []
            } else {
                current.append(line)
            }
        }
        blocks.append(current)
        blocks = blocks.filter { block in block.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

        var tables: [[Step]] = []
        for block in blocks {
            let trimmed = block.map { $0.trimmingCharacters(in: .whitespaces) }
            if trimmed.contains(where: { $0.hasPrefix("required time") || $0.hasPrefix("slack") || $0.hasPrefix("arrival time") }) {
                for t in trimmed {
                    let value = Double(t.split(separator: " ").last ?? "")
                    if t.hasPrefix("required time") { report.requiredTime = value }
                    if t.hasPrefix("arrival time") { report.arrivalTime = value }
                    if t.hasPrefix("slack") { report.slack = value }
                }
                continue
            }
            tables.append(block.compactMap(step))
        }
        switch tables.count {
        case 0: break
        case 1: report.dataPath = tables[0]
        case 2: report.dataPath = tables[0]; report.destinationClockPath = tables[1]
        default:
            report.sourceClockPath = tables[0]
            report.dataPath = tables[1]
            report.destinationClockPath = Array(tables[2...].joined())
        }
        return report
    }

    /// `  Name:   value` lines up to the table, with Vivado's continuation lines (deeper indent, no colon) joined on.
    static func summaryItems(_ lines: [String]) -> [Item] {
        var items: [Item] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("Slack"), let colon = trimmed.firstIndex(of: ":") {
                let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                items.append(Item(name: name, value: trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces), isDetail: false))
                continue
            }
            if let colon = trimmed.range(of: ":  ") ?? trimmed.range(of: ":", options: .backwards).flatMap({ $0.upperBound == trimmed.endIndex ? $0 : nil }),
               !trimmed.hasPrefix("(") {
                let name = String(trimmed[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = trimmed[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                items.append(Item(name: name, value: value, isDetail: indent > 2))
            } else if let last = items.popLast() {
                // A continuation, such as the clock under Source and Destination.
                items.append(Item(name: last.name, value: last.value + (last.value.isEmpty ? "" : " ") + trimmed, isDetail: last.isDetail))
            }
        }
        return items
    }

    /// One table line: `Location  Delay type  Incr(ns)  Path(ns)  edge  Netlist Resource(s)`. The location is the
    /// word starting in the fifth column; the two numbers split the delay type from the edge and the resource.
    static func step(_ line: String) -> Step? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var rest = Substring(line)
        var location = ""
        let indent = line.prefix { $0 == " " }.count
        if indent <= 6 {
            let word = rest.drop { $0 == " " }.prefix { $0 != " " }
            location = String(word)
            rest = rest.drop { $0 == " " }.dropFirst(word.count)
        }
        let words = rest.split(separator: " ", omittingEmptySubsequences: true)
        // The first two numbers in a row are the increment and the running total.
        var numberAt: Int?
        for k in words.indices.dropLast() where Double(words[k]) != nil && Double(words[k + 1]) != nil && words[k].contains(".") {
            numberAt = k
            break
        }
        var delayType = "", edge = "", resource = ""
        var increment: Double?, total: Double?
        var tail: ArraySlice<Substring>
        if let k = numberAt {
            delayType = words[..<k].joined(separator: " ")
            increment = Double(words[k])
            total = Double(words[k + 1])
            tail = words[(k + 2)...]
        } else if let k = words.firstIndex(where: { $0 == "r" || $0 == "f" }) {
            // No numbers: a line that only names the pin reached (`FDRE  r  count_reg[10]/C`).
            delayType = words[..<k].joined(separator: " ")
            tail = words[k...]
        } else {
            // No numbers and no edge: the whole line is a description.
            delayType = words.joined(separator: " ")
            tail = []
        }
        if let first = tail.first, first == "r" || first == "f" {
            edge = String(first)
            tail = tail.dropFirst()
        }
        resource = tail.joined(separator: " ")
        return Step(location: location, delayType: delayType, increment: increment, total: total, edge: edge, resource: resource)
    }
}

// MARK: The timing summary report's other sections

/// The parts of `report_timing_summary` that Vivado's Timing window shows as their own pages: the header (General
/// Information), Timer Settings, Check Timing and Clock Summary.
public struct TimingSummarySections: Equatable, Sendable {
    public var generalInformation: [(name: String, value: String)] = []
    public var timerSettings = ""
    public var checkTiming = ""
    public var clockSummary = ""
    /// `check_timing`'s numbered checks with how many problems each found (`no_input_delay`, 3).
    public var checks: [(name: String, count: Int)] = []
    /// Clock lines of the Clock Summary: name, waveform, period, frequency.
    public var clocks: [(name: String, waveform: String, period: String, frequency: String)] = []

    public init() {}

    public static func == (a: TimingSummarySections, b: TimingSummarySections) -> Bool {
        a.timerSettings == b.timerSettings && a.checkTiming == b.checkTiming && a.clockSummary == b.clockSummary
            && a.generalInformation.map(\.name) == b.generalInformation.map(\.name)
            && a.generalInformation.map(\.value) == b.generalInformation.map(\.value)
    }

    /// How many problems check_timing found, over all its checks.
    public var checkTimingProblems: Int { checks.reduce(0) { $0 + $1.count } }

    public static func parse(_ text: String) -> TimingSummarySections {
        var result = TimingSummarySections()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        // `| Name : value` lines in the header box.
        for line in lines.prefix(20) where line.hasPrefix("| ") {
            let body = line.dropFirst(2)
            guard let colon = body.range(of: ": ") else { continue }
            let name = body[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            if name == "Host" { continue }                 // the build machine's own name says nothing here
            result.generalInformation.append((name, body[colon.upperBound...].trimmingCharacters(in: .whitespaces)))
        }

        // Sections are boxed: a dashed line, `| Title`, `| -----`, a dashed line. check_timing has no box of its own.
        var sections: [String: [String]] = [:]
        var title: String?
        var k = 0
        while k < lines.count {
            let line = lines[k]
            if line.hasPrefix("| "), k + 1 < lines.count, lines[k + 1].hasPrefix("| ---") {
                title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                k += 3                                         // the title, its underline and the closing dashes
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "check_timing report" { title = "check_timing" }
            if let title, !(line.hasPrefix("-----") && k + 1 < lines.count && lines[k + 1].hasPrefix("| ")) {
                sections[title, default: []].append(line)
            }
            k += 1
        }
        func section(_ name: String) -> String {
            (sections[name] ?? []).joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        result.timerSettings = section("Timer Settings")
        result.clockSummary = section("Clock Summary")
        let check = sections["check_timing"] ?? []
        result.checkTiming = check.joined(separator: "\n").trimmingCharacters(in: .newlines)
        // The table of contents: `5. checking no_input_delay (3)`.
        for line in check {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), let open = t.lastIndex(of: "("),
                  t.hasSuffix(")"), let count = Int(t[t.index(after: open)..<t.index(before: t.endIndex)]) else { continue }
            let name = t[t.index(after: dot)..<open].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "checking ", with: "")
            if !result.checks.contains(where: { $0.name == name }) { result.checks.append((name, count)) }
        }
        var inTable = false
        for line in sections["Clock Summary"] ?? [] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-----") { inTable = true; continue }
            guard inTable, !t.isEmpty, let open = t.firstIndex(of: "{"), let close = t.firstIndex(of: "}") else { continue }
            let name = t[..<open].trimmingCharacters(in: .whitespaces)
            let after = t[t.index(after: close)...].split(separator: " ").map(String.init)
            result.clocks.append((name, String(t[open...close]), after.first ?? "", after.dropFirst().first ?? ""))
        }
        return result
    }
}
