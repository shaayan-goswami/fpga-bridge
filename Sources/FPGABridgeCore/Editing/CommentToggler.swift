import Foundation

/// Toggles line comments over the lines a selection touches, like Vivado's Toggle Line Comment.
public enum CommentToggler {
    public struct Result: Equatable {
        /// The whole text after toggling.
        public var text: String
        public var selection: NSRange
        /// What changed, as an edit to the original text: `replacedRange` of the old text became `replacement`. An
        /// editor applies this instead of replacing everything, which keeps its undo entry and scroll position small.
        public var replacedRange: NSRange
        public var replacement: String
    }

    public static func toggle(_ text: String, selection: NSRange, language: HDLLanguage) -> Result {
        let marker = language.lineComment
        let ns = text as NSString
        let unchanged = Result(text: text, selection: selection, replacedRange: NSRange(location: 0, length: 0), replacement: "")
        guard selection.location <= ns.length else { return unchanged }

        // A selection that ends right after a newline doesn't include the next line.
        var touched = selection
        if touched.length > 0, ns.character(at: NSMaxRange(touched) - 1) == 10 { touched.length -= 1 }
        let lineRange = ns.lineRange(for: touched)
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        func leadingWhitespace(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

        let content = lines.filter { !isBlank($0) }
        guard !content.isEmpty else { return unchanged }
        let allCommented = content.allSatisfy { $0.dropFirst(leadingWhitespace($0)).hasPrefix(marker) }
        let column = content.map(leadingWhitespace).min() ?? 0

        let toggled = lines.map { line -> String in
            guard !isBlank(line) else { return line }
            if allCommented {
                let indent = leadingWhitespace(line)
                var rest = String(line.dropFirst(indent + marker.count))
                if rest.hasPrefix(" ") { rest.removeFirst() }
                return String(line.prefix(indent)) + rest
            }
            let index = line.index(line.startIndex, offsetBy: column)
            return String(line[..<index]) + marker + " " + String(line[index...])
        }

        let newBlock = toggled.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let newText = ns.replacingCharacters(in: lineRange, with: newBlock)

        if selection.length == 0 {
            // Keep the caret in the same place relative to the text on its line.
            let delta = (toggled.first ?? "").utf16.count - (lines.first ?? "").utf16.count
            let location = max(lineRange.location, selection.location + delta)
            return Result(text: newText, selection: NSRange(location: location, length: 0),
                          replacedRange: lineRange, replacement: newBlock)
        }
        let length = newBlock.utf16.count - (hasTrailingNewline ? 1 : 0)
        return Result(text: newText, selection: NSRange(location: lineRange.location, length: length),
                      replacedRange: lineRange, replacement: newBlock)
    }
}
