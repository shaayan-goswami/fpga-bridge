import FPGABridgeCore
import Foundation
import SwiftUI

/// What the Waveform tab shows: a parsed waveform, which signals are on screen, the visible time window and the cursor.
@MainActor
final class WaveformModel: ObservableObject {
    @Published private(set) var waveform: Waveform?
    @Published private(set) var source: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    /// Signal ids in the order they are drawn.
    @Published private(set) var shown: [Int] = []
    @Published var selected: Int?
    @Published var defaultRadix = WaveRadix.hex
    @Published private(set) var radixOverrides: [Int: WaveRadix] = [:]

    /// The visible window, in ticks of the waveform's timescale.
    @Published private(set) var viewStart = 0.0
    @Published private(set) var viewEnd = 1.0
    @Published private(set) var cursor: UInt64?

    /// Signals shown when a waveform opens: the testbench's own, plus the first design instance under it.
    static let defaultLimit = 40

    /// Loads a waveform file, off the main thread, and fits it to the window.
    func load(_ url: URL) async {
        isLoading = true
        loadError = nil
        let result = await Task.detached { Result { try Waveform.load(from: url) } }.value
        isLoading = false
        switch result {
        case .success(let loaded):
            adopt(loaded, from: url)
        case .failure(let error):
            waveform = nil
            source = url
            loadError = error.userMessage
        }
    }

    /// Shows an already parsed waveform (the tests use this).
    func adopt(_ loaded: Waveform, from url: URL?) {
        waveform = loaded
        source = url
        loadError = nil
        shown = Self.defaultSignals(in: loaded)
        radixOverrides = [:]
        selected = nil
        cursor = nil
        fit()
    }

    func clear() {
        waveform = nil
        source = nil
        loadError = nil
        shown = []
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

    func isShown(_ id: Int) -> Bool { shown.contains(id) }

    func show(_ id: Int) { if !shown.contains(id) { shown.append(id) } }

    func hide(_ id: Int) {
        shown.removeAll { $0 == id }
        if selected == id { selected = nil }
    }

    func toggle(_ id: Int) { isShown(id) ? hide(id) : show(id) }

    func move(from: IndexSet, to: Int) { shown.move(fromOffsets: from, toOffset: to) }

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
