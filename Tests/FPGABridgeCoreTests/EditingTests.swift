import XCTest
@testable import FPGABridgeCore

final class EditingTests: XCTestCase {
    // MARK: Comment toggling

    func testCommentsASingleLineAndKeepsTheCaretOnTheSameText() {
        let r = CommentToggler.toggle("assign led = count;\n", selection: NSRange(location: 7, length: 0), language: .verilog)
        XCTAssertEqual(r.text, "// assign led = count;\n")
        XCTAssertEqual(r.selection, NSRange(location: 10, length: 0))
    }

    func testUncommentsAndRemovesTheSpaceAfterTheMarker() {
        let r = CommentToggler.toggle("// assign led = count;\n", selection: NSRange(location: 0, length: 0), language: .verilog)
        XCTAssertEqual(r.text, "assign led = count;\n")
    }

    func testMultipleLinesKeepTheirRelativeIndentation() {
        let text = "    wire a;\n        wire b;\n    wire c;\n"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let commented = CommentToggler.toggle(text, selection: all, language: .verilog)
        XCTAssertEqual(commented.text, "    // wire a;\n    //     wire b;\n    // wire c;\n")
        let restored = CommentToggler.toggle(commented.text, selection: commented.selection, language: .verilog)
        XCTAssertEqual(restored.text, text, "toggling twice must give back the original")
    }

    func testMixedSelectionCommentsEverythingRatherThanUncommentingSome() {
        let r = CommentToggler.toggle("// a\nb\n", selection: NSRange(location: 0, length: 7), language: .verilog)
        XCTAssertEqual(r.text, "// // a\n// b\n")
    }

    func testTheEditCoversOnlyTheTouchedLines() {
        let text = "keep\nwire a;\nwire b;\nkeep too\n"
        let r = CommentToggler.toggle(text, selection: NSRange(location: 5, length: 14), language: .verilog)
        XCTAssertEqual(r.replacedRange, NSRange(location: 5, length: 16), "the two touched lines, not the whole text")
        XCTAssertEqual(r.replacement, "// wire a;\n// wire b;\n")
        // Applying the edit to the original must give the full result.
        XCTAssertEqual((text as NSString).replacingCharacters(in: r.replacedRange, with: r.replacement), r.text)
    }

    func testBlankLinesAreLeftAlone() {
        let r = CommentToggler.toggle("a\n\nb\n", selection: NSRange(location: 0, length: 5), language: .verilog)
        XCTAssertEqual(r.text, "// a\n\n// b\n")
    }

    func testSelectionEndingAfterNewlineDoesNotTouchTheNextLine() {
        let r = CommentToggler.toggle("a\nb\n", selection: NSRange(location: 0, length: 2), language: .verilog)
        XCTAssertEqual(r.text, "// a\nb\n")
    }

    func testVHDLAndXDCUseTheirOwnMarkers() {
        XCTAssertEqual(CommentToggler.toggle("x <= y;", selection: NSRange(location: 0, length: 0), language: .vhdl).text, "-- x <= y;")
        XCTAssertEqual(CommentToggler.toggle("set_property A B", selection: NSRange(location: 0, length: 0), language: .constraints).text,
                       "# set_property A B")
    }

    func testNoTrailingNewlineAndEmptyText() {
        XCTAssertEqual(CommentToggler.toggle("wire a;", selection: NSRange(location: 0, length: 7), language: .verilog).text, "// wire a;")
        XCTAssertEqual(CommentToggler.toggle("", selection: NSRange(location: 0, length: 0), language: .verilog).text, "")
    }

    func testOutOfRangeSelectionIsIgnored() {
        let r = CommentToggler.toggle("abc", selection: NSRange(location: 10, length: 0), language: .verilog)
        XCTAssertEqual(r.text, "abc")
    }

    // MARK: Auto indent

    func testKeepsTheCurrentIndentation() {
        XCTAssertEqual(AutoIndent.indentation(afterLine: "        wire a;", language: .verilog), "        ")
        XCTAssertEqual(AutoIndent.indentation(afterLine: "wire a;", language: .verilog), "")
    }

    func testIndentsAfterBlockOpeners() {
        XCTAssertEqual(AutoIndent.indentation(afterLine: "    always @(posedge clk) begin", language: .verilog), "        ")
        XCTAssertEqual(AutoIndent.indentation(afterLine: "    begin : blk", language: .verilog), "        ")
        XCTAssertEqual(AutoIndent.indentation(afterLine: "module top(", language: .verilog), "    ")
        XCTAssertEqual(AutoIndent.indentation(afterLine: "    case (state)", language: .verilog), "    ", "case (state) ends in ')' not 'case'")
    }

    func testCommentsDoNotOpenBlocks() {
        XCTAssertEqual(AutoIndent.indentation(afterLine: "    wire a; // begin", language: .verilog), "    ")
    }

    func testVHDLOpeners() {
        XCTAssertEqual(AutoIndent.indentation(afterLine: "architecture rtl of top is", language: .vhdl), "    ")
        XCTAssertEqual(AutoIndent.indentation(afterLine: "  IF a = '1' THEN", language: .vhdl), "      ")
    }

    // MARK: Highlighting

    func testTokensCoverKeywordsNumbersDirectivesStringsAndComments() {
        let text = "`timescale 1ns / 1ps\nmodule m; // top\n  assign a = 4'd0; \"s\"\nendmodule\n"
        let tokens = SyntaxHighlighter.tokens(in: text, language: .verilog)
        func has(_ kind: SyntaxToken.Kind, _ s: String) -> Bool {
            tokens.contains { $0.kind == kind && (text as NSString).substring(with: $0.range) == s }
        }
        XCTAssertTrue(has(.directive, "`timescale"))
        XCTAssertTrue(has(.keyword, "module"))
        XCTAssertTrue(has(.keyword, "endmodule"))
        XCTAssertTrue(has(.number, "4'd0"))
        XCTAssertTrue(has(.string, "\"s\""))
        XCTAssertTrue(has(.comment, "// top"))
    }

    func testCommentTokensComeLastSoTheyCoverKeywordsInsideThem() {
        let text = "// module here\n"
        let tokens = SyntaxHighlighter.tokens(in: text, language: .verilog)
        let comment = tokens.firstIndex { $0.kind == .comment }!
        let keyword = tokens.firstIndex { $0.kind == .keyword }!
        XCTAssertGreaterThan(comment, keyword, "later tokens are painted over earlier ones")
    }

    func testBlockCommentsSpanLinesAndUnterminatedOnesRunToTheEnd() {
        let text = "a /* one\ntwo */ b /* open\nstill open"
        let comments = SyntaxHighlighter.tokens(in: text, language: .verilog).filter { $0.kind == .comment }
            .map { (text as NSString).substring(with: $0.range) }
        XCTAssertEqual(comments, ["/* one\ntwo */", "/* open\nstill open"])
    }

    func testVHDLKeywordsIgnoreCaseAndXDCCommentsUseHash() {
        let vhdl = "ENTITY e IS\n"
        XCTAssertTrue(SyntaxHighlighter.tokens(in: vhdl, language: .vhdl).contains { $0.kind == .keyword })
        let xdc = "set_property X Y [get_ports clk] # note\n"
        let tokens = SyntaxHighlighter.tokens(in: xdc, language: .constraints)
        XCTAssertTrue(tokens.contains { $0.kind == .comment && (xdc as NSString).substring(with: $0.range) == "# note" })
        XCTAssertFalse(tokens.contains { $0.kind == .directive })
    }

    func testLanguageFromExtension() {
        XCTAssertEqual(HDLLanguage(fileExtension: "SV"), .verilog)
        XCTAssertEqual(HDLLanguage(fileExtension: "vhd"), .vhdl)
        XCTAssertEqual(HDLLanguage(fileExtension: "xdc"), .constraints)
        XCTAssertEqual(HDLLanguage(fileExtension: "txt"), .verilog)
    }

    func testEmojiAndMultibyteTextKeepRangesInUTF16() {
        let text = "// héllo 🎉\nmodule m;\n"
        let tokens = SyntaxHighlighter.tokens(in: text, language: .verilog)
        let keyword = tokens.first { $0.kind == .keyword }!
        XCTAssertEqual((text as NSString).substring(with: keyword.range), "module")
    }
}
