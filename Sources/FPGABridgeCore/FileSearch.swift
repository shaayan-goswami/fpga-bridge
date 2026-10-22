import Foundation

/// Edit > Find in Files and Replace in Files: searching the project's sources as plain text, a whole word or a
/// regular expression. Positions are UTF-16 ranges (what the editor and `NSRegularExpression` use), and line numbers
/// count CR LF, LF and lone CR line ends, so a file written on Windows reports the same lines Vivado would.
public enum FileSearch {
    public struct Options: Equatable, Sendable {
        public var text: String
        public var matchCase = false
        public var wholeWord = false
        public var regularExpression = false

        public init(text: String, matchCase: Bool = false, wholeWord: Bool = false, regularExpression: Bool = false) {
            self.text = text
            self.matchCase = matchCase
            self.wholeWord = wholeWord
            self.regularExpression = regularExpression
        }
    }

    /// One place the search text was found.
    public struct Match: Equatable, Sendable, Identifiable {
        /// Project-relative file.
        public var path: String
        /// 1-based line and column (the column counts characters, as an editor shows them).
        public var line: Int
        public var column: Int
        /// The whole line, without its line break.
        public var lineText: String
        /// Where the match is in the file, in UTF-16 units.
        public var range: NSRange
        /// Where the match is in `lineText`, in UTF-16 units.
        public var rangeInLine: NSRange
        /// What Replace would put there (only set when searching to replace).
        public var replacement: String?

        public var id: String { "\(path)@\(range.location)" }

        /// The line as it would read after replacing just this match.
        public var replacedLine: String? {
            guard let replacement else { return nil }
            return (lineText as NSString).replacingCharacters(in: rangeInLine, with: replacement)
        }
    }

    public enum SearchError: DescribedError, Equatable {
        case empty
        case badPattern(String)

        public var description: String {
            switch self {
            case .empty: return "Type something to find."
            case .badPattern(let why): return "The regular expression isn't valid: \(why)"
            }
        }
    }

    /// The expression the options describe. Whole words use Verilog's identifier characters (letters, digits, `_`
    /// and `$`), so `clk` doesn't match inside `clk_div`.
    public static func expression(for options: Options) throws -> NSRegularExpression {
        guard !options.text.isEmpty else { throw SearchError.empty }
        var pattern = options.regularExpression ? options.text : NSRegularExpression.escapedPattern(for: options.text)
        if options.wholeWord { pattern = "(?<![A-Za-z0-9_$])(?:\(pattern))(?![A-Za-z0-9_$])" }
        do {
            return try NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive])
        } catch {
            throw SearchError.badPattern((error as NSError).localizedFailureReason ?? error.localizedDescription)
        }
    }

    /// The template for a replacement: taken literally unless the search is a regular expression, where `$1` means
    /// the first group.
    public static func template(_ replacement: String, options: Options) -> String {
        options.regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// Every match in one file, in order. Empty matches (`^`, `x*`) are skipped: they mark no text to show or change.
    public static func matches(in text: String, path: String, expression: NSRegularExpression, template: String? = nil) -> [Match] {
        let ns = text as NSString
        let starts = lineStarts(ns)
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { result in
            let range = result.range
            guard range.length > 0 else { return nil }
            let index = lineIndex(of: range.location, in: starts)
            let lineStart = starts[index]
            let lineEnd = contentEnd(of: ns, from: lineStart)
            let lineText = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let column = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart)).count + 1
            // A match that runs past the end of its line is shown up to the line end.
            let inLine = NSRange(location: range.location - lineStart, length: min(range.length, lineEnd - range.location))
            let replacement = template.map { expression.replacementString(for: result, in: text, offset: 0, template: $0) }
            return Match(path: path, line: index + 1, column: column, lineText: lineText, range: range, rangeInLine: inLine,
                         replacement: replacement)
        }
    }

    /// The text with every match replaced, and how many were. Uses the same matches `matches` lists, so the preview
    /// and the result agree.
    public static func replacing(in text: String, expression: NSRegularExpression, template: String) -> (text: String, count: Int) {
        let results = expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).filter { $0.range.length > 0 }
        let output = NSMutableString(string: text)
        for result in results.reversed() {
            let replacement = expression.replacementString(for: result, in: text, offset: 0, template: template)
            output.replaceCharacters(in: result.range, with: replacement)
        }
        return (output as String, results.count)
    }

    /// Whether a file passes the File types filter: `*.v, *.sv` (commas, semicolons or spaces between), or empty
    /// for every file.
    public static func matchesFileTypes(_ path: String, filter: String) -> Bool {
        let patterns = filter.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
        guard !patterns.isEmpty else { return true }
        let name = (path as NSString).lastPathComponent
        return patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    // MARK: Lines

    /// UTF-16 offset of the start of each line. CR LF is one line end, as are LF and a lone CR.
    static func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        let length = text.length
        while i < length {
            let c = text.character(at: i)
            if c == 13 {
                if i + 1 < length, text.character(at: i + 1) == 10 { i += 1 }
                starts.append(i + 1)
            } else if c == 10 {
                starts.append(i + 1)
            }
            i += 1
        }
        return starts
    }

    static func lineIndex(of location: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Where a line's text ends: before its CR or LF.
    static func contentEnd(of text: NSString, from start: Int) -> Int {
        var i = start
        while i < text.length {
            let c = text.character(at: i)
            if c == 10 || c == 13 { break }
            i += 1
        }
        return i
    }
}
