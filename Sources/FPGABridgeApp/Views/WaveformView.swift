import FPGABridgeCore
import SwiftUI

/// The Waveform tab: signal names with their values at the cursor on the left, the traces on the right.
struct WaveformView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var wave: WaveformModel
    @State private var showPicker = false

    static let rowHeight: CGFloat = 30
    static let namesWidth: CGFloat = 250
    static let rulerHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if wave.isLoading {
                ProgressView("Reading the waveform…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = wave.loadError {
                message("exclamationmark.triangle", "Couldn't open the waveform", error)
            } else if wave.waveform == nil {
                message("waveform.path.ecg", "No waveform yet", "Run Simulation, and its waveform appears here.")
            } else {
                viewer
            }
        }
        .background(Theme.surface)
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(wave.source?.lastPathComponent ?? "Waveform").font(.callout.weight(.semibold))
                if let w = wave.waveform {
                    Text("\(w.formatTime(Double(w.endTime))) simulated · \(w.signals.count) signals · timescale \(Int(w.timescaleValue)) \(w.timescaleUnit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if wave.waveform != nil {
                Button { wave.moveCursorToNextChange(forward: false) } label: { Image(systemName: "backward.end") }
                    .help("Previous change of the selected signal")
                Button { wave.moveCursorToNextChange(forward: true) } label: { Image(systemName: "forward.end") }
                    .help("Next change of the selected signal")
                Divider().frame(height: 16)
                Button { wave.zoom(by: 1 / 1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { wave.zoom(by: 1.6) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
                Button { wave.fit() } label: { Image(systemName: "arrow.left.and.right") }
                    .help("Zoom to fit the whole run")
                Divider().frame(height: 16)
                Menu {
                    Picker("Radix", selection: $wave.defaultRadix) {
                        ForEach(WaveRadix.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Radix", systemImage: "number")
                }
                .fixedSize()
                .help("How buses are shown")
                Button { showPicker.toggle() } label: { Label("Signals", systemImage: "plus") }
                    .popover(isPresented: $showPicker, arrowEdge: .bottom) { SignalPicker() }
                    .help("Choose the signals to show")
                if let url = wave.source {
                    Button("Open in Surfer") { model.openWaveform(url) }
                        .help("Open this file in Surfer or GTKWave")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    // MARK: Viewer

    private var viewer: some View {
        GeometryReader { geo in
            let traceWidth = max(100, geo.size.width - Self.namesWidth - 1)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .frame(width: Self.namesWidth, alignment: .leading)
                    Divider()
                    Ruler(width: traceWidth)
                }
                .frame(height: Self.rulerHeight)
                Divider()
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        NamesColumn()
                            .frame(width: Self.namesWidth)
                        Divider()
                        Traces(width: traceWidth)
                    }
                    .frame(minHeight: geo.size.height - Self.rulerHeight - 1, alignment: .top)
                }
            }
        }
    }
}

// MARK: Names

private struct NamesColumn: View {
    @EnvironmentObject private var wave: WaveformModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(wave.shown, id: \.self) { id in
                if let signal = wave.waveform?.signals[id] {
                    NameRow(signal: signal)
                }
            }
            if wave.shown.isEmpty {
                Text("No signals shown. Use Signals to add some.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
    }
}

private struct NameRow: View {
    @EnvironmentObject private var wave: WaveformModel
    let signal: WaveSignal

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: signal.isBus ? "square.stack.3d.up" : "waveform.path")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(signal.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let value = wave.displayValue(of: signal.id) {
                Text(value)
                    .font(.callout.monospaced())
                    .foregroundStyle(Accent.active)
                    .lineLimit(1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: WaveformView.rowHeight)
        .background(wave.selected == signal.id ? Color.primary.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { wave.selected = signal.id }
        .contextMenu {
            if signal.isBus {
                Menu("Radix") {
                    Button("Default (\(wave.defaultRadix.rawValue))") { wave.setRadix(nil, for: signal.id) }
                    ForEach(WaveRadix.allCases, id: \.self) { radix in
                        Button(radix.rawValue) { wave.setRadix(radix, for: signal.id) }
                    }
                }
            }
            Button("Remove from Waveform") { wave.hide(signal.id) }
        }
        .help(signal.path)
    }
}

// MARK: Traces

private struct Traces: View {
    @EnvironmentObject private var wave: WaveformModel
    let width: CGFloat

    var body: some View {
        let rows = max(wave.shown.count, 1)
        ZStack {
            Canvas { context, size in
                guard let waveform = wave.waveform else { return }
                WaveformPainter(waveform: waveform, shown: wave.shown, start: wave.viewStart, end: wave.viewEnd,
                                cursor: wave.cursor, selected: wave.selected, rowHeight: WaveformView.rowHeight,
                                radix: { wave.radix(for: $0) })
                    .drawTraces(&context, size: size)
            }
            WaveformInteraction(
                onCursor: { wave.setCursor(tick: wave.viewStart + Double($0 / width) * wave.span) },
                onPan: { wave.pan(byTicks: Double($0 / width) * wave.span) },
                onZoom: { factor, x in wave.zoom(by: Double(factor), anchor: Double(min(max(x / width, 0), 1))) })
        }
        .frame(width: width, height: CGFloat(rows) * WaveformView.rowHeight)
    }
}

private struct Ruler: View {
    @EnvironmentObject private var wave: WaveformModel
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let waveform = wave.waveform else { return }
            WaveformPainter(waveform: waveform, shown: [], start: wave.viewStart, end: wave.viewEnd,
                            cursor: wave.cursor, selected: nil, rowHeight: WaveformView.rowHeight, radix: { _ in .hex })
                .drawRuler(&context, size: size)
        }
        .frame(width: width, height: WaveformView.rulerHeight)
    }
}

// MARK: Painting

/// Draws traces and the time ruler. A plain value so it can be tested and so a redraw reads nothing it wasn't given.
struct WaveformPainter {
    let waveform: Waveform
    let shown: [Int]
    let start: Double
    let end: Double
    let cursor: UInt64?
    let selected: Int?
    let rowHeight: CGFloat
    let radix: (Int) -> WaveRadix

    private var span: Double { max(end - start, 1e-9) }

    func x(_ tick: Double, _ width: CGFloat) -> CGFloat { CGFloat((tick - start) / span) * width }

    // MARK: Ruler

    /// 1, 2 or 5 times a power of ten, near `raw`.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let nice: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
        return nice * magnitude
    }

    /// Where the labeled ticks fall, in ticks of the waveform.
    func majorTicks(width: CGFloat) -> [Double] {
        let step = max(WaveformPainter.niceStep(span * 110 / Double(max(width, 1))), 1)
        var ticks: [Double] = []
        var t = (start / step).rounded(.up) * step
        while t <= end && ticks.count < 400 {
            ticks.append(t)
            t += step
        }
        return ticks
    }

    func drawRuler(_ context: inout GraphicsContext, size: CGSize) {
        let majors = majorTicks(width: size.width)
        if let step = majors.count > 1 ? majors[1] - majors[0] : nil {
            var t = (start / (step / 5)).rounded(.up) * (step / 5)
            var minor = Path()
            while t <= end {
                let px = x(t, size.width)
                minor.move(to: CGPoint(x: px, y: size.height - 4))
                minor.addLine(to: CGPoint(x: px, y: size.height))
                t += step / 5
            }
            context.stroke(minor, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
        }
        for tick in majors {
            let px = x(tick, size.width)
            var line = Path()
            line.move(to: CGPoint(x: px, y: size.height - 9))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(.secondary), lineWidth: 1)
            let text = context.resolve(Text(waveform.formatTime(tick)).font(.system(size: 10)).foregroundStyle(.secondary))
            context.draw(text, at: CGPoint(x: px + 3, y: 8), anchor: .leading)
        }
        if let cursor {
            let px = x(Double(cursor), size.width)
            if px >= 0 && px <= size.width {
                let label = context.resolve(Text(waveform.formatTime(Double(cursor))).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                let box = label.measure(in: CGSize(width: 200, height: 20))
                let rect = CGRect(x: min(max(px - box.width / 2 - 5, 0), size.width - box.width - 10), y: 3, width: box.width + 10, height: 16)
                context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Accent.active))
                context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }

    // MARK: Traces

    func drawTraces(_ context: inout GraphicsContext, size: CGSize) {
        // Vertical grid under the ruler's ticks.
        var grid = Path()
        for tick in majorTicks(width: size.width) {
            let px = x(tick, size.width)
            grid.move(to: CGPoint(x: px, y: 0))
            grid.addLine(to: CGPoint(x: px, y: size.height))
        }
        context.stroke(grid, with: .color(.primary.opacity(0.07)), lineWidth: 1)

        for (row, id) in shown.enumerated() {
            let top = CGFloat(row) * rowHeight
            if selected == id {
                context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: rowHeight)), with: .color(.primary.opacity(0.07)))
            }
            var separator = Path()
            separator.move(to: CGPoint(x: 0, y: top + rowHeight))
            separator.addLine(to: CGPoint(x: size.width, y: top + rowHeight))
            context.stroke(separator, with: .color(.primary.opacity(0.06)), lineWidth: 1)

            let signal = waveform.signals[id]
            if signal.isBus {
                drawBus(&context, signal: signal, top: top, width: size.width, radix: radix(id))
            } else {
                drawBit(&context, signal: signal, top: top, width: size.width)
            }
        }

        if let cursor {
            let px = x(Double(cursor), size.width)
            if px >= 0 && px <= size.width {
                var line = Path()
                line.move(to: CGPoint(x: px, y: 0))
                line.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(line, with: .color(Accent.active), lineWidth: 1)
            }
        }
    }

    /// The pieces of a signal in view: pixel range and value of each stretch where it holds one value.
    private func segments(of signal: WaveSignal, width: CGFloat) -> [(x0: CGFloat, x1: CGFloat, value: String)] {
        let range = waveform.visibleChanges(of: signal.id, from: UInt64(max(0, start)), to: UInt64(max(0, end)))
        guard !signal.times.isEmpty else { return [] }
        var result: [(CGFloat, CGFloat, String)] = []
        result.reserveCapacity(min(range.count, Int(width) * 2))
        for k in range {
            let x0 = max(0, x(Double(signal.times[k]), width))
            let x1 = k + 1 < signal.times.count ? min(width, x(Double(signal.times[k + 1]), width)) : width
            if x1 >= 0 && x0 <= width { result.append((x0, x1, signal.values[k])) }
        }
        return result
    }

    private func drawBit(_ context: inout GraphicsContext, signal: WaveSignal, top: CGFloat, width: CGFloat) {
        let high = top + 7, low = top + rowHeight - 7, mid = top + rowHeight / 2
        var line = Path()
        var bars = Path()
        var lastBar = -1
        var previousY: CGFloat?
        for (x0, x1, value) in segments(of: signal, width: width) {
            if x1 - x0 < 1 {
                // Changing faster than a pixel: a solid bar shows "busy".
                let px = Int(x0)
                if px != lastBar { bars.addRect(CGRect(x: CGFloat(px), y: high, width: 1, height: low - high)); lastBar = px }
                previousY = nil
                continue
            }
            switch value {
            case "x":
                context.fill(Path(CGRect(x: x0, y: top + 3, width: x1 - x0, height: rowHeight - 6)), with: .color(Accent.error.opacity(0.22)))
                var m = Path(); m.move(to: CGPoint(x: x0, y: mid)); m.addLine(to: CGPoint(x: x1, y: mid))
                context.stroke(m, with: .color(Accent.error), lineWidth: 1.5)
                previousY = nil
            case "z":
                var m = Path(); m.move(to: CGPoint(x: x0, y: mid)); m.addLine(to: CGPoint(x: x1, y: mid))
                context.stroke(m, with: .color(Accent.warning), lineWidth: 1.5)
                previousY = nil
            default:
                let y = value == "1" ? high : low
                if let previousY { line.addLine(to: CGPoint(x: x0, y: previousY)); line.addLine(to: CGPoint(x: x0, y: y)) }
                else { line.move(to: CGPoint(x: x0, y: y)) }
                line.addLine(to: CGPoint(x: x1, y: y))
                previousY = y
            }
        }
        context.stroke(line, with: .color(Accent.success), style: StrokeStyle(lineWidth: 1.5, lineJoin: .miter))
        context.fill(bars, with: .color(Accent.success.opacity(0.8)))
    }

    private func drawBus(_ context: inout GraphicsContext, signal: WaveSignal, top: CGFloat, width: CGFloat, radix: WaveRadix) {
        let high = top + 6, low = top + rowHeight - 6, mid = top + rowHeight / 2
        var bars = Path()
        var lastBar = -1
        for (x0, x1, value) in segments(of: signal, width: width) {
            if x1 - x0 < 2 {
                let px = Int(x0)
                if px != lastBar { bars.addRect(CGRect(x: CGFloat(px), y: high, width: 1, height: low - high)); lastBar = px }
                continue
            }
            let hasX = value.contains("x"), hasZ = !hasX && value.contains("z")
            let color = hasX ? Accent.error : hasZ ? Accent.warning : Accent.success
            let bevel = min(4, (x1 - x0) / 3)
            var box = Path()
            box.move(to: CGPoint(x: x0, y: mid))
            box.addLine(to: CGPoint(x: x0 + bevel, y: high))
            box.addLine(to: CGPoint(x: x1 - bevel, y: high))
            box.addLine(to: CGPoint(x: x1, y: mid))
            box.addLine(to: CGPoint(x: x1 - bevel, y: low))
            box.addLine(to: CGPoint(x: x0 + bevel, y: low))
            box.closeSubpath()
            context.fill(box, with: .color(color.opacity(0.14)))
            context.stroke(box, with: .color(color), lineWidth: 1.2)

            if x1 - x0 > 24 {
                let text = context.resolve(Text(Waveform.format(value, radix: radix)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary))
                if text.measure(in: CGSize(width: 400, height: 20)).width + 2 * bevel + 4 <= x1 - x0 {
                    context.draw(text, at: CGPoint(x: (x0 + x1) / 2, y: mid), anchor: .center)
                }
            }
        }
        context.fill(bars, with: .color(Accent.success.opacity(0.8)))
    }
}

// MARK: Signal picker

/// A popover listing every signal in the design, grouped by scope, with a checkbox for each.
private struct SignalPicker: View {
    @EnvironmentObject private var wave: WaveformModel
    @State private var query = ""

    private enum Row: Identifiable {
        case scope(id: String, name: String, depth: Int)
        case signal(id: Int, depth: Int)
        var id: String {
            switch self {
            case .scope(let id, _, _): "scope-\(id)"
            case .signal(let id, _): "signal-\(id)"
            }
        }
    }

    private func rows() -> [Row] {
        guard let waveform = wave.waveform else { return [] }
        let words = query.lowercased().split(separator: " ").map(String.init)
        func matches(_ id: Int) -> Bool {
            let name = waveform.signals[id].path.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        func collect(_ scope: WaveScope, depth: Int) -> [Row] {
            let signals = scope.signals.filter(matches).map { Row.signal(id: $0, depth: depth + 1) }
            let children = scope.children.flatMap { collect($0, depth: depth + 1) }
            guard !signals.isEmpty || !children.isEmpty else { return [] }
            return [.scope(id: scope.id, name: scope.name, depth: depth)] + signals + children
        }
        return waveform.scopes.flatMap { collect($0, depth: 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search signals", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            List(rows()) { row in
                switch row {
                case .scope(_, let name, let depth):
                    Label(name, systemImage: "folder")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(depth) * 14)
                case .signal(let id, let depth):
                    if let signal = wave.waveform?.signals[id] {
                        Toggle(isOn: Binding(get: { wave.isShown(id) }, set: { _ in wave.toggle(id) })) {
                            HStack {
                                Text(signal.name)
                                Spacer()
                                Text(signal.kind).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.leading, CGFloat(depth) * 14)
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 340, height: 420)
    }
}
