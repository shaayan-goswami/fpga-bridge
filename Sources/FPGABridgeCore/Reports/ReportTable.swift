import Foundation

/// A `|`-bordered ASCII table as printed by Vivado's `report_utilization`.
struct ReportTable {
    struct Row {
        /// Leading spaces before the first cell's text. Vivado indents sub-rows (e.g. "LUT as Logic") deeper.
        let indent: Int
        let cells: [String]
    }

    let header: [String]
    let rows: [Row]

    func column(_ name: String) -> Int? {
        header.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Finds every table in `text`. A table is a run of lines starting with `+` or `|`;
    /// its first `|` line is the header, and the rest are rows.
    static func parseAll(_ text: String) -> [ReportTable] {
        var tables: [ReportTable] = []
        var block: [String] = []

        func flush() {
            let dataLines = block.filter { $0.hasPrefix("|") }
            block = []
            guard let headerLine = dataLines.first else { return }
            let rows = dataLines.dropFirst().map { line -> Row in
                let raw = splitCells(line)
                let first = raw.first ?? ""
                let indent = first.prefix { $0 == " " }.count
                return Row(indent: indent, cells: raw.map { $0.trimmingCharacters(in: .whitespaces) })
            }
            tables.append(ReportTable(header: splitCells(headerLine).map { $0.trimmingCharacters(in: .whitespaces) },
                                      rows: Array(rows)))
        }

        // Split on whole line breaks: some reports (report_power on Windows) end lines with CR LF, which Swift reads
        // as one character that never equals "\n".
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("+") || line.hasPrefix("|") {
                block.append(line)
            } else if !block.isEmpty {
                flush()
            }
        }
        flush()
        return tables
    }

    private static func splitCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if cells.first == "" { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells
    }
}
