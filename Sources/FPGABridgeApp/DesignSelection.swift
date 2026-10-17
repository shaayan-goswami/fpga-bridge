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

    /// Opens a design's window. The elaborated design opens on a schematic of the top, as Vivado's does.
    func showDesign(_ stage: DesignStage) {
        open(.design(stage))
        if stage == .rtl { openSchematic(stage) }
    }

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

// MARK: Schematic

extension AppModel {
    /// The open design's schematic: what it showed last, or the whole top level.
    func openSchematic(_ stage: DesignStage? = nil) {
        guard let stage = stage ?? activeDesign, designs[stage] != nil else { return }
        if schematicSpecs[stage] == nil { schematicSpecs[stage] = SchematicSpec() }
        open(.schematic(stage))
    }

    /// Shows a different view in a design's schematic, remembering the current one for Previous.
    func showSchematic(_ spec: SchematicSpec, in stage: DesignStage) {
        if let current = schematicSpecs[stage], current != spec {
            schematicHistory[stage, default: []].append(current)
            schematicFuture[stage] = []
        }
        schematicSpecs[stage] = spec
        open(.schematic(stage))
    }

    func schematicBack(_ stage: DesignStage) {
        guard let previous = schematicHistory[stage]?.popLast() else { return }
        if let current = schematicSpecs[stage] { schematicFuture[stage, default: []].append(current) }
        schematicSpecs[stage] = previous
    }

    func schematicForward(_ stage: DesignStage) {
        guard let next = schematicFuture[stage]?.popLast() else { return }
        if let current = schematicSpecs[stage] { schematicHistory[stage, default: []].append(current) }
        schematicSpecs[stage] = next
    }

    /// Opens or closes a module instance in place (Expand Inside / Collapse Inside).
    func toggleInSchematic(_ cell: String, stage: DesignStage) {
        var spec = schematicSpecs[stage] ?? SchematicSpec()
        if spec.expanded.contains(cell) { spec.expanded.remove(cell) } else { spec.expanded.insert(cell) }
        showSchematic(spec, in: stage)
    }

    /// The cells a schematic of the selection draws: selected cells, the cells of selected pins, and the cells a
    /// selected net or port connects at its own level.
    func cellsForSchematic(of refs: [DesignObjectRef], in design: DesignSnapshot) -> Set<String> {
        var cells: Set<String> = []
        func addNet(_ name: String) {
            guard let net = design.net(named: name) else { return }
            for end in net.endpoints where !end.isPort {
                if let pin = design.pins[end.name], pin.cellName != net.parentPath, design.cell(named: pin.cellName) != nil {
                    cells.insert(pin.cellName)
                }
            }
        }
        for ref in refs {
            switch ref.kind {
            case .cell: if design.cell(named: ref.name) != nil { cells.insert(ref.name) }
            case .pin: if let pin = design.pins[ref.name] { cells.insert(pin.cellName) }
            case .net: addNet(ref.name)
            case .port: if let net = design.net(ofPort: ref.name) { addNet(net) }
            }
        }
        return cells.filter { design.cell(named: $0)?.type != "GND" && design.cell(named: $0)?.type != "VCC" }
    }

    /// Vivado's Schematic command (F4): a schematic of what is selected, or of the top level when nothing is.
    func schematicOfSelection() {
        guard let stage = activeDesign, let design = designs[stage] else { return }
        let cells = cellsForSchematic(of: designSelection, in: design)
        showSchematic(cells.isEmpty ? SchematicSpec() : SchematicSpec(only: cells), in: stage)
    }
}
