import AppKit
import FPGABridgeCore
import SwiftUI

/// Block designs in the app: listed under Design Sources as Vivado lists them, opened in a Block Design tab from the
/// Sources pane or Flow Navigator ▸ Open Block Design, and left out of builds with a note saying so. Viewing only:
/// creating, editing and generating block designs come once builds run Vivado's IP Integrator.
extension AppModel {
    /// The project's block designs (project-relative `.bd` paths), as the Sources pane lists them.
    var blockDesignPaths: [String] {
        BlockDesignSources.paths(in: sourceTree)
    }

    /// Why a Flow Navigator item can't be used now, if it can't. Open Block Design depends on the project having one.
    func unavailableReason(of item: FlowItem) -> String? {
        if item == .openBlockDesign, blockDesignPaths.isEmpty {
            return "This project has no block design. Copy a block design's folder (from <project>.srcs/sources_1/bd in Vivado) into a design source folder to view it."
        }
        return item.unavailableReason
    }

    /// Flow Navigator ▸ Open Block Design: the only one opens straight away; with several, Vivado asks which.
    func openBlockDesign() {
        let paths = blockDesignPaths
        guard !paths.isEmpty else { return }
        if paths.count == 1 { openBlockDesign(paths[0]); return }
        let alert = NSAlert()
        alert.messageText = "Open Block Design"
        alert.informativeText = "Choose the block design to open."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: paths.map(BlockDesignSources.name(of:)))
        alert.accessoryView = popup
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, paths.indices.contains(popup.indexOfSelectedItem) {
            openBlockDesign(paths[popup.indexOfSelectedItem])
        }
    }

    func openBlockDesign(_ path: String) {
        echoTcl("open_bd_design {\(path)}")
        open(.blockDesign(path))
    }

    /// What to say in the Tcl Console before a build: which block designs it leaves out. (Not the run's log, which is
    /// cleared as the run starts.)
    var blockDesignBuildNotes: [ConsoleLine] {
        guard let project, let projectURL else { return [] }
        return project.blockDesignBuildNotes(in: projectURL).map { ConsoleLine(text: $0, kind: ConsoleLine.classify($0)) }
    }

    func blockDesignTitle(_ path: String) -> String { "Block Design - \(BlockDesignSources.name(of: path))" }
}

/// The Sources pane's entries for block designs: under Design Sources, `mb_system (mb_system.bd)` with its IP
/// underneath (`microblaze_0 : mb_system_microblaze_0_0`), as Vivado shows a block design that hasn't been generated.
enum BlockDesignSources {
    static let symbol = "square.grid.3x1.below.line.grid.1x2"
    static let idPrefix = "bd:"

    /// `mb_system` for `.../mb_system.bd`.
    static func name(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Adds the project's block designs to a tree built from its HDL sources.
    static func adding(to tree: [SourceNode], project: Project, root: URL) -> [SourceNode] {
        let paths = project.resolveBlockDesigns(in: root)
        guard !paths.isEmpty, let index = tree.firstIndex(where: { $0.id == "group.design" }) else { return tree }
        var tree = tree
        let nodes = paths.map { node(for: $0, design: try? BlockDesign.load(from: root.appendingPathComponent($0))) }
        tree[index].children = (tree[index].children ?? []) + nodes
        if let detail = tree[index].detail, let count = Int(detail.trimmingCharacters(in: CharacterSet(charactersIn: "()"))) {
            tree[index].detail = "(\(count + paths.count))"
        }
        return tree
    }

    static func node(for path: String, design: BlockDesign?) -> SourceNode {
        let blocks = (design?.allCells ?? []).filter { !$0.xciName.isEmpty || $0.kind != .hierarchy }.map { cell in
            SourceNode(id: "\(idPrefix)\(path)#\(cell.path)",
                       title: cell.xciName.isEmpty ? cell.name : "\(cell.name) : \(cell.xciName)",
                       detail: cell.xciName.isEmpty ? nil : "(\(cell.xciName).xci)",
                       symbol: cell.kind == .moduleReference ? "doc.text" : "puzzlepiece.extension", path: path)
        }
        return SourceNode(id: idPrefix + path, title: name(of: path), detail: "(\((path as NSString).lastPathComponent))",
                          symbol: symbol, path: path, children: blocks.isEmpty ? nil : blocks)
    }

    static func paths(in tree: [SourceNode]) -> [String] {
        tree.flatMap { node -> [String] in
            let own = node.id.hasPrefix(idPrefix) && !node.id.contains("#") ? [node.path].compactMap { $0 } : []
            return own + paths(in: node.children ?? [])
        }
    }
}
