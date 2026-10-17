import FPGABridgeCore
import Foundation

/// The window the left pane shows. Vivado puts the Netlist window next to Sources once a design is open.
enum SidePane: String, CaseIterable, Identifiable {
    case sources = "Sources"
    case netlist = "Netlist"
    var id: String { rawValue }
}

/// A place in a file for an open editor to select and scroll to. `token` changes on every request, so asking for the
/// same line twice still moves the editor there.
struct EditorReveal: Equatable {
    let range: NSRange
    let token: Int
}

extension AppModel {
    /// The design the Netlist and Properties windows are about, if it has been loaded.
    var activeSnapshot: DesignSnapshot? { activeDesign.flatMap { designs[$0] } }

    /// The object Properties shows: the most recently selected one.
    var primarySelection: DesignObjectRef? { designSelection.last }

    func designOpened(_ stage: DesignStage) {
        if activeDesign != stage { designSelection = [] }
        activeDesign = stage
        sidePane = .netlist
        propertiesShowsDesign = true
    }

    func designClosed(_ stage: DesignStage) {
        guard activeDesign == stage else { return }
        // Fall back to another open design, newest first, or back to Sources when none is left.
        activeDesign = openTabs.reversed().compactMap { tab -> DesignStage? in
            if case .design(let other) = tab { return other } else { return nil }
        }.first
        designSelection = []
        if activeDesign == nil {
            sidePane = .sources
            propertiesShowsDesign = false
        }
    }

    /// Selects an object in every design window. With `extend`, adds it to the selection (⌘-click), or takes it out
    /// if it was already there.
    func select(_ ref: DesignObjectRef?, extend: Bool = false) {
        guard let ref else {
            if !extend { designSelection = [] }
            return
        }
        if extend {
            if let index = designSelection.firstIndex(of: ref) { designSelection.remove(at: index) } else { designSelection.append(ref) }
        } else if designSelection != [ref] {
            designSelection = [ref]
        }
        propertiesShowsDesign = true
    }

    func select(_ refs: [DesignObjectRef]) {
        if designSelection != refs { designSelection = refs }
        propertiesShowsDesign = true
    }

    /// Whether a cell's HDL can be opened: Vivado knew its file, and the file is in this project.
    func canGoToSource(_ cell: DesignCell) -> Bool {
        guard let file = cell.sourceFile, cell.sourceLine != nil, let root = projectURL else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path)
    }

    /// Opens the file a cell comes from and selects the line, as Vivado's Go To Source does.
    func goToSource(_ cell: DesignCell) {
        guard let file = cell.sourceFile, let line = cell.sourceLine, let root = projectURL else { return }
        let url = root.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "\(file) isn't in this project any more."
            return
        }
        let text = (drafts[file] ?? (try? String(contentsOf: url, encoding: .utf8)) ?? "") as NSString
        let range = Self.range(ofLine: line, in: text)
        setCaret(range.location, in: file)
        editorReveal[file] = EditorReveal(range: range, token: (editorReveal[file]?.token ?? 0) + 1)
        openFile(file)
    }

    /// The UTF-16 range of a 1-based line, without its line break. Past the end means the last line.
    static func range(ofLine line: Int, in text: NSString) -> NSRange {
        var location = 0
        var current = 1
        while current < line, location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(lineRange)
            if next >= text.length { break }
            location = next
            current += 1
        }
        var contents = text.lineRange(for: NSRange(location: location, length: 0))
        while contents.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(contents) - 1)),
              CharacterSet.newlines.contains(scalar) {
            contents.length -= 1
        }
        return contents
    }
}
