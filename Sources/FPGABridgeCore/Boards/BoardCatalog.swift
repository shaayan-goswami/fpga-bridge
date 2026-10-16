import Foundation

/// Digilent boards that fit the plain bitstream-only flow (no Zynq processor system).
///
/// Part strings come from Digilent reference manuals and distributor listings.
/// Not included yet: Nexys A7-50T (sources disagree on its temperature grade, and Digilent has retired it)
/// and Zynq boards (need processor-system handling).
public enum BoardCatalog {
    public static let all: [Board] = [
        Board(id: "basys3", displayName: "Basys 3", part: "xc7a35tcpg236-1", family: "Artix-7", loaderName: "basys3"),
        Board(id: "arty-a7-35", displayName: "Arty A7-35", part: "xc7a35ticsg324-1L", family: "Artix-7",
              aliases: ["arty-a7-35t"], loaderName: "arty_a7_35t"),
        Board(id: "arty-a7-100", displayName: "Arty A7-100", part: "xc7a100tcsg324-1", family: "Artix-7",
              aliases: ["arty-a7-100t"], loaderName: "arty_a7_100t"),
        Board(id: "nexys-a7-100", displayName: "Nexys A7-100T", part: "xc7a100tcsg324-1", family: "Artix-7",
              aliases: ["nexys-a7-100t", "nexys-a7"], loaderName: "nexys_a7_100"),
        Board(id: "cmod-a7-15", displayName: "Cmod A7-15T", part: "xc7a15tcpg236-1", family: "Artix-7",
              aliases: ["cmod-a7-15t"], loaderName: "cmod_a7_15t"),
        Board(id: "cmod-a7-35", displayName: "Cmod A7-35T", part: "xc7a35tcpg236-1", family: "Artix-7",
              aliases: ["cmod-a7-35t"], loaderName: "cmod_a7_35t"),
        Board(id: "arty-s7-25", displayName: "Arty S7-25", part: "xc7s25csga324-1", family: "Spartan-7", loaderName: "arty_s7_25"),
        Board(id: "arty-s7-50", displayName: "Arty S7-50", part: "xc7s50csga324-1", family: "Spartan-7", loaderName: "arty_s7_50"),
    ]

    /// Case-insensitive lookup that ignores punctuation and spaces, so "Arty_A7-35" finds "arty-a7-35".
    public static func lookup(_ query: String) -> Board? {
        let q = normalize(query)
        return all.first { board in
            ([board.id] + board.aliases).contains { normalize($0) == q }
        }
    }

    /// Up to three close matches for a mistyped board name.
    public static func suggestions(for query: String) -> [Board] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let scored = all.map { board -> (Board, Int) in
            let names = ([board.id] + board.aliases).map(normalize)
            let best = names.map { name in
                q.count >= 3 && (name.contains(q) || q.contains(name)) ? 0 : editDistance(q, name)
            }.min() ?? Int.max
            return (board, best)
        }
        return scored.filter { $0.1 <= 3 }.sorted { $0.1 < $1.1 }.prefix(3).map { $0.0 }
    }

    /// A printable table for `new --list-boards`.
    public static func table() -> String {
        let idWidth = all.map { $0.id.count }.max() ?? 0
        let nameWidth = all.map { $0.displayName.count }.max() ?? 0
        return all.map {
            "\($0.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  "
                + "\($0.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \($0.part)"
        }.joined(separator: "\n")
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
