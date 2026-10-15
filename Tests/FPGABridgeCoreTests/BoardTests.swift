import XCTest
@testable import FPGABridgeCore

final class BoardTests: XCTestCase {
    func testLookupIgnoresCasePunctuationAndSpaces() {
        for query in ["basys3", "Basys-3", "BASYS 3", "basys_3"] {
            XCTAssertEqual(BoardCatalog.lookup(query)?.id, "basys3", query)
        }
        XCTAssertEqual(BoardCatalog.lookup("Arty_A7-35")?.id, "arty-a7-35")
        XCTAssertEqual(BoardCatalog.lookup("arty-a7-35t")?.id, "arty-a7-35")
        XCTAssertEqual(BoardCatalog.lookup("Nexys A7-100T")?.id, "nexys-a7-100")
    }

    func testLookupUnknownReturnsNil() {
        XCTAssertNil(BoardCatalog.lookup("zybo-z7-20"))
        XCTAssertNil(BoardCatalog.lookup(""))
    }

    func testKnownParts() {
        XCTAssertEqual(BoardCatalog.lookup("basys3")?.part, "xc7a35tcpg236-1")
        XCTAssertEqual(BoardCatalog.lookup("arty-a7-35")?.part, "xc7a35ticsg324-1L")
        XCTAssertEqual(BoardCatalog.lookup("arty-s7-50")?.part, "xc7s50csga324-1")
    }

    func testSuggestionsForTypos() {
        XCTAssertEqual(BoardCatalog.suggestions(for: "basis3").first?.id, "basys3")
        XCTAssertTrue(BoardCatalog.suggestions(for: "arty").contains { $0.id.hasPrefix("arty") })
        XCTAssertTrue(BoardCatalog.suggestions(for: "completely-unrelated-board").isEmpty)
        XCTAssertLessThanOrEqual(BoardCatalog.suggestions(for: "arty").count, 3)
    }

    func testCatalogIdsAndAliasesAreUnique() {
        let names = BoardCatalog.all.flatMap { [$0.id] + $0.aliases }.map(BoardCatalog.normalize)
        XCTAssertEqual(names.count, Set(names).count, "a board id or alias is used twice")
    }

    func testEveryCatalogPartIsAcceptedByProject() throws {
        for board in BoardCatalog.all {
            let project = Project(name: "p", top: "top", part: board.part, sources: ["src"], constraints: [], board: board.id)
            XCTAssertNoThrow(try project.validate(), board.id)
        }
    }

    func testProjectBoardFieldIsOptionalInJSON() throws {
        let old = #"{"name":"p","top":"t","part":"x","sources":["s"],"constraints":[]}"#
        XCTAssertNil(try JSONDecoder().decode(Project.self, from: Data(old.utf8)).board)
    }

    func testTableListsEveryBoard() {
        let table = BoardCatalog.table()
        for board in BoardCatalog.all {
            XCTAssertTrue(table.contains(board.id) && table.contains(board.part), board.id)
        }
    }
}
