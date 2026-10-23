import Foundation

/// What a package pin is for, worked out from Vivado's `PIN_FUNC`. The Package view draws each kind differently, and
/// only user I/O can take a port.
public enum PinKind: String, Sendable, CaseIterable {
    case userIO, ground, power, vcco, config, transceiver, analog, noConnect

    public var title: String {
        switch self {
        case .userIO: "User I/O"
        case .ground: "Ground"
        case .power: "Power"
        case .vcco: "VCCO"
        case .config: "Configuration"
        case .transceiver: "Gigabit transceiver"
        case .analog: "Analog (XADC)"
        case .noConnect: "Not connected"
        }
    }
}

/// One ball of the package, as Vivado's `get_package_pins` describes it.
public struct PackagePin: Equatable, Sendable, Identifiable {
    /// `W5`
    public let name: String
    /// The I/O bank (`34`), or "" for power and ground.
    public let bank: String
    /// Vivado's `PIN_FUNC`: `IO_L12P_T1_MRCC_34`, `GND`, `VCCO_34`, `TCK_0`...
    public let function: String
    /// The other pin of its differential pair, or "".
    public let diffPair: String
    public let isDifferential: Bool
    /// The P side of a differential pair (`IS_MASTER`).
    public let isPositive: Bool
    /// Clock-capable (an MRCC or SRCC pin).
    public let isClockCapable: Bool
    public let isGlobalClock: Bool
    public let isVREF: Bool
    /// A pin a port can go on (`IS_GENERAL_PURPOSE`).
    public let isUserIO: Bool
    public let isBonded: Bool
    /// The I/O site behind the pin (`IOB_X1Y26`), which places it on the die.
    public let site: String

    public init(name: String, bank: String, function: String, diffPair: String = "", isDifferential: Bool = false,
                isPositive: Bool = false, isClockCapable: Bool = false, isGlobalClock: Bool = false, isVREF: Bool = false,
                isUserIO: Bool = false, isBonded: Bool = true, site: String = "") {
        self.name = name
        self.bank = bank
        self.function = function
        self.diffPair = diffPair
        self.isDifferential = isDifferential
        self.isPositive = isPositive
        self.isClockCapable = isClockCapable
        self.isGlobalClock = isGlobalClock
        self.isVREF = isVREF
        self.isUserIO = isUserIO
        self.isBonded = isBonded
        self.site = site
    }

    public var id: String { name }

    /// The row letters (`W`, `AA`).
    public var row: String { String(name.prefix { $0.isLetter }) }
    /// The column number (5 for `W5`).
    public var column: Int { Int(name.drop { $0.isLetter }) ?? 0 }

    public var kind: PinKind {
        if isUserIO { return .userIO }
        let f = function.uppercased()
        if f == "NC" || f.hasPrefix("NC_") { return .noConnect }
        if ["VP_", "VN_", "VREFP_", "VREFN_", "DXP_", "DXN_", "VCCADC_", "GNDADC_"].contains(where: f.hasPrefix) { return .analog }
        if f.hasPrefix("VCCO") { return .vcco }
        if f.hasPrefix("GND") { return .ground }
        if f.hasPrefix("MGTAVCC") || f.hasPrefix("MGTAVTT") || f.hasPrefix("MGTVCCAUX") || f.hasPrefix("VCC") { return .power }
        if f.hasPrefix("MGT") { return .transceiver }
        return .config
    }
}

/// The kinds of I/O bank. 7-series high-range banks go up to 3.3 V; high-performance banks to 1.8 V.
public enum BankType: Equatable, Sendable {
    case highRange, highPerformance, transceiver, noUserIO
    case other(String)

    public init(vivado: String) {
        switch vivado {
        case "BT_HIGH_RANGE": self = .highRange
        case "BT_HIGH_PERFORMANCE": self = .highPerformance
        case "BT_MGT": self = .transceiver
        case "BT_NO_USER_IO": self = .noUserIO
        default: self = .other(vivado)
        }
    }

    public var vivado: String {
        switch self {
        case .highRange: "BT_HIGH_RANGE"
        case .highPerformance: "BT_HIGH_PERFORMANCE"
        case .transceiver: "BT_MGT"
        case .noUserIO: "BT_NO_USER_IO"
        case .other(let name): name
        }
    }

    public var title: String {
        switch self {
        case .highRange: "High Range"
        case .highPerformance: "High Performance"
        case .transceiver: "Transceiver"
        case .noUserIO: "Dedicated"
        case .other(let name): name
        }
    }
}

public struct IOBank: Equatable, Sendable, Identifiable {
    public let name: String
    public let type: BankType
    /// The I/O standards the bank supports, from `get_io_standards -of_objects`.
    public let standards: [String]

    public init(name: String, type: BankType, standards: [String]) {
        self.name = name
        self.type = type
        self.standards = standards
    }

    public var id: String { name }
    public var hasUserIO: Bool { type == .highRange || type == .highPerformance }
}

/// An I/O standard and the supply it needs, from Vivado's `get_io_standards`.
public struct IOStandardInfo: Equatable, Sendable, Identifiable {
    public let name: String
    /// The bank supply an input needs (0 when it doesn't depend on VCCO, as for VREF-based inputs).
    public let vccoIn: Double
    /// The bank supply an output needs.
    public let vccoOut: Double
    public let hasVREF: Bool
    public let vref: Double
    public let isDifferential: Bool
    /// `INPUT`, `OUTPUT`, `BIDIR`.
    public let directions: [String]
    public let driveStrengths: [String]
    public let slews: [String]

    public init(name: String, vccoIn: Double, vccoOut: Double, hasVREF: Bool = false, vref: Double = 0,
                isDifferential: Bool = false, directions: [String] = ["INPUT", "OUTPUT", "BIDIR"],
                driveStrengths: [String] = [], slews: [String] = []) {
        self.name = name
        self.vccoIn = vccoIn
        self.vccoOut = vccoOut
        self.hasVREF = hasVREF
        self.vref = vref
        self.isDifferential = isDifferential
        self.directions = directions
        self.driveStrengths = driveStrengths
        self.slews = slews
    }

    public var id: String { name }

    /// Whether a port of this direction (`IN`, `OUT`, `INOUT`) can use the standard.
    public func supports(direction: String) -> Bool {
        switch direction.uppercased() {
        case "IN": directions.contains("INPUT")
        case "OUT": directions.contains("OUTPUT")
        case "INOUT": directions.contains("BIDIR")
        default: true
        }
    }

    /// The bank supply a port of this direction needs, or nil if it doesn't constrain it.
    public func vcco(direction: String) -> Double? {
        let value = direction.uppercased() == "IN" ? vccoIn : vccoOut
        return value > 0 ? value : nil
    }
}

/// A clock region and the tiles it spans, in grid coordinates (`GRID_X`, `GRID_Y`; Y counts up from the bottom row).
public struct ClockRegion: Equatable, Sendable, Identifiable {
    public let name: String
    public let left: Int
    public let top: Int
    public let right: Int
    public let bottom: Int

    public init(name: String, left: Int, top: Int, right: Int, bottom: Int) {
        self.name = name
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var id: String { name }
}

/// One column of the die: its tile types from the bottom row up, as runs (`INT_L` × 25, `HCLK_L` × 1, ...), which is
/// how a whole die fits in a few kilobytes.
public struct DieColumn: Equatable, Sendable {
    public let x: Int
    public let runs: [Run]

    public struct Run: Equatable, Sendable {
        public let type: String
        public let count: Int
        public init(type: String, count: Int) {
            self.type = type
            self.count = count
        }
    }

    public init(x: Int, runs: [Run]) {
        self.x = x
        self.runs = runs
    }

    public var height: Int { runs.reduce(0) { $0 + $1.count } }

    /// The tile types bottom to top.
    public var types: [String] { runs.flatMap { Array(repeating: $0.type, count: $0.count) } }
}

/// A site of the die (a slice, a block RAM, an I/O buffer...) where cells are placed.
public struct DieSite: Equatable, Sendable {
    public let name: String
    /// `SLICEL`, `RAMB36E1`, `IOB33`...
    public let type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

/// A tile that has sites, which is what placement refers to.
public struct DieTile: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let name: String
    public let sites: [DieSite]

    public init(x: Int, y: Int, name: String, sites: [DieSite]) {
        self.x = x
        self.y = y
        self.name = name
        self.sites = sites
    }
}

/// Everything the Package and Device views need to know about a part, fetched once from the build machine's Vivado
/// and kept on the Mac, so the views work with the build machine asleep.
public struct PartData: Equatable, Sendable {
    public var part: String
    public var device: String
    public var package: String
    public var family: String
    public var speed: String
    public var vivado: String
    public var standards: [IOStandardInfo]
    public var banks: [IOBank]
    public var pins: [PackagePin]
    public var columns: [DieColumn]
    public var tiles: [DieTile]
    public var regions: [ClockRegion]

    public init(part: String, device: String = "", package: String = "", family: String = "", speed: String = "",
                vivado: String = "", standards: [IOStandardInfo] = [], banks: [IOBank] = [], pins: [PackagePin] = [],
                columns: [DieColumn] = [], tiles: [DieTile] = [], regions: [ClockRegion] = []) {
        self.part = part
        self.device = device
        self.package = package
        self.family = family
        self.speed = speed
        self.vivado = vivado
        self.standards = standards
        self.banks = banks
        self.pins = pins
        self.columns = columns
        self.tiles = tiles
        self.regions = regions
    }

    // MARK: Lookups

    public func pin(named name: String) -> PackagePin? { pins.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    public func bank(named name: String) -> IOBank? { banks.first { $0.name == name } }

    public func standard(named name: String) -> IOStandardInfo? { standards.first { $0.name == name } }

    /// The package's rows in order: by length, then alphabetically (`A`...`Y`, `AA`, `AB`...), skipping letters the
    /// package doesn't use (JEDEC leaves out I, O, Q, S, X and Z).
    public var rows: [String] {
        Array(Set(pins.map(\.row))).sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
    }

    /// The highest column number.
    public var columnCount: Int { pins.map(\.column).max() ?? 0 }

    /// The I/O standards a port can use on a bank, in Vivado's order.
    public func standards(forBank name: String) -> [String] { bank(named: name)?.standards ?? [] }

    /// The die's size in tiles.
    public var gridWidth: Int { (columns.map(\.x).max() ?? -1) + 1 }
    public var gridHeight: Int { columns.map(\.height).max() ?? 0 }

    /// The tile holding each site, by site name.
    public func siteIndex() -> [String: (tile: DieTile, site: DieSite)] {
        var index: [String: (tile: DieTile, site: DieSite)] = [:]
        for tile in tiles { for site in tile.sites { index[site.name] = (tile, site) } }
        return index
    }

    // MARK: Getting the data

    /// The marker every line of data starts with, so it can be picked out of Vivado's own output.
    public static let marker = "FPGABRIDGE-PART"

    /// The Tcl that writes the part data. It opens the bare part (no design), so it takes a minute or less: most of it
    /// is listing the sites tile by tile. Tie-off sites are left out; they never hold a cell.
    public static func dumpScript(part: String) -> String {
        let m = marker
        return """
        proc fpgabridge_clean {v} { return [string map [list "\\t" " " "\\n" " " "\\r" ""] $v] }
        if {[catch {
            # Checked first: an unknown part otherwise fails later with a message about get_property.
            if {[llength [get_parts -quiet {\(part)}]] == 0} { error \(unknownPartMessage) }
            link_design -part {\(part)} -quiet
            set p [get_parts {\(part)}]
            puts "\(m)\\tVIVADO\\t[version -short]"
            puts "\(m)\\tPART\\t[get_property NAME $p]\\t[get_property DEVICE $p]\\t[get_property PACKAGE $p]\\t[get_property ARCHITECTURE_FULL_NAME $p]\\t[get_property SPEED $p]"
            foreach s [get_io_standards -quiet] {
                set v {}
                foreach k {VCCO_IN VCCO_OUT HAS_VREF VREF IS_DIFFERENTIAL DIRECTION DRIVE_STRENGTH SLEW} { lappend v [fpgabridge_clean [get_property -quiet $k $s]] }
                puts "\(m)\\tSTD\\t[get_property NAME $s]\\t[join $v "\\t"]"
            }
            foreach b [get_iobanks -quiet] {
                puts "\(m)\\tBANK\\t[get_property NAME $b]\\t[get_property -quiet BANK_TYPE $b]\\t[fpgabridge_clean [get_io_standards -quiet -of_objects $b]]"
            }
            foreach pin [get_package_pins -quiet] {
                set v {}
                foreach k {BANK PIN_FUNC DIFF_PAIR_PIN IS_DIFFERENTIAL IS_MASTER IS_CLK_CAPABLE IS_GLOBAL_CLK IS_VREF IS_GENERAL_PURPOSE IS_BONDED} {
                    lappend v [fpgabridge_clean [get_property -quiet $k $pin]]
                }
                puts "\(m)\\tPIN\\t[get_property NAME $pin]\\t[join $v "\\t"]\\t[get_sites -quiet -of_objects $pin]"
            }
            set tiles [get_tiles -quiet]
            set cols [dict create]
            foreach x [get_property GRID_X $tiles] y [get_property GRID_Y $tiles] t [get_property TYPE $tiles] { dict lappend cols $x [list $y $t] }
            foreach x [lsort -integer [dict keys $cols]] {
                set runs {}
                set prev ""
                set n 0
                foreach yt [lsort -integer -index 0 [dict get $cols $x]] {
                    set t [lindex $yt 1]
                    if {$t eq $prev} { incr n } else { if {$n > 0} { lappend runs "$prev*$n" }; set prev $t; set n 1 }
                }
                if {$n > 0} { lappend runs "$prev*$n" }
                puts "\(m)\\tCOLUMN\\t$x\\t[join $runs " "]"
            }
            foreach t [get_tiles -quiet -filter {NUM_SITES > 0}] {
                set ss {}
                foreach s [get_sites -quiet -of_objects $t] {
                    set st [get_property SITE_TYPE $s]
                    if {$st ne "TIEOFF"} { lappend ss "$s:$st" }
                }
                if {[llength $ss] > 0} { puts "\(m)\\tTILE\\t[get_property GRID_X $t]\\t[get_property GRID_Y $t]\\t[get_property NAME $t]\\t[join $ss " "]" }
            }
            foreach c [get_clock_regions -quiet] {
                set tl [get_tiles -quiet [get_property TOP_LEFT_TILE $c]]
                set br [get_tiles -quiet [get_property BOTTOM_RIGHT_TILE $c]]
                puts "\(m)\\tREGION\\t[get_property NAME $c]\\t[get_property GRID_X $tl]\\t[get_property GRID_Y $tl]\\t[get_property GRID_X $br]\\t[get_property GRID_Y $br]"
            }
            close_design -quiet
        } err]} {
            puts "\(m)\\tERROR\\t[fpgabridge_clean $err]"
        }
        """
    }

    /// What the script reports when Vivado has no part by that name.
    static let unknownPartMessage = "FPGABRIDGE_UNKNOWN_PART"

    /// What went wrong, if the script caught an error (an unknown part, say).
    public static func error(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker + "\tERROR\t") {
            return String(line.dropFirst(marker.count + "\tERROR\t".count))
        }
        return nil
    }

    /// Reads the marker lines out of Vivado's output (or a saved copy).
    public static func parse(output: String, part: String = "") -> PartData {
        var data = PartData(part: part)
        func flag(_ s: String) -> Bool { s == "1" }
        func number(_ s: String) -> Double { Double(s) ?? 0 }
        func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init).filter { $0 != "NA" } }
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker + "\t") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
            switch f[1] {
            case "VIVADO": data.vivado = f[2]
            case "PART":
                data.part = f[2]
                data.device = field(3)
                data.package = field(4)
                data.family = field(5)
                data.speed = field(6)
            case "STD":
                data.standards.append(IOStandardInfo(name: f[2], vccoIn: number(field(3)), vccoOut: number(field(4)),
                                                     hasVREF: flag(field(5)), vref: number(field(6)), isDifferential: flag(field(7)),
                                                     directions: words(field(8)), driveStrengths: words(field(9)), slews: words(field(10))))
            case "BANK":
                data.banks.append(IOBank(name: f[2], type: BankType(vivado: field(3)), standards: words(field(4))))
            case "PIN":
                data.pins.append(PackagePin(name: f[2], bank: field(3), function: field(4), diffPair: field(5),
                                            isDifferential: flag(field(6)), isPositive: flag(field(7)), isClockCapable: flag(field(8)),
                                            isGlobalClock: flag(field(9)), isVREF: flag(field(10)), isUserIO: flag(field(11)),
                                            isBonded: flag(field(12)), site: field(13)))
            case "COLUMN":
                guard let x = Int(f[2]) else { continue }
                let runs = field(3).split(separator: " ").compactMap { run -> DieColumn.Run? in
                    guard let star = run.lastIndex(of: "*"), let n = Int(run[run.index(after: star)...]) else { return nil }
                    return DieColumn.Run(type: String(run[..<star]), count: n)
                }
                data.columns.append(DieColumn(x: x, runs: runs))
            case "TILE":
                guard let x = Int(f[2]), let y = Int(field(3)) else { continue }
                let sites = field(5).split(separator: " ").map { entry -> DieSite in
                    let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                    return DieSite(name: parts[0], type: parts.count > 1 ? parts[1] : "")
                }
                data.tiles.append(DieTile(x: x, y: y, name: field(4), sites: sites))
            case "REGION":
                guard let l = Int(field(3)), let t = Int(field(4)), let r = Int(field(5)), let b = Int(field(6)) else { continue }
                data.regions.append(ClockRegion(name: f[2], left: l, top: t, right: r, bottom: b))
            default: break
            }
        }
        data.columns.sort { $0.x < $1.x }
        return data
    }

    /// The marker lines `parse` reads, so the data can be saved and loaded without asking Vivado again.
    public var serialized: String {
        let m = PartData.marker
        func n(_ v: Double) -> String { String(format: "%.3f", v) }
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        var lines = ["\(m)\tVIVADO\t\(vivado)", "\(m)\tPART\t\(part)\t\(device)\t\(package)\t\(family)\t\(speed)"]
        for s in standards {
            lines.append("\(m)\tSTD\t\(s.name)\t\(n(s.vccoIn))\t\(n(s.vccoOut))\t\(b(s.hasVREF))\t\(n(s.vref))\t\(b(s.isDifferential))\t"
                         + "\(s.directions.joined(separator: " "))\t\(s.driveStrengths.joined(separator: " "))\t\(s.slews.joined(separator: " "))")
        }
        for bank in banks { lines.append("\(m)\tBANK\t\(bank.name)\t\(bank.type.vivado)\t\(bank.standards.joined(separator: " "))") }
        for p in pins {
            lines.append([m, "PIN", p.name, p.bank, p.function, p.diffPair, b(p.isDifferential), b(p.isPositive), b(p.isClockCapable),
                          b(p.isGlobalClock), b(p.isVREF), b(p.isUserIO), b(p.isBonded), p.site].joined(separator: "\t"))
        }
        for c in columns { lines.append("\(m)\tCOLUMN\t\(c.x)\t\(c.runs.map { "\($0.type)*\($0.count)" }.joined(separator: " "))") }
        for t in tiles { lines.append("\(m)\tTILE\t\(t.x)\t\(t.y)\t\(t.name)\t\(t.sites.map { "\($0.name):\($0.type)" }.joined(separator: " "))") }
        for r in regions { lines.append("\(m)\tREGION\t\(r.name)\t\(r.left)\t\(r.top)\t\(r.right)\t\(r.bottom)") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Cache

    /// Where part data is kept: `~/Library/Application Support/fpga-bridge/parts`. It describes the silicon, not a
    /// design or a build machine, so one copy per part serves every project.
    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/fpga-bridge/parts")
    }

    public static func cacheURL(part: String, in directory: URL = defaultCacheDirectory) -> URL {
        let safe = String(part.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).txt")
    }

    public func save(in directory: URL = PartData.defaultCacheDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try serialized.write(to: PartData.cacheURL(part: part, in: directory), atomically: true, encoding: .utf8)
    }

    /// The saved data for a part, or nil if it was never fetched (or the file holds no pins).
    public static func cached(part: String, in directory: URL = defaultCacheDirectory) -> PartData? {
        guard let text = try? String(contentsOf: cacheURL(part: part, in: directory), encoding: .utf8) else { return nil }
        let data = parse(output: text, part: part)
        return data.pins.isEmpty ? nil : data
    }
}

/// Fetches part data from the build machine's Vivado, keeping a copy on the Mac.
public struct PartDataService: Sendable {
    public let remote: Remote
    public let cacheDirectory: URL

    public init(remote: Remote, cacheDirectory: URL = PartData.defaultCacheDirectory) {
        self.remote = remote
        self.cacheDirectory = cacheDirectory
    }

    /// The data for `part`: the saved copy if there is one (unless `refresh`), else from Vivado, which is then saved.
    public func partData(part: String, refresh: Bool = false, log: (@Sendable (String) -> Void)? = nil) throws -> PartData {
        if !refresh, let cached = PartData.cached(part: part, in: cacheDirectory) { return cached }
        let box = OutputBox()
        let status = try remote.runTcl(script: PartData.dumpScript(part: part)) { chunk in
            box.append(chunk)
            log?(chunk)
        }
        let output = box.value
        if let error = PartData.error(in: output) {
            throw error == PartData.unknownPartMessage ? PartDataError.unknownPart(part) : PartDataError.vivado(error)
        }
        let data = PartData.parse(output: output, part: part)
        guard !data.pins.isEmpty else {
            throw status == 0 ? PartDataError.noPins(part) : PartDataError.vivadoFailed(status, String(output.suffix(600)))
        }
        try data.save(in: cacheDirectory)
        return data
    }
}

public enum PartDataError: DescribedError, Equatable {
    case vivadoFailed(Int32, String)
    case vivado(String)
    case noPins(String)
    case unknownPart(String)

    public var description: String {
        switch self {
        case .unknownPart(let part): "Vivado on the build machine has no part named \(part). Check the part number, and that its device family is installed there."
        case .vivadoFailed(let status, let tail): "Vivado exited with status \(status).\n\(tail)"
        case .vivado(let message): "Vivado said: \(message)"
        case .noPins(let part): "Vivado listed no package pins for \(part). Is the part number right, and is that device family installed?"
        }
    }
}
