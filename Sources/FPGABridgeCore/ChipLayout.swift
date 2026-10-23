import CoreGraphics
import Foundation

/// Where each ball of a package is drawn: the grid of rows (letters, top to bottom) and columns (numbers, left to
/// right) seen from the top, A1 at the top left, as Vivado's Package window shows it by default.
public struct PackageLayout: Sendable {
    public static let pitch: CGFloat = 30
    /// Room for the row letters and column numbers.
    public static let margin: CGFloat = 30

    public let rows: [String]
    public let columns: Int
    public let centers: [String: CGPoint]
    public let size: CGSize

    public init(part: PartData) {
        rows = part.rows
        columns = part.columnCount
        let rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })
        var centers: [String: CGPoint] = [:]
        for pin in part.pins {
            guard let r = rowIndex[pin.row], pin.column > 0 else { continue }
            centers[pin.name] = PackageLayout.center(row: r, column: pin.column)
        }
        self.centers = centers
        size = CGSize(width: PackageLayout.margin * 2 + CGFloat(columns) * PackageLayout.pitch,
                      height: PackageLayout.margin * 2 + CGFloat(rows.count) * PackageLayout.pitch)
    }

    static func center(row: Int, column: Int) -> CGPoint {
        CGPoint(x: margin + (CGFloat(column) - 0.5) * pitch, y: margin + (CGFloat(row) + 0.5) * pitch)
    }

    /// Where a row's letter goes (left of the grid) and a column's number (above it).
    public func rowLabel(_ index: Int) -> CGPoint { CGPoint(x: PackageLayout.margin / 2, y: PackageLayout.center(row: index, column: 1).y) }
    public func columnLabel(_ column: Int) -> CGPoint { CGPoint(x: PackageLayout.center(row: 0, column: column).x, y: PackageLayout.margin / 2) }

    /// The pin under a point, if it is within half a pitch of its center.
    public func pin(at point: CGPoint) -> String? {
        let column = Int(((point.x - PackageLayout.margin) / PackageLayout.pitch).rounded(.down)) + 1
        let row = Int(((point.y - PackageLayout.margin) / PackageLayout.pitch).rounded(.down))
        guard rows.indices.contains(row), column >= 1, column <= columns else { return nil }
        let name = rows[row] + String(column)
        guard let c = centers[name], hypot(c.x - point.x, c.y - point.y) <= PackageLayout.pitch / 2 else { return nil }
        return name
    }
}

/// What a tile of the die is, for drawing it.
public enum TileCategory: String, Sendable, CaseIterable {
    case clbL, clbM, bram, dsp, io, ioLogic, clockManagement, clock, transceiver, config, pcie, interconnect, empty

    public var title: String {
        switch self {
        case .clbL: "CLB (SLICEL)"
        case .clbM: "CLB (SLICEM)"
        case .bram: "Block RAM"
        case .dsp: "DSP"
        case .io: "I/O"
        case .ioLogic: "I/O logic"
        case .clockManagement: "Clock management (MMCM, PLL)"
        case .clock: "Global clocking"
        case .transceiver: "Transceiver"
        case .config: "Configuration, XADC"
        case .pcie: "PCI Express"
        case .interconnect: "Interconnect"
        case .empty: "Other"
        }
    }

    /// Blocks that are taller than one row: Vivado lists them on their bottom row and leaves `NULL` tiles above.
    var spansRows: Bool { ![.clbL, .clbM, .interconnect, .empty, .clock].contains(self) }

    /// Whether a column of these is drawn at full width; interconnect and filler columns are drawn thin.
    var isWide: Bool { self != .interconnect && self != .empty }

    public init(tileType t: String) {
        if t.hasPrefix("CLBLL") { self = .clbL }
        else if t.hasPrefix("CLBLM") { self = .clbM }
        else if t == "BRAM_L" || t == "BRAM_R" { self = .bram }
        else if t == "DSP_L" || t == "DSP_R" { self = .dsp }
        else if t.hasPrefix("LIOB") || t.hasPrefix("RIOB") { self = .io }
        else if t.hasPrefix("LIOI") || t.hasPrefix("RIOI") { self = .ioLogic }
        else if t.hasPrefix("CMT_") && !t.hasPrefix("CMT_FIFO") { self = .clockManagement }
        else if t.hasPrefix("CLK_BUFG") || t.hasPrefix("CLK_HROW") { self = .clock }
        else if (t.hasPrefix("GTP_") || t.hasPrefix("GTX_") || t.hasPrefix("GTH_")) && !t.contains("INT_INTERFACE") { self = .transceiver }
        else if t.hasPrefix("CFG_CENTER") || t.hasPrefix("MONITOR_") { self = .config }
        else if t == "PCIE_BOT" || t == "PCIE_TOP" { self = .pcie }
        else if t == "INT_L" || t == "INT_R" || t.hasPrefix("INT_FEEDTHRU") { self = .interconnect }
        else { self = .empty }
    }
}

/// The die drawn from the part data: one column per tile column (thin for interconnect and fillers), one row per
/// tile row (thin for the clock and break rows), the top row of the die at the top. Blocks that span several rows
/// (block RAM, DSP, I/O pairs, clock management) are drawn as one rectangle.
public struct DieLayout: Sendable {
    public static let wide: CGFloat = 10
    public static let narrow: CGFloat = 3
    public static let rowHeight: CGFloat = 6
    public static let thinRow: CGFloat = 2

    public struct Block: Sendable {
        public let x: Int
        public let y: Int
        public let rows: Int
        public let type: String
        public let category: TileCategory
        public let frame: CGRect
    }

    public let blocks: [Block]
    public let size: CGSize
    private let columnX: [CGFloat]
    private let columnWidth: [CGFloat]
    /// By GRID_Y, the drawn top edge and height.
    private let rowTop: [CGFloat]
    private let rowSize: [CGFloat]
    private let tilesBySite: [String: DieTile]
    private let blockAt: [Int: Int]

    public init(part: PartData) {
        let width = part.gridWidth, height = part.gridHeight
        var types = Array(repeating: Array(repeating: "NULL", count: height), count: width)
        for column in part.columns where column.x < width { for (y, t) in column.types.enumerated() where y < height { types[column.x][y] = t } }

        // A column is wide if most of its tiles are something other than interconnect and filler.
        var columnWidth: [CGFloat] = []
        for x in 0..<width {
            let wideCount = types[x].filter { TileCategory(tileType: $0).isWide }.count
            columnWidth.append(wideCount * 4 >= height ? DieLayout.wide : DieLayout.narrow)
        }
        // A row is thin if most columns have a clock-row or break tile there (HCLK, BRKH, the top and bottom terms).
        var rowSize = Array(repeating: DieLayout.rowHeight, count: height)
        for y in 0..<height {
            let breaks = (0..<width).filter { x in
                let t = types[x][y]
                return t.hasPrefix("HCLK") || t.hasPrefix("BRKH") || t.hasPrefix("T_TERM") || t.hasPrefix("B_TERM")
            }.count
            if breaks * 2 >= width { rowSize[y] = DieLayout.thinRow }
        }
        var columnX: [CGFloat] = []
        var cursor: CGFloat = 0
        for w in columnWidth { columnX.append(cursor); cursor += w }
        var rowTop = Array(repeating: CGFloat(0), count: height)
        var top: CGFloat = 0
        for y in stride(from: height - 1, through: 0, by: -1) { rowTop[y] = top; top += rowSize[y] }

        var blocks: [Block] = []
        var blockAt: [Int: Int] = [:]
        for x in 0..<width {
            var y = 0
            while y < height {
                let t = types[x][y]
                let category = TileCategory(tileType: t)
                var span = 1
                if category.spansRows { while y + span < height, types[x][y + span] == "NULL" { span += 1 } }
                if t != "NULL" {
                    let minY = rowTop[y + span - 1]
                    let frame = CGRect(x: columnX[x], y: minY, width: columnWidth[x], height: rowTop[y] + rowSize[y] - minY)
                    for k in y..<(y + span) { blockAt[x * height + k] = blocks.count }
                    blocks.append(Block(x: x, y: y, rows: span, type: t, category: category, frame: frame))
                }
                y += span
            }
        }
        self.blocks = blocks
        self.blockAt = blockAt
        self.columnX = columnX
        self.columnWidth = columnWidth
        self.rowTop = rowTop
        self.rowSize = rowSize
        self.size = CGSize(width: cursor, height: top)
        var tiles: [String: DieTile] = [:]
        for tile in part.tiles { for site in tile.sites { tiles[site.name] = tile } }
        tilesBySite = tiles
    }

    /// The rectangle a clock region covers.
    public func frame(of region: ClockRegion) -> CGRect {
        let l = max(0, min(region.left, columnX.count - 1)), r = max(0, min(region.right, columnX.count - 1))
        let t = max(0, min(region.top, rowTop.count - 1)), b = max(0, min(region.bottom, rowTop.count - 1))
        guard !columnX.isEmpty, !rowTop.isEmpty else { return .zero }
        return CGRect(x: columnX[l], y: rowTop[t], width: columnX[r] + columnWidth[r] - columnX[l], height: rowTop[b] + rowSize[b] - rowTop[t])
    }

    /// The block drawn at a tile position.
    public func block(x: Int, y: Int) -> Block? { blockAt[x * rowTop.count + y].map { blocks[$0] } }

    /// The block under a point.
    public func block(at point: CGPoint) -> Block? {
        guard let x = columnX.lastIndex(where: { $0 <= point.x }), point.x < columnX[x] + columnWidth[x],
              let y = rowTop.indices.first(where: { rowTop[$0] <= point.y && point.y < rowTop[$0] + rowSize[$0] }) else { return nil }
        return block(x: x, y: y)
    }

    /// Where a site is drawn: its share of its tile's block. Sites side by side in the die (the two slices of a CLB)
    /// split it across; sites above each other (the two I/O buffers of an IOB tile, the RAMs of a block RAM) split it
    /// from the top down.
    public func frame(ofSite name: String) -> CGRect? {
        guard let tile = tilesBySite[name], let block = block(x: tile.x, y: tile.y) else { return nil }
        let sites = tile.sites.map(\.name)
        guard sites.count > 1, let index = DieLayout.order(sites).firstIndex(of: name) else { return block.frame }
        let n = CGFloat(sites.count), f = block.frame
        if f.width >= f.height {
            return CGRect(x: f.minX + f.width * CGFloat(index) / n, y: f.minY, width: f.width / n, height: f.height)
        }
        return CGRect(x: f.minX, y: f.minY + f.height * CGFloat(index) / n, width: f.width, height: f.height / n)
    }

    /// The sites of the block under a point, nearest first.
    public func sites(at point: CGPoint, in part: PartData) -> [String] {
        guard let block = block(at: point) else { return [] }
        return part.tiles.filter { $0.x == block.x && $0.y == block.y }.flatMap { $0.sites.map(\.name) }
            .sorted { a, b in
                let fa = frame(ofSite: a) ?? .zero, fb = frame(ofSite: b) ?? .zero
                return fa.contains(point) && !fb.contains(point)
            }
    }

    /// Sites in drawing order: by X, then from the highest Y down (the top of the die first).
    static func order(_ sites: [String]) -> [String] {
        func coordinates(_ s: String) -> (Int, Int) {
            guard let xr = s.range(of: "_X", options: .backwards) else { return (0, 0) }
            let rest = s[xr.upperBound...]
            let parts = rest.split(separator: "Y")
            return (Int(parts.first ?? "") ?? 0, Int(parts.count > 1 ? parts[1] : "") ?? 0)
        }
        return sites.sorted {
            let a = coordinates($0), b = coordinates($1)
            return a.0 != b.0 ? a.0 < b.0 : a.1 > b.1
        }
    }
}
