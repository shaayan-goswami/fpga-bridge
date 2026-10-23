import Foundation

/// A marker on the waveform's time axis (Vivado's Add Marker): a name and a time in the waveform's ticks.
public struct WaveMarker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var time: UInt64

    public init(id: UUID = UUID(), name: String, time: UInt64) {
        self.id = id
        self.name = name
        self.time = time
    }
}

/// What the Waveform tab looks like for one testbench: the rows (signals by hierarchical path, and dividers), their
/// radixes, the zoom and the markers. Saved as JSON next to the waveform (`<testbench>.wcfg.json`) and put back when
/// the same testbench runs again. Vivado's own `.wcfg` is undocumented XML, so this is its own format.
public struct WaveLayout: Codable, Equatable, Sendable {
    public enum Row: Codable, Equatable, Sendable {
        /// A signal, by its path (`tb.dut.count [7:0]`), since ids change from one run to the next.
        case signal(String)
        case divider(String)
    }

    public static let currentVersion = 1

    public var version = WaveLayout.currentVersion
    public var rows: [Row]
    /// Radix names (`WaveRadix.rawValue`) for signals that don't use the default, by path.
    public var radixes: [String: String]
    public var defaultRadix: String
    /// The visible window, in ticks.
    public var viewStart: Double
    public var viewEnd: Double
    public var markers: [WaveMarker]

    public init(rows: [Row], radixes: [String: String] = [:], defaultRadix: WaveRadix = .hex, viewStart: Double, viewEnd: Double,
                markers: [WaveMarker] = []) {
        self.rows = rows
        self.radixes = radixes
        self.defaultRadix = defaultRadix.rawValue
        self.viewStart = viewStart
        self.viewEnd = viewEnd
        self.markers = markers
    }

    /// Where the layout for a testbench goes: next to its waveform, `<project>.sim/sim_1/behav/<testbench>.wcfg.json`.
    public static func url(testbench: String, nextTo waveform: URL) -> URL {
        waveform.deletingLastPathComponent().appendingPathComponent("\(testbench).wcfg.json")
    }

    public static func load(from url: URL) throws -> WaveLayout {
        try JSONDecoder().decode(WaveLayout.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The layout applied to a new run's waveform: rows with signal ids, radixes by id, and the paths of signals
    /// that are gone (renamed or removed from the testbench), which are dropped.
    public struct Resolved: Equatable, Sendable {
        public enum Row: Equatable, Sendable {
            case signal(Int)
            case divider(String)
        }
        public var rows: [Row]
        public var radixes: [Int: WaveRadix]
        public var missing: [String]
    }

    public func resolve(in waveform: Waveform) -> Resolved {
        var byPath: [String: Int] = [:]
        for signal in waveform.signals where byPath[signal.path] == nil { byPath[signal.path] = signal.id }
        var rows: [Resolved.Row] = []
        var missing: [String] = []
        var radixes: [Int: WaveRadix] = [:]
        for row in self.rows {
            switch row {
            case .divider(let name): rows.append(.divider(name))
            case .signal(let path):
                guard let id = byPath[path] else { missing.append(path); continue }
                rows.append(.signal(id))
                if let radix = self.radixes[path].flatMap(WaveRadix.init(rawValue:)) { radixes[id] = radix }
            }
        }
        return Resolved(rows: rows, radixes: radixes, missing: missing)
    }
}
