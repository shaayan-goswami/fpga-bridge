import Foundation

/// Works out the indentation for the line after Return is pressed.
public enum AutoIndent {
    /// `line` is the text of the current line before the caret. The new line keeps its indentation and gets one more
    /// level after a block opener (`begin`, `case`, `(`, `is`, `then`, ...).
    public static func indentation(afterLine line: String, language: HDLLanguage, indentWidth: Int = 4) -> String {
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        let code = stripComment(line, language: language).trimmingCharacters(in: .whitespaces)
        return opensBlock(code, language: language) ? leading + String(repeating: " ", count: indentWidth) : leading
    }

    private static func stripComment(_ line: String, language: HDLLanguage) -> String {
        guard let range = line.range(of: language.lineComment) else { return line }
        return String(line[..<range.lowerBound])
    }

    private static func opensBlock(_ code: String, language: HDLLanguage) -> Bool {
        guard !code.isEmpty else { return false }
        switch language {
        case .verilog:
            return code.hasSuffix("(") || code.hasSuffix("{")
                || code.range(of: #"\b(begin|case|casex|casez|fork|generate)\b(\s*:\s*\w+)?$"#, options: .regularExpression) != nil
        case .vhdl:
            return code.hasSuffix("(")
                || code.range(of: #"\b(is|then|begin|loop|generate)$"#, options: [.regularExpression, .caseInsensitive]) != nil
        case .constraints:
            return code.hasSuffix("{") || code.hasSuffix("\\")
        }
    }
}
