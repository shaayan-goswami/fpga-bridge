import Foundation

public struct SyntaxToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case keyword, number, directive, string, comment }
    public let kind: Kind
    public let range: NSRange
}

/// Finds the pieces of an HDL or XDC file worth coloring. Tokens come back in paint order: apply them one after
/// another and later ones win, so a comment covers a keyword inside it.
public enum SyntaxHighlighter {
    public static func tokens(in text: String, language: HDLLanguage) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let whole = NSRange(text.startIndex..., in: text)

        func find(_ pattern: String, _ kind: SyntaxToken.Kind, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, range: whole) where match.range.length > 0 {
                tokens.append(SyntaxToken(kind: kind, range: match.range))
            }
        }

        let caseInsensitive: NSRegularExpression.Options = language == .vhdl ? [.caseInsensitive] : []
        find("\\b(" + language.keywords.joined(separator: "|") + ")\\b", .keyword, options: caseInsensitive)
        find("\\b\\d+'[sS]?[bBhHdDoO][0-9a-fA-F_xXzZ]+|\\b\\d[\\d_]*(\\.\\d+)?\\b", .number)
        if language == .verilog { find("`\\w+|\\$\\w+", .directive) }
        find("\"[^\"\\n]*\"", .string)

        switch language {
        case .verilog:
            find("//[^\\n]*", .comment)
            find("/\\*[\\s\\S]*?(\\*/|\\z)", .comment)
        case .vhdl:
            find("--[^\\n]*", .comment)
        case .constraints:
            find("#[^\\n]*", .comment)
        }
        return tokens
    }
}
