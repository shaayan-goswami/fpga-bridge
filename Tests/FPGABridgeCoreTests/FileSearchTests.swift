import XCTest
@testable import FPGABridgeCore

final class FileSearchTests: XCTestCase {
    func find(_ text: String, in file: String, _ options: FileSearch.Options = .init(text: "")) throws -> [FileSearch.Match] {
        var o = options
        if o.text.isEmpty { o.text = text }
        return FileSearch.matches(in: file, path: "f.v", expression: try FileSearch.expression(for: o))
    }

    func testLinesAndColumnsWithCRLFAndLoneCR() throws {
        let file = "module a;\r\n  wire clk;\r\nendmodule\r\n// clk\rclk\n"
        let found = try find("clk", in: file)
        XCTAssertEqual(found.map(\.line), [2, 4, 5])
        XCTAssertEqual(found.map(\.column), [8, 4, 1])
        XCTAssertEqual(found.map(\.lineText), ["  wire clk;", "// clk", "clk"])
        let ns = file as NSString
        XCTAssertEqual(found.map { ns.substring(with: $0.range) }, ["clk", "clk", "clk"])
        XCTAssertEqual(found.map { ($0.lineText as NSString).substring(with: $0.rangeInLine) }, ["clk", "clk", "clk"])
    }

    func testColumnsCountCharactersNotUTF16() throws {
        let found = try find("x", in: "// é😀 x\n")
        XCTAssertEqual(found.first?.column, 7)
        XCTAssertEqual(found.first?.rangeInLine.location, 7, "the emoji is two UTF-16 units")
    }

    func testCaseWholeWordAndRegex() throws {
        let file = "CLK clk clk_div my_clk $clk\n"
        XCTAssertEqual(try find("clk", in: file).count, 5)
        XCTAssertEqual(try find("", in: file, .init(text: "clk", matchCase: true)).count, 4)
        XCTAssertEqual(try find("", in: file, .init(text: "clk", wholeWord: true)).map(\.column), [1, 5])
        XCTAssertEqual(try find("", in: file, .init(text: "clk_\\w+", regularExpression: true)).count, 1)
        XCTAssertEqual(try find("", in: file, .init(text: "a.b")).count, 0, "plain text isn't a pattern")
        XCTAssertThrowsError(try FileSearch.expression(for: .init(text: "(", regularExpression: true)))
        XCTAssertThrowsError(try FileSearch.expression(for: .init(text: "")))
        XCTAssertEqual(try find("", in: file, .init(text: "^", regularExpression: true)).count, 0, "empty matches are skipped")
    }

    func testReplacePlainTextIsLiteralAndRegexUsesGroups() throws {
        let plain = FileSearch.Options(text: "a.b")
        var result = FileSearch.replacing(in: "a.b axb a.b\r\n", expression: try FileSearch.expression(for: plain),
                                          template: FileSearch.template("$1\\", options: plain))
        XCTAssertEqual(result.text, "$1\\ axb $1\\\r\n")
        XCTAssertEqual(result.count, 2)

        let regex = FileSearch.Options(text: "(\\w+)_n\\b", regularExpression: true)
        result = FileSearch.replacing(in: "rst_n en_n x", expression: try FileSearch.expression(for: regex),
                                      template: FileSearch.template("n_$1", options: regex))
        XCTAssertEqual(result.text, "n_rst n_en x")
    }

    func testPreviewAgreesWithTheResult() throws {
        let options = FileSearch.Options(text: "clk", wholeWord: true)
        let expression = try FileSearch.expression(for: options)
        let template = FileSearch.template("clock", options: options)
        let file = "input clk,\r\n  clk_en; assign y = clk;\n"
        let preview = FileSearch.matches(in: file, path: "f.v", expression: expression, template: template)
        XCTAssertEqual(preview.compactMap(\.replacedLine), ["input clock,", "  clk_en; assign y = clock;"])
        XCTAssertEqual(FileSearch.replacing(in: file, expression: expression, template: template).count, preview.count)
    }

    func testFileTypesFilter() {
        XCTAssertTrue(FileSearch.matchesFileTypes("a/b.v", filter: ""))
        XCTAssertTrue(FileSearch.matchesFileTypes("a/b.V", filter: "*.v, *.sv"))
        XCTAssertTrue(FileSearch.matchesFileTypes("a/b.sv", filter: "*.v;*.sv"))
        XCTAssertFalse(FileSearch.matchesFileTypes("a/b.xdc", filter: "*.v *.sv"))
    }
}
