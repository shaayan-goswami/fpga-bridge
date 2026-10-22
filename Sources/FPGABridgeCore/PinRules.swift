import Foundation

/// A port as I/O planning sees it: where it is (or is going) and with which standard.
public struct PlannedPort: Equatable, Sendable, Identifiable {
    public let name: String
    /// `IN`, `OUT` or `INOUT`.
    public let direction: String
    public var pin: String
    public var standard: String
    /// Whether it carries a clock, which should come in on a clock-capable pin.
    public var isClock: Bool

    public init(name: String, direction: String, pin: String, standard: String, isClock: Bool = false) {
        self.name = name
        self.direction = direction
        self.pin = pin
        self.standard = standard
        self.isClock = isClock
    }

    public var id: String { name }
    public var isPlaced: Bool { !pin.isEmpty }
}

/// Something wrong with the pin plan. Rules Vivado's DRC also has carry its ID (`BIVC-1`).
public struct PinIssue: Equatable, Hashable, Sendable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public let severity: Severity
    public let rule: String
    public let ports: [String]
    public let pins: [String]
    public let message: String

    public init(_ severity: Severity, rule: String, ports: [String] = [], pins: [String] = [], message: String) {
        self.severity = severity
        self.rule = rule
        self.ports = ports
        self.pins = pins
        self.message = message
    }

    public var id: String { "\(rule)|\(ports.joined(separator: ","))|\(pins.joined(separator: ","))|\(message)" }
}

/// The checks Vivado makes on I/O placement, made on the Mac from the part data: pins exist and are user I/O, one
/// port per pin, standards the bank supports, one VCCO and one VREF per bank, and differential pairs on P/N pins.
public enum PinRules {
    /// Everything wrong with a set of ports, errors first.
    public static func check(_ ports: [PlannedPort], part: PartData) -> [PinIssue] {
        var issues: [PinIssue] = []
        var byPin: [String: [PlannedPort]] = [:]
        var placed: [(port: PlannedPort, pin: PackagePin)] = []

        for port in ports {
            if let problem = standardProblem(port, part: part) { issues.append(problem) }
            guard port.isPlaced else {
                issues.append(PinIssue(.warning, rule: "UCIO-1", ports: [port.name],
                                       message: "\(port.name) has no package pin. The bitstream step refuses a design with unplaced ports."))
                continue
            }
            guard let pin = part.pin(named: port.pin) else {
                issues.append(PinIssue(.error, rule: "PIN", ports: [port.name], pins: [port.pin],
                                       message: "\(port.pin) isn't a pin of the \(part.package.isEmpty ? part.part : part.package) package."))
                continue
            }
            byPin[pin.name, default: []].append(port)
            guard pin.kind == .userIO else {
                issues.append(PinIssue(.error, rule: "PIN", ports: [port.name], pins: [pin.name],
                                       message: "\(pin.name) is a \(pin.kind.title.lowercased()) pin (\(pin.function)); a port needs a user I/O pin."))
                continue
            }
            placed.append((port, pin))
        }

        for (pin, here) in byPin where here.count > 1 {
            issues.append(PinIssue(.error, rule: "PIN", ports: here.map(\.name), pins: [pin],
                                   message: "\(here.map(\.name).joined(separator: " and ")) are all on \(pin)."))
        }

        // Each bank has one VCCO, and one VREF when any of its inputs uses one.
        for (bankName, group) in Dictionary(grouping: placed, by: { $0.pin.bank }) {
            guard let bank = part.bank(named: bankName) else { continue }
            // (A standard the part doesn't know at all is reported once, above.)
            for item in group where part.standard(named: item.port.standard) != nil && !bank.standards.isEmpty
                && !bank.standards.contains(item.port.standard) {
                issues.append(PinIssue(.error, rule: "BIVB-1", ports: [item.port.name], pins: [item.pin.name],
                                       message: "Bank \(bankName) (\(bank.type.title)) doesn't support \(item.port.standard), which \(item.port.name) uses."))
            }
            var voltages: [Double: [String]] = [:]
            var vrefs: [Double: [String]] = [:]
            for item in group {
                guard let std = part.standard(named: item.port.standard) else { continue }
                if item.port.direction.uppercased() == "INOUT" {
                    if let v = std.vcco(direction: "IN") { voltages[v, default: []].append(item.port.name) }
                    if let v = std.vcco(direction: "OUT"), v != std.vcco(direction: "IN") { voltages[v, default: []].append(item.port.name) }
                } else if let v = std.vcco(direction: item.port.direction) {
                    voltages[v, default: []].append(item.port.name)
                }
                if std.hasVREF, std.vref > 0, item.port.direction.uppercased() != "OUT" { vrefs[std.vref, default: []].append(item.port.name) }
            }
            if voltages.count > 1 {
                let parts = voltages.keys.sorted().map { "\(volts($0)) (\(list(voltages[$0] ?? [])))" }
                issues.append(PinIssue(.error, rule: "BIVC-1", ports: voltages.values.flatMap { $0 }.sorted(), pins: group.map(\.pin.name),
                                       message: "Bank \(bankName) can have only one VCCO, but its ports need \(parts.joined(separator: " and "))."))
            }
            if vrefs.count > 1 {
                let parts = vrefs.keys.sorted().map { "\(volts($0)) (\(list(vrefs[$0] ?? [])))" }
                issues.append(PinIssue(.error, rule: "VREF", ports: vrefs.values.flatMap { $0 }.sorted(), pins: group.map(\.pin.name),
                                       message: "Bank \(bankName) can have only one VREF, but its inputs need \(parts.joined(separator: " and "))."))
            }
            if !vrefs.isEmpty {
                for item in group where item.pin.isVREF {
                    issues.append(PinIssue(.warning, rule: "VREF", ports: [item.port.name], pins: [item.pin.name],
                                           message: "\(item.pin.name) is bank \(bankName)'s VREF pin, which the bank's VREF inputs need, unless INTERNAL_VREF is set."))
                }
            }
        }

        // Differential pairs: the P port on a P pin, the N port on its partner, nothing single-ended next to them.
        let pinOfPort = Dictionary(placed.map { ($0.port.name, $0.pin) }, uniquingKeysWith: { a, _ in a })
        let portOnPin = Dictionary(placed.map { ($0.pin.name, $0.port) }, uniquingKeysWith: { a, _ in a })
        for (port, pin) in placed {
            guard let std = part.standard(named: port.standard) else { continue }
            if std.isDifferential {
                guard pin.isDifferential, !pin.diffPair.isEmpty else {
                    issues.append(PinIssue(.error, rule: "IOSTDTYPE-1", ports: [port.name], pins: [pin.name],
                                           message: "\(port.name) uses the differential standard \(port.standard), but \(pin.name) isn't part of a differential pair."))
                    continue
                }
                let side = differentialSide(of: port.name)
                if side == .negative {
                    if let positive = partner(of: port.name, in: ports), let other = pinOfPort[positive], other.diffPair != pin.name {
                        issues.append(PinIssue(.error, rule: "DIFF", ports: [positive, port.name], pins: [other.name, pin.name],
                                               message: "\(port.name) must be on \(other.diffPair), the N pin paired with \(positive)'s pin \(other.name)."))
                    } else if pin.isPositive {
                        issues.append(PinIssue(.error, rule: "DIFF", ports: [port.name], pins: [pin.name],
                                               message: "\(port.name) is the N side of a pair, but \(pin.name) is a P pin. Put it on \(pin.diffPair)."))
                    }
                } else if !pin.isPositive {
                    issues.append(PinIssue(.error, rule: "DIFF", ports: [port.name], pins: [pin.name],
                                           message: "\(port.name) must be on the P pin of a pair; \(pin.name) is the N pin. Use \(pin.diffPair)."))
                }
            } else if let neighbour = portOnPin[pin.diffPair], let otherStd = part.standard(named: neighbour.standard), otherStd.isDifferential {
                issues.append(PinIssue(.error, rule: "DIFF", ports: [port.name, neighbour.name], pins: [pin.name, pin.diffPair],
                                       message: "\(pin.name) is the other half of the differential pair \(neighbour.name) uses, so it can't take the single-ended \(port.name)."))
            }
            if port.isClock, !pin.isClockCapable, !pin.isGlobalClock {
                issues.append(PinIssue(.warning, rule: "CLK", ports: [port.name], pins: [pin.name],
                                       message: "\(port.name) is a clock, but \(pin.name) isn't clock-capable (MRCC or SRCC). Placement fails unless CLOCK_DEDICATED_ROUTE is FALSE."))
            }
        }
        return issues.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.message < $1.message }
    }

    /// Why `port` can't go on `pin` given where the others are, or nil if it can. Only errors refuse a placement;
    /// warnings (a clock on a pin that isn't clock-capable, say) are shown but allowed, as in Vivado.
    public static func placementProblem(port: PlannedPort, pin: String, others: [PlannedPort], part: PartData) -> String? {
        var moved = port
        moved.pin = pin
        let all = others.filter { $0.name != port.name } + [moved]
        let before = Set(check(others.filter { $0.name != port.name }, part: part).filter { $0.severity == .error })
        return check(all, part: part).first { issue in
            issue.severity == .error && !before.contains(issue) && (issue.ports.contains(port.name) || issue.pins.contains(where: { $0.caseInsensitiveCompare(pin) == .orderedSame }))
        }?.message
    }

    /// The standard itself: one the part knows, for the port's direction.
    static func standardProblem(_ port: PlannedPort, part: PartData) -> PinIssue? {
        guard !port.standard.isEmpty, !part.standards.isEmpty else { return nil }
        guard let std = part.standard(named: port.standard) else {
            return PinIssue(.error, rule: "IOSTD", ports: [port.name], message: "\(port.standard) isn't an I/O standard of \(part.part).")
        }
        guard std.supports(direction: port.direction) else {
            return PinIssue(.error, rule: "IOSTD", ports: [port.name],
                            message: "\(port.standard) can't be used for an \(port.direction.lowercased())put like \(port.name).")
        }
        return nil
    }

    public enum Side { case positive, negative, unknown }

    /// Which half of a differential pair a port is, by Vivado's naming habit: `clk_p`/`clk_n`, `rx_P`/`rx_N`.
    public static func differentialSide(of name: String) -> Side {
        let base = DesignNet.busName(of: name).lowercased()
        if base.hasSuffix("_n") { return .negative }
        if base.hasSuffix("_p") { return .positive }
        return .unknown
    }

    /// The P port that goes with an N port (`clk_n` → `clk_p`), if the design has one.
    static func partner(of name: String, in ports: [PlannedPort]) -> String? {
        guard let range = name.range(of: "_n", options: [.backwards, .caseInsensitive]) else { return nil }
        let upper = name[range].hasSuffix("N")
        let candidate = name.replacingCharacters(in: range, with: upper ? "_P" : "_p")
        return ports.contains { $0.name == candidate } ? candidate : nil
    }

    static func volts(_ v: Double) -> String { String(format: "%g V", v) }

    static func list(_ names: [String]) -> String {
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return sorted.count > 3 ? sorted.prefix(3).joined(separator: ", ") + " and \(sorted.count - 3) more" : sorted.joined(separator: ", ")
    }
}
