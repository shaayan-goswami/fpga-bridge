import FPGABridgeCore
import XCTest
@testable import FPGABridgeApp

@MainActor
final class LanguageTemplatesAppTests: ExampleSandboxTestCase {
    func makeModel() -> (AppModel, String) {
        let model = AppModel(backend: DemoBackend(speed: 0), persist: false)
        model.openExampleProject()
        let file = model.sourceTree.first?.children?.first?.path ?? ""
        return (model, file)
    }

    func testTheFlowNavigatorItemOpensTheTemplatesTab() {
        let (model, _) = makeModel()
        XCTAssertTrue(FlowItem.languageTemplates.isAvailable)
        XCTAssertFalse(FlowItem.ipCatalog.isAvailable, "still needs Vivado's IP tooling")
        model.perform(.languageTemplates)
        XCTAssertEqual(model.selectedTab, .templates)
        XCTAssertEqual(model.title(of: .templates), "Language Templates")
    }

    func testThereIsNowhereToInsertUntilAFileIsOpen() {
        let (model, file) = makeModel()
        XCTAssertFalse(model.canInsertTemplate)
        let before = model.drafts
        model.insertTemplate("wire x;\n")
        XCTAssertEqual(model.drafts, before, "nothing changes")
        model.openFile(file)
        XCTAssertTrue(model.canInsertTemplate)
        model.close(.file(file))
        XCTAssertFalse(model.canInsertTemplate, "the file's tab is closed again")
    }

    func testInsertGoesInAtTheCaretOnItsOwnLine() {
        let (model, file) = makeModel()
        model.openFile(file)
        model.updateDraft("alpha\nbeta\n", for: file)
        model.setCaret(8, in: file)           // in the middle of "beta"
        model.perform(.languageTemplates)     // switching to the templates tab keeps the file for later
        model.insertTemplate("// snippet\n")

        XCTAssertEqual(model.editedText(for: file), "alpha\nbe\n// snippet\nta\n")
        XCTAssertEqual(model.selectedTab, .file(file), "shows the file it went into")
        XCTAssertEqual(model.caret(in: file), 8 + 1 + "// snippet\n".utf16.count, "caret ends up after the snippet")
        XCTAssertTrue(model.isDirty(file))
    }

    func testInsertAtTheStartOfALineAddsNoExtraNewline() {
        let (model, file) = makeModel()
        model.openFile(file)
        model.updateDraft("alpha\nbeta\n", for: file)
        model.setCaret(6, in: file)           // start of "beta"
        model.insertTemplate("X\n")
        XCTAssertEqual(model.editedText(for: file), "alpha\nX\nbeta\n")
    }

    func testWithoutACaretTheTemplateGoesAtTheEnd() {
        let (model, file) = makeModel()
        model.openFile(file)
        model.updateDraft("alpha\n", for: file)
        model.insertTemplate("X\n")
        XCTAssertEqual(model.editedText(for: file), "alpha\nX\n")
    }

    func testTheLastFileOpenedIsTheTarget() {
        let (model, file) = makeModel()
        // The example's top module has submodules nested under it in the hierarchy.
        guard let other = model.sourceTree.first?.children?.first?.children?.first?.path else { return XCTFail("example has submodules") }
        model.openFile(file)
        model.openFile(other)
        model.updateDraft("", for: other)
        model.insertTemplate("X\n")
        XCTAssertEqual(model.editedText(for: other), "X\n")
        XCTAssertNotEqual(model.editedText(for: file), "X\n")
    }
}
