import FPGABridgeCore
import Foundation
import SwiftUI

/// One row of the Waveform tab: a signal, or a divider (a named line that groups the signals under it).
enum WaveRow: Hashable, Identifiable {
    case signal(Int)
    case divider(UUID)

    var id: String {
        switch self {
        case .signal(let id): "s\(id)"
        case .divider(let id): "d\(id.uuidString)"
        }
    }
}

/// What the Waveform tab shows: a parsed waveform, which signals are on screen, the visible time window, the cursor
/// and the markers. The layout (rows, radixes, zoom, markers) is saved next to the waveform for its testbench and
/// put back the next time that testbench runs.
@MainActor
final class WaveformModel: ObservableObject {
    @Published private(set) var waveform: Waveform?
    @Published private(set) var source: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    /// Signals and dividers in the order they are drawn.
    @Published private(set) var rows: [WaveRow] = [] { didSet { layoutChanged() } }
    /// Divider names, by id.
    @Published private(set) var dividers: [UUID: String] = [:] { didSet { layoutChanged() } }
    /// Signal ids in the order they are drawn.
    var shown: [Int] { rows.compactMap { if case .signal(let id) = $0 { id } else { nil } } }
    @Published var selected: Int?
    @Published var defaultRadix = WaveRadix.hex { didSet { layoutChanged() } }
    @Published private(set) var radixOverrides: [Int: WaveRadix] = [:] { didSet { layoutChanged() } }

    /// The visible window, in ticks of the waveform's timescale.
    @Published private(set) var viewStart = 0.0 { didSet { layoutChanged() } }
    @Published private(set) var viewEnd = 1.0 { didSet { layoutChanged() } }
    @Published private(set) var cursor: UInt64?

    /// Markers, in the order they were added.
    @Published private(set) var markers: [WaveMarker] = [] { didSet { layoutChanged() } }
    /// The markers picked in the ruler, at most two, for the time between them.
    @Published private(set) var selectedMarkers: [UUID] = []

    /// Where this testbench's layout is saved. Nil for a waveform opened on its own, which saves nothing.
    @Published private(set) var layoutURL: URL?
    /// Said once after restoring a layout, e.g. which signals no longer exist.
    @Published private(set) var layoutNote: String?
    /// While a layout is being put in place, its own changes mustn't save it again.
    private var restoring = false
    private var saveTask: Task<Void, Never>?
    /// How long after the last change the layout is written. Zooming fires many changes; one write is enough.
    var saveDelay: UInt64 = 400_000_000

    /// Signals shown when a waveform opens: the testbench's own, plus the first design instance under it.
    static let defaultLimit = 40

    /// Loads a waveform file, off the main thread, and fits it to the window. With `layout`, the saved layout there
    /// (if any) is put back, and changes are saved to it.
    func load(_ url: URL, layout: URL? = nil) async {
        isLoading = true
        loadError = nil
        let result = await Task.detached { Result { try Waveform.load(from: url) } }.value
        isLoading = false
        switch result {
        case .success(let loaded):
            adopt(loaded, from: url, layout: layout)
        case .failure(let error):
            waveform = nil
            source = url
            loadError = error.userMessage
        }
    }

    /// Shows an already parsed waveform (the tests use this).
    func adopt(_ loaded: Waveform, from url: URL?, layout: URL? = nil) {
        saveTask?.cancel()
        restoring = true
        defer { restoring = false }
        waveform = loaded
        source = url
        loadError = nil
        layoutURL = layout
        layoutNote = nil
        rows = Self.defaultSignals(in: loaded).map(WaveRow.signal)
        dividers = [:]
        radixOverrides = [:]
        markers = []
        selectedMarkers = []
        selected = nil
        cursor = nil
        fit()
        if let layout, FileManager.default.fileExists(atPath: layout.path) {
            do { apply(try WaveLayout.load(from: layout)) }
            catch { layoutNote = "The saved layout couldn't be read (\(error.userMessage)), so the default one is shown." }
        }
    }

    func clear() {
        saveTask?.cancel()
        restoring = true
        defer { restoring = false }
        waveform = nil
        source = nil
        loadError = nil
        layoutURL = nil
        layoutNote = nil
        rows = []
        dividers = [:]
        markers = []
        selectedMarkers = []
        cursor = nil
    }

    static func defaultSignals(in waveform: Waveform) -> [Int] {
        func drawable(_ id: Int) -> Bool { !["integer", "parameter", "real", "realtime", "event", "time"].contains(waveform.signals[id].kind) }
        guard let top = waveform.scopes.first else { return Array(waveform.signals.indices.prefix(defaultLimit)) }
        var ids = top.signals.filter(drawable)
        if let instance = top.children.first {
            // The same net seen from the instance (clk, led, ...) is already there under the testbench.
            let have = Set(ids.map { waveform.signals[$0].name })
            ids += instance.signals.filter { drawable($0) && !have.contains(waveform.signals[$0].name) }
        }
        return Array(ids.prefix(defaultLimit))
    }

    // MARK: Signals

    func isShown(_ id: Int) -> Bool { rows.contains(.signal(id)) }

    func show(_ id: Int) { if !isShown(id) { rows.append(.signal(id)) } }

    func hide(_ id: Int) {
        rows.removeAll { $0 == .signal(id) }
        if selected == id { selected = nil }
    }

    func toggle(_ id: Int) { isShown(id) ? hide(id) : show(id) }

    func move(from: IndexSet, to: Int) { rows.move(fromOffsets: from, toOffset: to) }

    /// Moves a row up (-1) or down (+1) one place.
    func move(_ row: WaveRow, by offset: Int) {
        guard let index = rows.firstIndex(of: row), rows.indices.contains(index + offset) else { return }
        rows.swapAt(index, index + offset)
    }

    // MARK: Dividers

    /// Adds a divider above the selected signal, or at the end. Returns its id.
    @discardableResult
    func addDivider(named name: String = "Divider") -> UUID {
        let id = UUID()
        dividers[id] = name
        if let selected, let index = rows.firstIndex(of: .signal(selected)) {
            rows.insert(.divider(id), at: index)
        } else {
            rows.append(.divider(id))
        }
        return id
    }

    func renameDivider(_ id: UUID, to name: String) {
        guard dividers[id] != nil else { return }
        dividers[id] = name
    }

    func removeDivider(_ id: UUID) {
        rows.removeAll { $0 == .divider(id) }
        dividers[id] = nil
    }

    func dividerName(_ id: UUID) -> String { dividers[id] ?? "" }

    func radix(for id: Int) -> WaveRadix { radixOverrides[id] ?? defaultRadix }

    func setRadix(_ radix: WaveRadix?, for id: Int) { radixOverrides[id] = radix }

    // MARK: Time window

    var endTime: Double { Double(waveform?.endTime ?? 1) }
    var span: Double { viewEnd - viewStart }

    /// The whole run, with a little room at the end.
    func fit() {
        viewStart = 0
        viewEnd = max(endTime * 1.02, 10)
    }

    /// Zooms by `factor` (> 1 zooms in), keeping the tick under `anchor` (0...1 across the window) where it is.
    func zoom(by factor: Double, anchor: Double = 0.5) {
        guard factor > 0, waveform != nil else { return }
        let focus = viewStart + anchor * span
        let newSpan = min(max(span / factor, 10), max(endTime * 4, 100))
        viewStart = focus - anchor * newSpan
        viewEnd = viewStart + newSpan
        keepInRange()
    }

    /// Moves the window by `ticks`.
    func pan(byTicks ticks: Double) {
        guard waveform != nil else { return }
        viewStart += ticks
        viewEnd += ticks
        keepInRange()
    }

    /// Doesn't let the window drift off either end of the run.
    private func keepInRange() {
        let limit = max(endTime * 1.02, 10)
        if viewStart < 0 { viewEnd -= viewStart; viewStart = 0 }
        if viewEnd > limit && span <= limit { viewStart -= viewEnd - limit; viewEnd = limit }
        if viewStart < 0 { viewStart = 0 }
    }

    // MARK: Markers

    /// Vivado's Add Marker: a marker at the cursor (or the middle of the view when there is none), named M1, M2, ….
    @discardableResult
    func addMarker() -> WaveMarker? {
        guard waveform != nil else { return nil }
        let time = cursor ?? UInt64(max(0, min((viewStart + span / 2).rounded(), endTime)))
        let used = Set(markers.map(\.name))
        let name = (1...).lazy.map { "M\($0)" }.first { !used.contains($0) }!
        let marker = WaveMarker(name: name, time: time)
        markers.append(marker)
        return marker
    }

    func moveMarker(_ id: UUID, toTick tick: Double) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].time = UInt64(max(0, min(tick.rounded(), endTime)))
    }

    func renameMarker(_ id: UUID, to name: String) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { markers[index].name = trimmed }
    }

    func deleteMarker(_ id: UUID) {
        markers.removeAll { $0.id == id }
        selectedMarkers.removeAll { $0 == id }
    }

    func deleteAllMarkers() {
        markers = []
        selectedMarkers = []
    }

    /// Picks a marker; picking a third forgets the oldest of the two.
    func selectMarker(_ id: UUID) {
        selectedMarkers.removeAll { $0 == id }
        selectedMarkers.append(id)
        if selectedMarkers.count > 2 { selectedMarkers.removeFirst() }
    }

    func marker(_ id: UUID) -> WaveMarker? { markers.first { $0.id == id } }

    /// The marker closest to the cursor.
    var nearestMarker: WaveMarker? {
        guard let cursor else { return nil }
        return markers.min { a, b in a.time.distance(to: cursor).magnitude < b.time.distance(to: cursor).magnitude }
    }

    /// The marker within `ticks` of a tick, if any: what a click in the ruler grabs.
    func marker(near tick: Double, within ticks: Double) -> WaveMarker? {
        markers.filter { abs(Double($0.time) - tick) <= ticks }.min { abs(Double($0.time) - tick) < abs(Double($1.time) - tick) }
    }

    /// A signed time difference, as the status line shows it: "+12 ns".
    func delta(from a: UInt64, to b: UInt64) -> String {
        let difference = Double(b) - Double(a)
        return (difference < 0 ? "−" : "+") + label(forTick: abs(difference))
    }

    /// The status line under the waveform: the cursor, the time from the nearest marker, and between two picked
    /// markers.
    var measurements: [String] {
        var parts: [String] = []
        if let cursor {
            parts.append("Cursor \(label(forTick: Double(cursor)))")
            if let nearest = nearestMarker { parts.append("\(nearest.name) → cursor \(delta(from: nearest.time, to: cursor))") }
        }
        if selectedMarkers.count == 2, let a = marker(selectedMarkers[0]), let b = marker(selectedMarkers[1]) {
            parts.append("\(a.name) → \(b.name) \(delta(from: a.time, to: b.time))")
        }
        return parts
    }

    // MARK: Layout

    /// The layout as it is now.
    var layout: WaveLayout {
        let signals = waveform?.signals ?? []
        let saved: [WaveLayout.Row] = rows.compactMap { row in
            switch row {
            case .signal(let id): signals.indices.contains(id) ? .signal(signals[id].path) : nil
            case .divider(let id): .divider(dividers[id] ?? "")
            }
        }
        var radixes: [String: String] = [:]
        for (id, radix) in radixOverrides where signals.indices.contains(id) { radixes[signals[id].path] = radix.rawValue }
        return WaveLayout(rows: saved, radixes: radixes, defaultRadix: defaultRadix, viewStart: viewStart, viewEnd: viewEnd,
                          markers: markers)
    }

    /// Puts a saved layout in place. Signals that no longer exist are dropped, and `layoutNote` says which.
    func apply(_ layout: WaveLayout) {
        guard let waveform else { return }
        let wasRestoring = restoring
        restoring = true
        defer { restoring = wasRestoring }
        let resolved = layout.resolve(in: waveform)
        var names: [UUID: String] = [:]
        rows = resolved.rows.map { row in
            switch row {
            case .signal(let id): return .signal(id)
            case .divider(let name):
                let id = UUID()
                names[id] = name
                return .divider(id)
            }
        }
        dividers = names
        radixOverrides = resolved.radixes
        defaultRadix = WaveRadix(rawValue: layout.defaultRadix) ?? .hex
        markers = layout.markers.map { var m = $0; m.time = min(m.time, waveform.endTime); return m }
        selectedMarkers = []
        if layout.viewEnd > layout.viewStart {
            viewStart = layout.viewStart
            viewEnd = layout.viewEnd
            keepInRange()
        }
        if !resolved.missing.isEmpty {
            let list = resolved.missing.prefix(5).joined(separator: ", ") + (resolved.missing.count > 5 ? ", …" : "")
            layoutNote = "\(resolved.missing.count == 1 ? "1 saved signal is" : "\(resolved.missing.count) saved signals are") no longer in this simulation and \(resolved.missing.count == 1 ? "was" : "were") dropped: \(list)"
        }
    }

    /// Writes the layout now (Save Waveform Configuration, and the tests).
    func saveLayout(to url: URL? = nil) throws {
        saveTask?.cancel()
        guard let target = url ?? layoutURL, waveform != nil else { return }
        try layout.save(to: target)
    }

    /// Opens a saved layout (Open Waveform Configuration) and keeps saving to the testbench's own file.
    func openLayout(_ url: URL) throws {
        let loaded = try WaveLayout.load(from: url)
        layoutNote = nil
        apply(loaded)
        layoutChanged()
    }

    /// Back to the signals a new waveform starts with, no markers, fitted.
    func resetLayout() {
        guard let waveform else { return }
        rows = Self.defaultSignals(in: waveform).map(WaveRow.signal)
        dividers = [:]
        radixOverrides = [:]
        defaultRadix = .hex
        markers = []
        selectedMarkers = []
        layoutNote = nil
        fit()
    }

    private func layoutChanged() {
        guard !restoring, layoutURL != nil, waveform != nil else { return }
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            try? self.saveLayout()
        }
    }

    // MARK: Cursor

    func setCursor(tick: Double) {
        guard waveform != nil else { return }
        cursor = UInt64(max(0, min(tick.rounded(), endTime)))
    }

    func moveCursorToNextChange(forward: Bool) {
        guard let waveform, let id = selected ?? shown.first else { return }
        let times = waveform.signals[id].times
        let now = cursor ?? 0
        let target = forward ? times.first { $0 > now } : times.last { $0 < now }
        if let target {
            cursor = target
            if Double(target) < viewStart || Double(target) > viewEnd { pan(byTicks: Double(target) - (viewStart + span / 2)) }
        }
    }

    /// The value of a signal under the cursor, formatted for display. Nil if there is no cursor.
    func displayValue(of id: Int) -> String? {
        guard let waveform, let cursor, let bits = waveform.value(of: id, at: cursor) else { return nil }
        return Waveform.format(bits, radix: radix(for: id))
    }

    /// How a time reads on screen.
    func label(forTick tick: Double) -> String { waveform?.formatTime(tick) ?? "" }
}
