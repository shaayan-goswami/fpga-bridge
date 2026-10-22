import Foundation

/// Block designs as sources of a project. A block design is a folder Vivado writes (`<name>/<name>.bd` with the IP
/// it uses under `ip/`); Vivado keeps it at `<project>.srcs/sources_1/bd/<name>/`. Anything under the project's source
/// folders is found, so copying that folder into the sources is enough to add one.
///
/// Builds don't generate block designs yet: the build script reads HDL only (`Project.sourceExtensions`), so a block
/// design in a source folder is left out of the build rather than breaking it.
extension Project {
    public static let blockDesignExtension = "bd"

    public static func isBlockDesign(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == blockDesignExtension
    }

    /// The project's block designs, relative to `root`, sorted: every `.bd` under its source folders, and any listed
    /// by name. Folders that are missing or outside the project are skipped (resolving the sources reports those).
    public func resolveBlockDesigns(in root: URL) -> [String] {
        var found = Set<String>()
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().path
        func relative(_ url: URL) -> String? {
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
        }
        for entry in sources where !entry.hasPrefix("/") && !entry.split(separator: "/").contains("..") {
            let url = root.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if Project.isBlockDesign(entry), let path = relative(url) { found.insert(path) }
                continue
            }
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil)
            while let item = walker?.nextObject() as? URL {
                // Vivado's generated output (`.gen`, `ip/` copies, `ipshared`) holds no block designs of its own.
                if item.lastPathComponent == "ipshared" || item.pathExtension == "gen" { walker?.skipDescendants(); continue }
                if Project.isBlockDesign(item.path), let path = relative(item) { found.insert(path) }
            }
        }
        return found.sorted()
    }

    /// What to tell someone building a project that has block designs: they're left out, and a block design listed by
    /// name in `sources` would be read as Verilog (so that build fails).
    public func blockDesignBuildNotes(in root: URL) -> [String] {
        let designs = resolveBlockDesigns(in: root)
        guard !designs.isEmpty else { return [] }
        let names = designs.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        var notes = ["WARNING: [FPGA Bridge] Block designs aren't built yet, so this build leaves out \(names). "
                     + "Generate Block Design is coming; until then, build them in Vivado and add the generated HDL as a source."]
        for entry in sources where Project.isBlockDesign(entry) {
            notes.append("ERROR: [FPGA Bridge] \(entry) is listed in \(Project.fileName) as a source file, so the build would read it as Verilog. "
                         + "List the folder that holds it instead.")
        }
        let modules = Set(designs.flatMap { path -> [String] in
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return [name, name + "_wrapper"]
        })
        if modules.contains(top) {
            notes.append("WARNING: [FPGA Bridge] The top module, \(top), is a block design's; synthesis won't find it until block designs are built.")
        }
        return notes
    }
}
