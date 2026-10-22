import Foundation

/// A JSON value that keeps the order of object keys. Vivado's `.bd` and `.xci` files list cells, pins and nets in the
/// order the design shows them (and a net's driver first), which `JSONSerialization` and `Codable` both lose.
public enum OrderedJSON: Equatable, Sendable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let x), .array(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.number(let x), .number(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        default: false
        }
    }

    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// An object's members in file order; empty for anything else.
    public var members: [(key: String, value: OrderedJSON)] {
        if case .object(let m) = self { return m }
        return []
    }

    public var elements: [OrderedJSON] {
        if case .array(let a) = self { return a }
        return []
    }

    /// The value as text: strings as they are, numbers and booleans written out (Vivado mixes `"32"` and `32`).
    public var text: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    public enum ParseError: DescribedError, Equatable {
        case invalid(offset: Int)
        public var description: String {
            switch self {
            case .invalid(let offset): "not valid JSON (at byte \(offset))"
            }
        }
    }

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipSpace()
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError.invalid(offset: parser.index) }
        return value
    }

    public static func parse(_ text: String) throws -> OrderedJSON { try parse(Data(text.utf8)) }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            // Space, tab, LF and CR: Vivado on Windows writes CR LF.
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func fail() -> ParseError { .invalid(offset: index) }

        mutating func expect(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else { throw fail() }
            index += 1
        }

        mutating func value() throws -> OrderedJSON {
            guard index < bytes.count else { throw fail() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [(key: String, value: OrderedJSON)] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try expect(UInt8(ascii: ":"))
                    skipSpace()
                    members.append((key, try value()))
                    skipSpace()
                    guard index < bytes.count else { throw fail() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return .object(members)
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value())
                    skipSpace()
                    guard index < bytes.count else { throw fail() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return .array(items)
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true"); return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false"); return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null"); return .null
            default:
                return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            for byte in word.utf8 { try expect(byte) }
        }

        mutating func number() throws -> Double {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start, let text = String(bytes: bytes[start..<index], encoding: .ascii), let n = Double(text) else {
                index = start
                throw fail()
            }
            return n
        }

        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw fail() }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        // A surrogate pair is two escapes making one character.
                        if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                           bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(UnicodeScalar(scalar).map(Character.init) ?? "?").utf8))
                    default: out.append(escape)       // \" \\ \/
                    }
                default:
                    out.append(byte)
                }
            }
            throw fail()
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                  let value = UInt32(text, radix: 16) else { throw fail() }
            index += 4
            return value
        }
    }
}
