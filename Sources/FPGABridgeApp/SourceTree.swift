import FPGABridgeCore
import Foundation

/// Builds the Sources pane's Hierarchy view: the top module with its instances underneath, like Vivado's
/// "blinky (blinky.v)" > "u_div : clk_div (clk_div.v)".
enum SourceTreeBuilder {
    static func build(top: String, design: [String], constraints: [String], simulation: [String],
                      read: (String) -> String) -> [SourceNode] {
        var fileOf: [String: String] = [:]
        var bodyOf: [String: String] = [:]
        for path in design {
            for (name, body) in moduleBodies(in: ProjectCreator.stripComments(read(path))) {
                fileOf[name] = path
                bodyOf[name] = body
            }
        }
        let known = Set(fileOf.keys)
        var covered = Set<String>()

        func moduleNode(_ module: String, instance: String?, id: String, visiting: Set<String>) -> SourceNode {
            let path = fileOf[module] ?? ""
            covered.insert(path)
            let children = visiting.contains(module) || visiting.count > 12 ? [] :
                instances(in: bodyOf[module] ?? "", known: known.subtracting([module])).map { inst in
                    moduleNode(inst.module, instance: inst.name, id: "\(id)/\(inst.name)", visiting: visiting.union([module]))
                }
            return SourceNode(
                id: id,
                title: instance.map { "\($0) : \(module)" } ?? module,
                detail: "(\((path as NSString).lastPathComponent))",
                symbol: instance == nil ? "cpu" : "square.on.square",
                path: path, isTop: instance == nil,
                children: children.isEmpty ? nil : children)
        }

        var designChildren: [SourceNode] = []
        if known.contains(top) {
            designChildren.append(moduleNode(top, instance: nil, id: "top:\(top)", visiting: []))
        }
        for path in design where !covered.contains(path) {
            designChildren.append(fileNode(path))
        }

        return [
            SourceNode(id: "group.design", title: "Design Sources", detail: "(\(design.count))", symbol: "folder",
                       children: designChildren),
            SourceNode(id: "group.constraints", title: "Constraints", detail: "(\(constraints.count))", symbol: "folder",
                       children: [setNode("constrs_1", constraints)]),
            SourceNode(id: "group.simulation", title: "Simulation Sources", detail: "(\(simulation.count))", symbol: "folder",
                       children: [setNode("sim_1", simulation)]),
        ]
    }

    private static func setNode(_ name: String, _ files: [String]) -> SourceNode {
        SourceNode(id: "set.\(name)", title: name, detail: "(\(files.count))", symbol: "folder",
                   children: files.isEmpty ? nil : files.map(fileNode))
    }

    private static func fileNode(_ path: String) -> SourceNode {
        let isConstraint = (path as NSString).pathExtension.lowercased() == "xdc"
        return SourceNode(id: "file:\(path)", title: (path as NSString).lastPathComponent, detail: nil,
                          symbol: isConstraint ? "pin" : "doc.text", path: path)
    }

    static func moduleBodies(in text: String) -> [(String, String)] {
        let pattern = #"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)([\s\S]*?)\bendmodule\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let name = Range(match.range(at: 1), in: text), let body = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[name]), String(text[body]))
        }
    }

    /// `module_name [#(...)] instance_name (` for every known module, in source order.
    static func instances(in body: String, known: Set<String>) -> [(name: String, module: String)] {
        var found: [(Int, String, String)] = []
        for module in known {
            let pattern = "(?<![A-Za-z0-9_$])\(NSRegularExpression.escapedPattern(for: module))\\s*(?:#\\s*\\((?:[^()]|\\([^()]*\\))*\\)\\s*)?([A-Za-z_][A-Za-z0-9_$]*)\\s*\\("
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let r = Range(match.range(at: 1), in: body) {
                    found.append((match.range.location, String(body[r]), module))
                }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map { (name: $0.1, module: $0.2) }
    }
}
