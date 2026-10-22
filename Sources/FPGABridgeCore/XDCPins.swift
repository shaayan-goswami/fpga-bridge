import Foundation

/// A constraints file of the project: its path (relative to the project) and its text.
public struct XDCFile: Equatable, Sendable {
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// One `set_property` in an XDC file that sets a property of ports: `set_property PACKAGE_PIN W5 [get_ports clk]`, or one
/// key of `set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]`.
public struct XDCPortSetting: Equatable, Sendable {
    /// The line it is on, counting from 0.
    public let line: Int
    /// Upper case: `PACKAGE_PIN`.
    public let property: String
    public let value: String
    /// The `get_ports` patterns, which may hold `*` and `?`.
    public let patterns: [String]
    public let isDict: Bool

    /// The one port this line is about, when it names exactly one without wildcards, which is the only kind of line
    /// that can be edited without changing other ports.
    public var singlePort: String? {
        patterns.count == 1 && !patterns[0].contains(where: { $0 == "*" || $0 == "?" }) ? patterns[0] : nil
    }

    public func applies(to port: String) -> Bool { patterns.contains { XDCPins.glob($0, matches: port) } }
}

/// What the constraints say about one port.
public struct XDCPortConstraints: Equatable, Sendable {
    public var packagePin: String?
    public var ioStandard: String?

    public init(packagePin: String? = nil, ioStandard: String? = nil) {
        self.packagePin = packagePin
        self.ioStandard = ioStandard
    }
}

/// Reads and edits the pin assignments in XDC files: `PACKAGE_PIN` and `IOSTANDARD` of ports. Editing changes only the
/// line (or the one key of a `-dict`) that sets the property, keeping every other line, comment, spacing and line
/// ending as it was, which is what I/O planning in Vivado does when it saves to the target constraints file.
public enum XDCPins {
    public static let packagePin = "PACKAGE_PIN"
    public static let ioStandard = "IOSTANDARD"

    // MARK: Reading

    /// Every port property set in a file, in order.
    public static func settings(in text: String) -> [XDCPortSetting] {
        parse(splitLines(text).map(\.text)).flatMap(\.settings)
    }

    /// The pin and standard each of `ports` gets, reading the files in order with the last setting winning, as when
    /// Vivado reads them.
    public static func constraints(for ports: [String], in files: [XDCFile]) -> [String: XDCPortConstraints] {
        var result: [String: XDCPortConstraints] = [:]
        for file in files {
            for setting in settings(in: file.text) where setting.property == packagePin || setting.property == ioStandard {
                for port in ports where setting.applies(to: port) {
                    if setting.property == packagePin { result[port, default: XDCPortConstraints()].packagePin = setting.value }
                    else { result[port, default: XDCPortConstraints()].ioStandard = setting.value }
                }
            }
        }
        return result
    }

    /// Whether any file assigns package pins. When one does, pins are managed in the XDC, so a port it doesn't
    /// mention has no pin, whatever an older build said.
    public static func assignsPackagePins(_ files: [XDCFile]) -> Bool {
        files.contains { settings(in: $0.text).contains { $0.property == packagePin } }
    }

    // MARK: Editing

    /// Sets a property of one port to `value`, or removes it when `value` is nil, and returns the files with the
    /// change made (unchanged files are returned as they were).
    ///
    /// - The last line that sets the property for the port alone is edited in place.
    /// - If the last line that sets it covers other ports too (a wildcard or a list), a line for this port alone is
    ///   added after it, so the others keep their value.
    /// - Otherwise the setting joins the port's own `-dict` line if it has one, goes after another line about the port,
    ///   or is added at the end of the target file (`target`, an index into `files`).
    public static func set(_ property: String, of port: String, to value: String?, in files: [XDCFile], target: Int = 0) -> [XDCFile] {
        let property = property.uppercased()
        var docs = files.map { Document(text: $0.text) }
        var matches: [(file: Int, command: Command, setting: XDCPortSetting)] = []
        var ownLines: [(file: Int, command: Command)] = []
        for (f, doc) in docs.enumerated() {
            for command in doc.commands {
                if command.settings.contains(where: { $0.singlePort == port }) { ownLines.append((f, command)) }
                for setting in command.settings where setting.property == property && setting.applies(to: port) {
                    matches.append((f, command, setting))
                }
            }
        }

        if let value {
            if let last = matches.last {
                if last.setting.singlePort == port {
                    docs[last.file].replaceValue(of: property, in: last.command, with: value)
                } else {
                    docs[last.file].insert(line: plainLine(property, value, port), after: last.command.line)
                }
            } else if let own = ownLines.last(where: { $0.command.isDict }) {
                docs[own.file].addKey(property, value: value, to: own.command)
            } else if let own = ownLines.last {
                docs[own.file].insert(line: plainLine(property, value, port), after: own.command.line)
            } else if docs.indices.contains(target) {
                docs[target].append(line: plainLine(property, value, port))
            }
        } else {
            // Bottom up, so the line numbers of the ones still to do stay right.
            for match in matches.reversed() where match.setting.singlePort == port {
                docs[match.file].remove(property, from: match.command)
            }
        }
        return zip(files, docs).map { XDCFile(path: $0.path, text: $1.text) }
    }

    /// `set_property PACKAGE_PIN W5 [get_ports clk]`, as Vivado writes it.
    public static func plainLine(_ property: String, _ value: String, _ port: String) -> String {
        "set_property \(property) \(value) [get_ports \(quoted(port))]"
    }

    /// A port name as Tcl needs it: braces around anything but letters, digits and underscores (`{led[0]}`).
    public static func quoted(_ port: String) -> String {
        port.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !port.isEmpty ? port : "{\(port)}"
    }

    /// Vivado's name matching for `get_ports`: `*` and `?` are wildcards; brackets are part of bus names, not
    /// character classes.
    public static func glob(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "?" || p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ni; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ni = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: Lines

    /// Lines with their own endings, so a file with Windows line endings is written back the same way. (Swift reads
    /// CR LF as one character, which is why this compares characters rather than splitting on "\n".)
    static func splitLines(_ text: String) -> [(text: String, end: String)] {
        var result: [(text: String, end: String)] = []
        var current = ""
        for ch in text {
            if ch == "\r\n" || ch == "\n" || ch == "\r" {
                result.append((current, String(ch)))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append((current, "")) }
        return result
    }

    // MARK: Parsing

    /// A word of a Tcl command, by character offsets into its line.
    struct Token {
        enum Kind { case bare, braced, quoted, bracketed }
        let kind: Kind
        let start: Int
        let end: Int
        /// The text inside the braces, quotes or brackets (the whole word for a bare one).
        var inner: Range<Int> { kind == .bare ? start..<end : (start + 1)..<(end - 1) }
    }

    /// A `set_property` command about ports, with where its parts are on its line.
    struct Command {
        let line: Int
        let isDict: Bool
        let settings: [XDCPortSetting]
        /// For a plain command, the value word; for a dict, each key's key and value words.
        let valueTokens: [String: Token]
        let keyTokens: [String: Token]
        let keyOrder: [String]
        /// The dict word itself.
        let dict: Token?
    }

    /// Splits `chars[range]` into Tcl words, stopping at the end of the command (`;`) or a comment. Nil if a brace,
    /// quote or bracket isn't closed on the line.
    static func tokens(_ chars: [Character], in range: Range<Int>) -> [Token]? {
        var result: [Token] = []
        var i = range.lowerBound
        func closing(_ open: Character, _ close: Character, from start: Int) -> Int? {
            var depth = 0
            var k = start
            while k < range.upperBound {
                let c = chars[k]
                if c == "\\" { k += 2; continue }
                if c == open { depth += 1 } else if c == close { depth -= 1; if depth == 0 { return k + 1 } }
                k += 1
            }
            return nil
        }
        while i < range.upperBound {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c == ";" { break }
            if c == "#" && result.isEmpty { break }
            switch c {
            case "{":
                guard let end = closing("{", "}", from: i) else { return nil }
                result.append(Token(kind: .braced, start: i, end: end)); i = end
            case "[":
                guard let end = closing("[", "]", from: i) else { return nil }
                result.append(Token(kind: .bracketed, start: i, end: end)); i = end
            case "\"":
                var k = i + 1
                while k < range.upperBound, chars[k] != "\"" { k += chars[k] == "\\" ? 2 : 1 }
                guard k < range.upperBound else { return nil }
                result.append(Token(kind: .quoted, start: i, end: k + 1)); i = k + 1
            default:
                var k = i
                while k < range.upperBound, chars[k] != " ", chars[k] != "\t", chars[k] != ";" {
                    if chars[k] == "\\" { k += 1 }
                    k += 1
                }
                k = min(k, range.upperBound)
                result.append(Token(kind: .bare, start: i, end: k)); i = k
            }
        }
        return result
    }

    static func text(_ chars: [Character], _ range: Range<Int>) -> String { String(chars[range]) }

    /// The ports a `[get_ports ...]` word names, or nil if it selects them some other way (`-filter`, `-of_objects`).
    static func ports(_ chars: [Character], _ token: Token) -> [String]? {
        guard token.kind == .bracketed, let words = tokens(chars, in: token.inner), words.count >= 2,
              ["get_ports", "get_port"].contains(text(chars, words[0].inner)) else { return nil }
        var patterns: [String] = []
        for word in words.dropFirst() {
            let value = text(chars, word.inner)
            if word.kind == .bare, value.hasPrefix("-") {
                if ["-quiet", "-verbose", "-nocase"].contains(value) { continue }
                return nil
            }
            if word.kind == .bracketed { return nil }
            if word.kind == .bare {
                patterns.append(value.replacingOccurrences(of: "\\", with: ""))
            } else {
                patterns += value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
        }
        return patterns.isEmpty ? nil : patterns
    }

    /// The `set_property` commands about ports in a file's lines. Commands that run on over several lines (a
    /// backslash at the end) are skipped: they can be read by Vivado but aren't edited here.
    static func parse(_ lines: [String]) -> [Command] {
        var commands: [Command] = []
        var continued = false
        for (index, line) in lines.enumerated() {
            let wasContinued = continued
            continued = line.hasSuffix("\\")
            if wasContinued || continued { continue }
            let chars = Array(line)
            guard let words = tokens(chars, in: 0..<chars.count), words.count >= 4,
                  text(chars, words[0].inner) == "set_property" else { continue }
            var k = 1
            while k < words.count, ["-quiet", "-verbose"].contains(text(chars, words[k].inner)) { k += 1 }
            guard k < words.count else { continue }
            if text(chars, words[k].inner) == "-dict" {
                guard k + 2 < words.count, let patterns = ports(chars, words[k + 2]) else { continue }
                let dict = words[k + 1]
                guard dict.kind == .braced || dict.kind == .quoted, let pairs = tokens(chars, in: dict.inner), pairs.count % 2 == 0 else { continue }
                var settings: [XDCPortSetting] = []
                var values: [String: Token] = [:], keys: [String: Token] = [:], order: [String] = []
                for p in stride(from: 0, to: pairs.count, by: 2) {
                    let key = text(chars, pairs[p].inner).uppercased()
                    let value = text(chars, pairs[p + 1].inner).trimmingCharacters(in: .whitespaces)
                    settings.append(XDCPortSetting(line: index, property: key, value: value, patterns: patterns, isDict: true))
                    values[key] = pairs[p + 1]
                    keys[key] = pairs[p]
                    order.append(key)
                }
                commands.append(Command(line: index, isDict: true, settings: settings, valueTokens: values, keyTokens: keys,
                                        keyOrder: order, dict: dict))
            } else {
                guard k + 2 < words.count, let patterns = ports(chars, words[k + 2]) else { continue }
                let key = text(chars, words[k].inner).uppercased()
                let value = text(chars, words[k + 1].inner).trimmingCharacters(in: .whitespaces)
                commands.append(Command(line: index, isDict: false,
                                        settings: [XDCPortSetting(line: index, property: key, value: value, patterns: patterns, isDict: false)],
                                        valueTokens: [key: words[k + 1]], keyTokens: [key: words[k]], keyOrder: [key], dict: nil))
            }
        }
        return commands
    }

    /// A file being edited: its lines and their endings.
    struct Document {
        var lines: [(text: String, end: String)]
        let newline: String
        let endsWithNewline: Bool

        init(text: String) {
            lines = XDCPins.splitLines(text)
            newline = lines.first { !$0.end.isEmpty }?.end ?? "\n"
            endsWithNewline = text.isEmpty || lines.last?.end.isEmpty == false
        }

        var commands: [Command] { XDCPins.parse(lines.map(\.text)) }

        var text: String { lines.map { $0.text + $0.end }.joined() }

        private mutating func edit(_ line: Int, _ change: (inout [Character]) -> Void) {
            var chars = Array(lines[line].text)
            change(&chars)
            lines[line].text = String(chars)
        }

        mutating func replaceValue(of key: String, in command: Command, with value: String) {
            guard let token = command.valueTokens[key] else { return }
            let word: String
            switch token.kind {
            case .braced: word = "{\(value)}"
            case .quoted: word = "\"\(value)\""
            default: word = value
            }
            edit(command.line) { $0.replaceSubrange(token.start..<token.end, with: Array(word)) }
        }

        mutating func addKey(_ key: String, value: String, to command: Command) {
            guard let dict = command.dict else { return }
            let at = command.keyOrder.last.flatMap { command.valueTokens[$0]?.end } ?? dict.inner.lowerBound
            let piece = command.keyOrder.isEmpty ? "\(key) \(value) " : " \(key) \(value)"
            edit(command.line) { $0.insert(contentsOf: Array(piece), at: at) }
        }

        mutating func remove(_ key: String, from command: Command) {
            guard command.isDict, command.keyOrder.count > 1, let index = command.keyOrder.firstIndex(of: key),
                  let keyToken = command.keyTokens[key], let valueToken = command.valueTokens[key] else {
                lines.remove(at: command.line)
                return
            }
            // The first pair goes with the space after it; any other with the space before it, so the spacing that's
            // left reads as before.
            let range: Range<Int>
            if index == 0, let next = command.keyTokens[command.keyOrder[1]] {
                range = keyToken.start..<next.start
            } else if let previous = command.valueTokens[command.keyOrder[index - 1]] {
                range = previous.end..<valueToken.end
            } else {
                return
            }
            edit(command.line) { $0.removeSubrange(range) }
        }

        mutating func insert(line text: String, after index: Int) {
            let indent = String(lines[index].text.prefix { $0 == " " || $0 == "\t" })
            if lines[index].end.isEmpty { lines[index].end = newline }
            lines.insert((indent + text, newline), at: index + 1)
            if index + 1 == lines.count - 1, !endsWithNewline { lines[index + 1].end = "" }
        }

        mutating func append(line text: String) {
            if let last = lines.indices.last, lines[last].end.isEmpty { lines[last].end = newline }
            lines.append((text, newline))
        }
    }
}
