import FPGABridgeCore
import Foundation

// MARK: Where part data comes from

/// Where the Package and Device views get a part's pins and die: the copy saved on this Mac, or the build machine's
/// Vivado once per part. In Demo Mode, made-up data.
protocol PartDataBackend: AnyObject, Sendable {
    var isDemo: Bool { get }
    /// Whether `fetch` can reach Vivado.
    var canFetch: Bool { get }
    /// The saved data, if this Mac has it. Reads a file, so it isn't free; `ChipViews` keeps what it read.
    func cached(part: String) -> PartData?
    func fetch(part: String) async throws -> PartData
}

final class LivePartDataBackend: PartDataBackend, Sendable {
    let isDemo = false
    let canFetch = true
    private let service: PartDataService

    init(config: BridgeConfig, cacheDirectory: URL = PartData.defaultCacheDirectory) {
        service = PartDataService(remote: Remote(config: config), cacheDirectory: cacheDirectory)
    }

    func cached(part: String) -> PartData? { PartData.cached(part: part, in: service.cacheDirectory) }

    func fetch(part: String) async throws -> PartData {
        let service = service
        return try await Task.detached { try service.partData(part: part, refresh: true) }.value
    }
}

/// No build machine: the views still work for any part fetched before.
final class LocalPartDataBackend: PartDataBackend, Sendable {
    let isDemo = false
    let canFetch = false
    let cacheDirectory: URL

    init(cacheDirectory: URL = PartData.defaultCacheDirectory) { self.cacheDirectory = cacheDirectory }

    func cached(part: String) -> PartData? { PartData.cached(part: part, in: cacheDirectory) }
    func fetch(part: String) async throws -> PartData { throw NoBuildMachine() }
}

/// A made-up package and die, so the views can be explored without a build machine. Not the real pinout, and the
/// app says so.
final class DemoPartDataBackend: PartDataBackend, Sendable {
    let isDemo = true
    let canFetch = true

    func cached(part: String) -> PartData? { DemoPartData.make(part: part) }
    func fetch(part: String) async throws -> PartData { DemoPartData.make(part: part) }
}

enum DemoPartData {
    static func make(part: String) -> PartData {
        let rows = ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N", "P", "R", "T", "U", "V", "W"]
        var pins: [PackagePin] = []
        for (r, row) in rows.enumerated() {
            for column in 1...19 {
                let ring = min(r, column - 1, 18 - r, 19 - column)
                let name = "\(row)\(column)"
                let bank = r >= 9 ? (column >= 10 ? "14" : "34") : (column >= 10 ? "16" : "35")
                if ring < 5 && (r + 2 * column) % 9 != 4 {
                    let positive = column % 2 == 1 && column < 19
                    let pair = positive ? "\(row)\(column + 1)" : (column % 2 == 0 ? "\(row)\(column - 1)" : "")
                    pins.append(PackagePin(name: name, bank: bank, function: "IO_\(positive ? "P" : "N")_\(bank)", diffPair: pair,
                                           isDifferential: !pair.isEmpty, isPositive: positive, isClockCapable: column == 5 || column == 14,
                                           isUserIO: true))
                } else if ring < 5 {
                    pins.append(PackagePin(name: name, bank: bank, function: "VCCO_\(bank)"))
                } else {
                    pins.append(PackagePin(name: name, bank: "", function: (r + column) % 3 == 0 ? "VCCINT" : "GND", isBonded: false))
                }
            }
        }
        let standards = [IOStandardInfo(name: "LVCMOS33", vccoIn: 3.3, vccoOut: 3.3), IOStandardInfo(name: "LVTTL", vccoIn: 3.3, vccoOut: 3.3),
                         IOStandardInfo(name: "LVCMOS25", vccoIn: 2.5, vccoOut: 2.5), IOStandardInfo(name: "LVCMOS18", vccoIn: 1.8, vccoOut: 1.8),
                         IOStandardInfo(name: "LVCMOS15", vccoIn: 1.5, vccoOut: 1.5), IOStandardInfo(name: "LVCMOS12", vccoIn: 1.2, vccoOut: 1.2),
                         IOStandardInfo(name: "SSTL15", vccoIn: 0, vccoOut: 1.5, hasVREF: true, vref: 0.75),
                         IOStandardInfo(name: "LVDS_25", vccoIn: 0, vccoOut: 2.5, isDifferential: true)]
        let banks = ["14", "16", "34", "35"].map { IOBank(name: $0, type: .highRange, standards: standards.map(\.name)) }
        // Columns of I/O, interconnect and CLBs, with a block RAM and a DSP column on each side of the clock spine.
        let pattern = ["LIOB33", "LIOI3", "INT_L", "CLBLL_L", "INT_R", "CLBLM_R", "INT_L", "BRAM_L", "INT_R", "CLBLM_R", "INT_L", "DSP_L",
                       "CLK_BUFG_BOT_R", "DSP_R", "INT_R", "CLBLM_L", "INT_L", "BRAM_R", "INT_R", "CLBLL_L", "INT_L", "RIOI3", "RIOB33"]
        let columns = pattern.enumerated().map { x, type -> DieColumn in
            let tall = ["BRAM_L", "BRAM_R", "DSP_L", "DSP_R"].contains(type) ? 5 : (type.hasSuffix("IOB33") ? 2 : 1)
            var runs: [DieColumn.Run] = []
            for _ in 0..<(60 / tall) {
                runs.append(DieColumn.Run(type: type, count: 1))
                if tall > 1 { runs.append(DieColumn.Run(type: "NULL", count: tall - 1)) }
            }
            return DieColumn(x: x, runs: runs)
        }
        let regions = [ClockRegion(name: "X0Y0", left: 0, top: 29, right: 11, bottom: 0), ClockRegion(name: "X1Y0", left: 13, top: 29, right: 22, bottom: 0),
                       ClockRegion(name: "X0Y1", left: 0, top: 59, right: 11, bottom: 30), ClockRegion(name: "X1Y1", left: 13, top: 59, right: 22, bottom: 30)]
        return PartData(part: part, device: String(part.prefix(7)), package: "demo", family: "Artix-7", speed: "-1",
                        vivado: "demo data, not the real pinout", standards: standards, banks: banks, pins: pins, columns: columns, regions: regions)
    }
}

// MARK: State

/// What the Package and Device views share: the part data (loaded once per part), the pin chosen in the Package view
/// when it has no port, and why the last placement was refused.
@MainActor
final class ChipViews: ObservableObject {
    enum Load: Equatable { case idle, loading, failed(String) }

    let backend: PartDataBackend
    @Published private(set) var loads: [String: Load] = [:]
    /// Bumped when part data arrives, so views that read it draw again.
    @Published private(set) var generation = 0
    /// A package pin selected in the Package view. Pins aren't design objects, so this is separate from the design
    /// selection; selecting a port clears it.
    @Published var selectedPin: String?
    /// Why the last drag or edit didn't place a port, shown until the next one.
    @Published var notice: String?

    // Read on demand from view bodies, so kept out of @Published.
    private var parts: [String: PartData] = [:]
    private var missing: Set<String> = []
    private var dies: [String: DieLayout] = [:]
    private var clockPorts: [String: Set<String>] = [:]
    private var placement: [String: [String: [String]]] = [:]

    init(backend: PartDataBackend) { self.backend = backend }

    /// The backend that goes with the app's: Vivado through the same build machine, the saved copies without one.
    static func backend(for app: Backend) -> PartDataBackend {
        let directory = DebugHooks.partDataDirectory ?? PartData.defaultCacheDirectory
        if app.isDemo { return DemoPartDataBackend() }
        if let live = app as? LiveBackend { return LivePartDataBackend(config: live.config, cacheDirectory: directory) }
        return LocalPartDataBackend(cacheDirectory: directory)
    }

    func data(for part: String) -> PartData? {
        if let data = parts[part] { return data }
        guard !part.isEmpty, !missing.contains(part) else { return nil }
        if let data = backend.cached(part: part) {
            parts[part] = data
            return data
        }
        missing.insert(part)
        return nil
    }

    func load(of part: String) -> Load { loads[part] ?? .idle }

    /// Asks Vivado for the part's data (about a minute), replacing any saved copy.
    func fetch(_ part: String) {
        guard !part.isEmpty, load(of: part) != .loading else { return }
        loads[part] = .loading
        Task {
            do {
                let data = try await backend.fetch(part: part)
                parts[part] = data
                missing.remove(part)
                dies[part] = nil
                loads[part] = .idle
                generation += 1
            } catch {
                loads[part] = .failed(error.userMessage)
            }
        }
    }

    func die(for data: PartData) -> DieLayout {
        if let die = dies[data.part] { return die }
        let die = DieLayout(part: data)
        dies[data.part] = die
        return die
    }

    private static func key(_ design: DesignSnapshot) -> String {
        "\(design.stage.rawValue)|\(design.info.design)|\(design.cells.count)|\(design.nets.count)|\(design.propertyTable.count)"
    }

    /// The input ports that carry a clock: they reach a clock pin, or a global clock buffer, directly or through
    /// their input buffer.
    func clocks(in design: DesignSnapshot) -> Set<String> {
        let key = Self.key(design)
        if let found = clockPorts[key] { return found }
        func reachesClock(_ net: String, depth: Int) -> Bool {
            for end in design.flatConnectivity(of: net) where !end.isPort {
                guard let pin = design.pins[end.name] else { continue }
                if pin.isClock { return true }
                let type = design.cell(named: pin.cellName)?.type ?? ""
                if type.hasPrefix("BUFG") || type.hasPrefix("BUFH") || type.hasPrefix("MMCM") || type.hasPrefix("PLLE") { return true }
                if depth == 0, type.hasPrefix("IBUF"), let out = design.net(ofPin: pin.cellName + "/O"), reachesClock(out, depth: 1) { return true }
            }
            return false
        }
        let found = Set(design.ports.filter { $0.direction == "IN" }.filter { port in
            design.net(ofPort: port.name).map { reachesClock($0, depth: 0) } ?? false
        }.map(\.name))
        clockPorts[key] = found
        return found
    }

    /// The cells placed on each site (from their `LOC`), for the Device view.
    func cellsBySite(in design: DesignSnapshot) -> [String: [String]] {
        let key = Self.key(design)
        if let found = placement[key] { return found }
        var found: [String: [String]] = [:]
        for (key, properties) in design.propertyTable where key.hasPrefix("cell:") {
            if let loc = properties.first(where: { $0.name == "LOC" })?.value, !loc.isEmpty {
                found[loc, default: []].append(String(key.dropFirst("cell:".count)))
            }
        }
        placement[key] = found
        return found
    }
}

// MARK: Tabs

extension WorkspaceTab {
    /// The design a Package or Device window belongs to.
    var chipStage: DesignStage? {
        switch self {
        case .package(let stage), .device(let stage): stage
        default: nil
        }
    }
}

// MARK: I/O planning

extension AppModel {
    /// Vivado offers the Package window for every open design, and the Device window once it is synthesized (the
    /// elaborated design isn't mapped to the device yet).
    static func hasDeviceView(_ stage: DesignStage) -> Bool { stage != .rtl }

    func openPackage(_ stage: DesignStage? = nil) {
        guard let stage = stage ?? activeDesign, designs[stage] != nil else { return }
        open(.package(stage))
    }

    func openDevice(_ stage: DesignStage? = nil) {
        guard let stage = stage ?? activeDesign, designs[stage] != nil, Self.hasDeviceView(stage) else { return }
        open(.device(stage))
    }

    /// Closing a design closes its Package and Device windows too.
    func closeChipTabs(of stage: DesignStage) {
        for tab in [WorkspaceTab.package(stage), .device(stage)] {
            guard let index = openTabs.firstIndex(of: tab) else { continue }
            openTabs.remove(at: index)
            if selectedTab == tab { selectedTab = openTabs.last ?? .summary }
        }
    }

    func chipTitle(_ tab: WorkspaceTab) -> String {
        if case .device = tab { return "Device" }
        return "Package"
    }

    func chipSymbol(_ tab: WorkspaceTab) -> String {
        if case .device = tab { return "cpu" }
        return "circle.grid.3x3"
    }

    /// The part an open design is for.
    func part(of stage: DesignStage) -> String {
        let fromBuild = designs[stage]?.info.part ?? ""
        return fromBuild.isEmpty ? (project?.part ?? "") : fromBuild
    }

    func partData(of stage: DesignStage) -> PartData? { chipViews.data(for: part(of: stage)) }

    /// The project's constraint files with any unsaved edits, in the order Vivado reads them.
    func constraintFiles() -> [XDCFile] {
        guard let project, let projectURL else { return [] }
        return ((try? project.resolveConstraints(in: projectURL)) ?? []).map { XDCFile(path: $0, text: editedText(for: $0)) }
    }

    /// The design's ports as I/O planning sees them: the pin and standard the constraints give now (which may have
    /// changed since the build), else what the build had. Once the constraints assign any pins, a port they don't
    /// mention has no pin, so taking a pin away shows as unplaced straight away.
    func plannedPorts(_ stage: DesignStage) -> [PlannedPort] {
        guard let design = designs[stage] else { return [] }
        let files = constraintFiles()
        let constraints = XDCPins.constraints(for: design.ports.map(\.name), in: files)
        let pinsInXDC = XDCPins.assignsPackagePins(files)
        let clocks = chipViews.clocks(in: design)
        return design.ports.map { port in
            let c = constraints[port.name]
            return PlannedPort(name: port.name, direction: port.direction,
                               pin: c?.packagePin ?? (pinsInXDC ? "" : port.packagePin),
                               standard: c?.ioStandard ?? port.ioStandard, isClock: clocks.contains(port.name))
        }
    }

    /// What the rule checks find, or nothing when the part data isn't on this Mac.
    func pinIssues(_ stage: DesignStage, ports: [PlannedPort]? = nil) -> [PinIssue] {
        guard let part = partData(of: stage) else { return [] }
        return PinRules.check(ports ?? plannedPorts(stage), part: part)
    }

    /// Places a port on a package pin, or unplaces it with nil, by writing `PACKAGE_PIN` into the constraints. Refuses
    /// (and says why in `chipViews.notice`) when the rule checks find a problem with the new place. Returns whether
    /// it was placed.
    @discardableResult
    func placePort(_ port: String, on pin: String?, in stage: DesignStage) -> Bool {
        let ports = plannedPorts(stage)
        guard let current = ports.first(where: { $0.name == port }) else { return false }
        let target = pin?.trimmingCharacters(in: .whitespaces).uppercased()
        if let target, !target.isEmpty {
            if current.pin.caseInsensitiveCompare(target) == .orderedSame { return true }
            if let part = partData(of: stage),
               let problem = PinRules.placementProblem(port: current, pin: target, others: ports, part: part) {
                chipViews.notice = "Can't place \(port) on \(target): \(problem)"
                return false
            }
            chipViews.notice = nil
            return writePortConstraint(XDCPins.packagePin, of: port, to: target)
        }
        chipViews.notice = nil
        return writePortConstraint(XDCPins.packagePin, of: port, to: nil)
    }

    /// Sets the I/O standard of ports. Unlike a placement this isn't refused: as in Vivado, a standard that clashes with
    /// the bank shows up in the rule checks instead.
    func setIOStandard(_ standard: String, of ports: [String], in stage: DesignStage) {
        guard !standard.isEmpty else { return }
        for port in ports where plannedPorts(stage).first(where: { $0.name == port })?.standard != standard {
            writePortConstraint(XDCPins.ioStandard, of: port, to: standard)
        }
    }

    /// Writes one property into the constraints: the line that sets it is edited, else one is added to the first
    /// constraints file (a new `<top>.xdc` if the project has none). A file open with unsaved edits gets the change in
    /// its editor, to be saved with them; otherwise it is saved at once, which makes the runs out of date as saving
    /// any constraint does.
    @discardableResult
    func writePortConstraint(_ property: String, of port: String, to value: String?) -> Bool {
        guard let project else { return false }
        var files = constraintFiles()
        if files.isEmpty {
            guard value != nil else { return true }
            let tab = selectedTab
            createSourceFile(named: project.top + ".xdc", in: .constraints)
            open(tab)
            files = constraintFiles()
            guard !files.isEmpty else { return false }
        }
        let edited = XDCPins.set(property, of: port, to: value, in: files)
        for (old, new) in zip(files, edited) where old.text != new.text {
            let hadEdits = isDirty(new.path)
            updateDraft(new.text, for: new.path)
            if !hadEdits, !saveFile(new.path) { return false }
        }
        echoTcl("set_property \(property) \(value ?? "{}") [get_ports \(XDCPins.quoted(port))]")
        return true
    }
}
