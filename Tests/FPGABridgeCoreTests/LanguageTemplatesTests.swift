import XCTest
@testable import FPGABridgeCore

final class LanguageTemplatesTests: XCTestCase {
    func testEveryLanguageHasTemplatesInSeveralGroups() {
        for language in TemplateLanguage.allCases {
            let templates = LanguageTemplates.all.filter { $0.language == language }
            XCTAssertGreaterThanOrEqual(templates.count, 4, language.rawValue)
            XCTAssertGreaterThanOrEqual(Set(templates.map(\.group)).count, 2, language.rawValue)
        }
    }

    func testIdsAreUniqueAndLookUpTheTemplate() {
        let ids = LanguageTemplates.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for template in LanguageTemplates.all {
            XCTAssertEqual(LanguageTemplates.template(id: template.id), template)
        }
        XCTAssertNil(LanguageTemplates.template(id: "nope"))
    }

    func testTheTreeIsLanguageThenGroupThenTemplate() {
        XCTAssertEqual(LanguageTemplates.tree.map(\.title), ["Verilog", "SystemVerilog", "VHDL", "XDC"])
        var leaves = 0
        for language in LanguageTemplates.tree {
            XCTAssertNil(language.template)
            for group in language.children ?? [] {
                XCTAssertNil(group.template)
                XCTAssertFalse((group.children ?? []).isEmpty, group.title)
                for leaf in group.children ?? [] {
                    XCTAssertNotNil(leaf.template, leaf.title)
                    XCTAssertNil(leaf.children)
                    leaves += 1
                }
            }
        }
        XCTAssertEqual(leaves, LanguageTemplates.all.count, "every template appears once in the tree")
    }

    func testEveryTemplateIsDescribedAndEndsWithOneNewline() {
        for t in LanguageTemplates.all {
            XCTAssertFalse(t.summary.isEmpty, t.id)
            XCTAssertTrue(t.text.hasSuffix("\n") && !t.text.hasSuffix("\n\n"), t.id)
            XCTAssertFalse(t.text.contains("\t"), "\(t.id) uses spaces, as the editor does")
            XCTAssertFalse(t.text.contains("<") && t.text.contains(">") && t.language == .xdc, t.id)
        }
    }

    /// Cheap structure checks: a template that opens a construct must close it.
    func testHDLTemplatesBalanceTheirKeywords() {
        func count(_ word: String, in text: String) -> Int {
            // Whole words only, ignoring comments.
            let code = text.split(separator: "\n").map { $0.components(separatedBy: "//")[0].components(separatedBy: "--")[0] }.joined(separator: "\n")
            return (try? NSRegularExpression(pattern: "\\b\(word)\\b"))?.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)) ?? 0
        }
        for t in LanguageTemplates.all where t.language == .verilog || t.language == .systemVerilog {
            XCTAssertEqual(count("module", in: t.text), count("endmodule", in: t.text), t.id)
            XCTAssertEqual(count("case", in: t.text), count("endcase", in: t.text), t.id)
            XCTAssertEqual(count("begin", in: t.text), count("end", in: t.text), "begin/end in \(t.id)")
        }
        for t in LanguageTemplates.all where t.language == .vhdl {
            let entities = count("entity", in: t.text)
            XCTAssertEqual(entities % 2, 0, "entity opens and closes in \(t.id)")
            XCTAssertEqual(count("architecture", in: t.text) % 2, 0, t.id)
        }
    }

    func testTemplatesLookLikeTheirLanguage() {
        for t in LanguageTemplates.all {
            switch t.language {
            case .verilog, .systemVerilog:
                XCTAssertTrue(t.text.contains("module") || t.text.contains("interface"), t.id)
            case .vhdl:
                XCTAssertTrue(t.text.contains("entity"), t.id)
                XCTAssertTrue(t.text.contains("architecture"), t.id)
            case .xdc:
                XCTAssertFalse(t.text.contains("module"), t.id)
                XCTAssertTrue(t.text.split(separator: "\n").allSatisfy { $0.hasPrefix("set_") || $0.hasPrefix("create_") }, t.id)
            }
        }
    }

    func testSearchMatchesNameGroupLanguageAndSummaryWithEveryWord() {
        XCTAssertTrue(LanguageTemplates.search("counter").contains { $0.name == "Binary Up Counter" })
        XCTAssertTrue(LanguageTemplates.search("vhdl counter").allSatisfy { $0.language == .vhdl })
        XCTAssertFalse(LanguageTemplates.search("vhdl counter").isEmpty)
        XCTAssertTrue(LanguageTemplates.search("FALSE PATH").contains { $0.name == "False Path" }, "case-insensitive")
        XCTAssertTrue(LanguageTemplates.search("block ram").contains { $0.group == "Memories" }, "matches the summary")
        XCTAssertEqual(LanguageTemplates.search("zzzz"), [])
        XCTAssertEqual(LanguageTemplates.search("   "), [])
    }

    func testEditorHighlightingFollowsTheLanguage() {
        XCTAssertEqual(TemplateLanguage.systemVerilog.highlighting, .verilog)
        XCTAssertEqual(TemplateLanguage.vhdl.highlighting, .vhdl)
        XCTAssertEqual(TemplateLanguage.xdc.highlighting, .constraints)
    }
}
