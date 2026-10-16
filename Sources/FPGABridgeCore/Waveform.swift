import Foundation

/// One signal in a waveform: its name, where it sits in the design, and every change of its value.
public struct WaveSignal: Identifiable, Equatable, Sendable {
    /// Index in `Waveform.signals`.
    public let id: Int
    public let name: String
    /// The scopes it sits in, outermost first: ["tb", "dut"].
    public let scope: [String]
    public let width: Int
    /// "wire", "reg", "integer", "parameter", and so on.
    public let kind: String
    /// Times of the changes, in ticks of the waveform's timescale, ascending. Parallel to `values`.
    public internal(set) var times: [UInt64]
    /// Values as bit strings, most significant bit first, padded to `width`: "0101", "1", "x", "zz01".
    public internal(set) var values: [String]

    public var path: String { (scope + [name]).joined(separator: ".") }
    public var isBus: Bool { width > 1 }
}

/// A scope in the design hierarchy and what is in it.
public struct WaveScope: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var signals: [Int]
    public var children: [WaveScope]
}

public enum WaveRadix: String, CaseIterable, Sendable {
    case hex = "Hexadecimal"
    case decimal = "Unsigned Decimal"
    case signed = "Signed Decimal"
    case binary = "Binary"
}

/// A parsed VCD (value change dump) file, as written by Icarus Verilog, Verilator, GHDL and Vivado's simulator.
public struct Waveform: Equatable, Sendable {
    /// One tick is `timescaleValue` × `timescaleUnit`, e.g. 1 ps.
    public var timescaleValue: Double
    public var timescaleUnit: String
    public var signals: [WaveSignal]
    public var scopes: [WaveScope]
    /// The latest time at which anything was recorded.
    public var endTime: UInt64

    /// Seconds per tick.
    public var secondsPerTick: Double { timescaleValue * Waveform.unitSeconds[timescaleUnit, default: 1e-12] }

    static let unitSeconds: [String: Double] = ["s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15]

    // MARK: Parsing

    public enum ParseError: DescribedError {
        case notAWaveform
        case tooLarge(Int)

        public var description: String {
            switch self {
            case .notAWaveform: return "That file isn't a VCD waveform: no signals were found in it."
            case .tooLarge(let mb): return "The waveform is \(mb) MB, which is more than the viewer will load."
            }
        }
    }

    public static let maxBytes = 400_000_000

    public static func load(from url: URL) throws -> Waveform {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw ParseError.tooLarge(size / 1_000_000) }
        return try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func parse(_ text: String) throws -> Waveform { try parse(Data(text.utf8)) }

    public static func parse(_ data: Data) throws -> Waveform {
        var parser = VCDParser()
        data.withUnsafeBytes { parser.run($0.bindMemory(to: UInt8.self)) }
        guard !parser.signals.isEmpty else { throw ParseError.notAWaveform }
        return Waveform(timescaleValue: parser.timescaleValue, timescaleUnit: parser.timescaleUnit,
                        signals: parser.signals, scopes: parser.scopeTree(), endTime: parser.endTime)
    }

    // MARK: Queries

    /// The value of a signal at `time`: its last change at or before then. Nil before its first recorded value.
    public func value(of signal: Int, at time: UInt64) -> String? {
        let s = signals[signal]
        let i = Waveform.lastIndex(in: s.times, atOrBefore: time)
        return i >= 0 ? s.values[i] : nil
    }

    /// Index of the last element <= `time`, or -1.
    static func lastIndex(in times: [UInt64], atOrBefore time: UInt64) -> Int {
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    /// The changes that matter for drawing `start...end`: the one in force at `start` through the last one at or before `end`.
    public func visibleChanges(of signal: Int, from start: UInt64, to end: UInt64) -> Range<Int> {
        let s = signals[signal]
        let first = max(0, Waveform.lastIndex(in: s.times, atOrBefore: start))
        let last = Waveform.lastIndex(in: s.times, atOrBefore: end)
        return first..<max(first, last + 1)
    }

    // MARK: Formatting

    /// "112 ns", "2.0001 ms": a time in ticks, in the unit that reads best.
    public func formatTime(_ ticks: Double) -> String {
        if ticks == 0 { return "0 \(timescaleUnit == "us" ? "µs" : timescaleUnit)" }
        let seconds = abs(ticks) * secondsPerTick
        let units: [(String, Double)] = [("s", 1), ("ms", 1e-3), ("µs", 1e-6), ("ns", 1e-9), ("ps", 1e-12), ("fs", 1e-15)]
        let (name, scale) = units.first { seconds >= $0.1 * 0.9999 } ?? units.last!
        let value = (ticks < 0 ? -1 : 1) * seconds / scale
        let text = String(format: "%.4f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(text.isEmpty ? "0" : text) \(name)"
    }

    /// A bit string in the chosen radix. Any x or z in a digit shows as x or z for that digit; decimal can't, so it
    /// shows "x" for the whole value.
    public static func format(_ bits: String, radix: WaveRadix) -> String {
        guard bits.count > 1 else { return bits }
        switch radix {
        case .binary:
            return bits
        case .hex:
            let padded = String(repeating: "0", count: (4 - bits.count % 4) % 4) + bits
            var out = ""
            var chars = Substring(padded)
            while !chars.isEmpty {
                let nibble = chars.prefix(4)
                chars = chars.dropFirst(4)
                if nibble.contains(where: { $0 == "x" || $0 == "X" }) { out += "x" }
                else if nibble.contains(where: { $0 == "z" || $0 == "Z" }) { out += "z" }
                else { out += String(Int(nibble, radix: 2) ?? 0, radix: 16) }
            }
            return out
        case .decimal, .signed:
            guard !bits.contains(where: { "xXzZ".contains($0) }), bits.count <= 64 else { return bits.count > 64 ? "…" : "x" }
            let unsigned = UInt64(bits, radix: 2) ?? 0
            guard radix == .signed, bits.first == "1" else { return String(unsigned) }
            // Two's complement: subtract 2^width.
            return String(bits.count == 64 ? Int64(bitPattern: unsigned) : Int64(unsigned) - (Int64(1) << Int64(bits.count)))
        }
    }
}

/// Reads VCD bytes. Written against the bytes rather than lines: a simulation can write millions of changes.
struct VCDParser {
    var timescaleValue = 1.0
    var timescaleUnit = "ps"
    var signals: [WaveSignal] = []
    var endTime: UInt64 = 0

    private var scopePath: [String] = []
    private var scopeSignals: [[String]: [Int]] = [:]
    private var scopeOrder: [[String]] = []
    /// VCD id code -> every signal using it (the same net seen from several scopes shares one code).
    private var byCode: [Substring: [Int]] = [:]
    private var time: UInt64 = 0

    mutating func run(_ bytes: UnsafeBufferPointer<UInt8>) {
        var tokens = Tokens(bytes)
        var inDefinitions = true
        while let token = tokens.next() {
            if token.first == UInt8(ascii: "$") {
                switch String(decoding: token, as: UTF8.self) {
                case "$scope":
                    _ = tokens.next()                       // module, task, ...
                    let name = tokens.next().map { String(decoding: $0, as: UTF8.self) } ?? "?"
                    scopePath.append(name)
                    if scopeSignals[scopePath] == nil { scopeSignals[scopePath] = []; scopeOrder.append(scopePath) }
                    tokens.skipToEnd()
                case "$upscope":
                    _ = scopePath.popLast()
                    tokens.skipToEnd()
                case "$var":
                    readVar(&tokens)
                case "$timescale":
                    readTimescale(&tokens)
                case "$enddefinitions":
                    inDefinitions = false
                    tokens.skipToEnd()
                case "$dumpvars", "$dumpall", "$dumpon", "$dumpoff", "$end":
                    break                                    // the values inside are read as usual
                default:
                    tokens.skipToEnd()                       // $date, $version, $comment
                }
                continue
            }
            if inDefinitions { continue }
            readValue(token, &tokens)
        }
    }

    private mutating func readVar(_ tokens: inout Tokens) {
        var parts: [String] = []
        while let t = tokens.next() {
            let text = String(decoding: t, as: UTF8.self)
            if text == "$end" { break }
            parts.append(text)
        }
        // type size code name [range]
        guard parts.count >= 4, let width = Int(parts[1]) else { return }
        let range = parts.count > 4 ? " " + parts[4] : ""
        let id = signals.count
        let name = parts[3] + (width > 1 ? range : "")
        signals.append(WaveSignal(id: id, name: name, scope: scopePath, width: width, kind: parts[0], times: [], values: []))
        byCode[Substring(parts[2]), default: []].append(id)
        scopeSignals[scopePath, default: []].append(id)
    }

    private mutating func readTimescale(_ tokens: inout Tokens) {
        var text = ""
        while let t = tokens.next() {
            let part = String(decoding: t, as: UTF8.self)
            if part == "$end" { break }
            text += part
        }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        timescaleValue = Double(digits) ?? 1
        if !unit.isEmpty { timescaleUnit = unit }
    }

    private mutating func readValue(_ token: UnsafeBufferPointer<UInt8>.SubSequence, _ tokens: inout Tokens) {
        guard let first = token.first else { return }
        switch first {
        case UInt8(ascii: "#"):
            time = UInt64(String(decoding: token.dropFirst(), as: UTF8.self)) ?? time
            endTime = max(endTime, time)
        case UInt8(ascii: "b"), UInt8(ascii: "B"):
            guard let code = tokens.next() else { return }
            record(code: String(decoding: code, as: UTF8.self), bits: String(decoding: token.dropFirst(), as: UTF8.self).lowercased())
        case UInt8(ascii: "r"), UInt8(ascii: "R"), UInt8(ascii: "s"), UInt8(ascii: "S"):
            _ = tokens.next()                                // reals and strings aren't drawn
        case UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "x"), UInt8(ascii: "X"), UInt8(ascii: "z"), UInt8(ascii: "Z"):
            record(code: String(decoding: token.dropFirst(), as: UTF8.self), bits: String(UnicodeScalar(first)).lowercased())
        default:
            break
        }
    }

    private mutating func record(code: String, bits: String) {
        guard let ids = byCode[Substring(code)] else { return }
        for id in ids {
            let width = signals[id].width
            var value = bits
            if value.count < width, let lead = value.first {
                // Short vectors extend with 0, or with x or z if that is what they start with.
                value = String(repeating: lead == "x" || lead == "z" ? lead : "0", count: width - value.count) + value
            }
            if signals[id].values.last == value { continue }
            if let lastTime = signals[id].times.last, lastTime == time {
                // Two writes in one instant: the later wins. If that puts it back where it was, there was no change.
                let n = signals[id].values.count
                if n >= 2 && signals[id].values[n - 2] == value {
                    signals[id].values.removeLast()
                    signals[id].times.removeLast()
                } else {
                    signals[id].values[n - 1] = value
                }
            } else {
                signals[id].times.append(time)
                signals[id].values.append(value)
            }
        }
    }

    func scopeTree() -> [WaveScope] {
        func children(of parent: [String]) -> [WaveScope] {
            scopeOrder.filter { $0.count == parent.count + 1 && Array($0.prefix(parent.count)) == parent }.map { path in
                WaveScope(id: path.joined(separator: "."), name: path.last ?? "", signals: scopeSignals[path] ?? [], children: children(of: path))
            }
        }
        return children(of: [])
    }
}

/// Splits bytes on whitespace.
private struct Tokens {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    mutating func next() -> UnsafeBufferPointer<UInt8>.SubSequence? {
        while index < bytes.count, bytes[index] <= 32 { index += 1 }
        guard index < bytes.count else { return nil }
        let start = index
        while index < bytes.count, bytes[index] > 32 { index += 1 }
        return bytes[start..<index]
    }

    /// Skips tokens up to and including the next `$end`.
    mutating func skipToEnd() {
        while let t = next() {
            if t.count == 4, t.elementsEqual("$end".utf8) { return }
        }
    }
}
