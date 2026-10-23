import AppKit
import FPGABridgeCore
import SwiftUI

/// Vivado's Package window: the package's balls seen from the top, I/O banks in colors, and the design's ports on
/// their pins. Drag a port (from its pin, the list of unplaced ports or the I/O Ports table) onto a pin to place it;
/// the rule checks refuse a pin that can't take it. Below is the I/O Ports table, as in Vivado's I/O Planning layout.
struct PackageView: View {
    @EnvironmentObject private var model: AppModel
    let stage: DesignStage

    var body: some View {
        PackageWindow(chip: model.chipViews, stage: stage)
    }
}

/// Colors for the banks, in order of their names, and for the kinds of pin that aren't user I/O.
enum ChipColors {
    static let banks: [Color] = [
        Color(red: 0.25, green: 0.52, blue: 0.96), Color(red: 0.20, green: 0.70, blue: 0.45), Color(red: 0.62, green: 0.40, blue: 0.90),
        Color(red: 0.10, green: 0.68, blue: 0.75), Color(red: 0.93, green: 0.45, blue: 0.62), Color(red: 0.85, green: 0.62, blue: 0.15),
        Color(red: 0.40, green: 0.45, blue: 0.85), Color(red: 0.45, green: 0.72, blue: 0.20),
    ]

    static func bankColors(_ part: PartData) -> [String: Color] {
        let names = part.banks.filter(\.hasUserIO).map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, banks[$0 % banks.count]) })
    }

    static func color(_ kind: PinKind) -> Color {
        switch kind {
        case .userIO: .gray
        case .ground: Color(white: 0.45)
        case .power: Color(red: 0.86, green: 0.30, blue: 0.25)
        case .vcco: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .config: Color(red: 0.60, green: 0.35, blue: 0.80)
        case .transceiver: Color(red: 0.10, green: 0.62, blue: 0.62)
        case .analog: Color(red: 0.30, green: 0.65, blue: 0.30)
        case .noConnect: Color(white: 0.6)
        }
    }

    static let selection = Color(red: 0.36, green: 0.56, blue: 1.0)
    static let placed = Color(red: 0.98, green: 0.60, blue: 0.10)
}

private struct PackageWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var chip: ChipViews
    let stage: DesignStage

    @State private var viewport = CanvasViewport()
    @State private var needsFit = true
    @State private var hover: String?
    @State private var dragPort: String?
    @State private var dragPoint: CGPoint?
    @State private var showNames = true

    var body: some View {
        let partName = model.part(of: stage)
        if model.designs[stage] == nil {
            ContentUnavailableView("No \(stage.title)", systemImage: "circle.grid.3x3", description: Text("Run a build to produce it."))
        } else if let data = chip.data(for: partName) {
            content(data)
        } else {
            PartDataMissing(chip: chip, part: partName, window: "Package")
        }
    }

    private func content(_ data: PartData) -> some View {
        let layout = PackageLayout(part: data)
        let ports = model.plannedPorts(stage)
        let issues = PinRules.check(ports, part: data)
        return VStack(spacing: 0) {
            toolbar(data, layout: layout)
            Divider()
            VSplitView {
                HStack(spacing: 0) {
                    canvas(data, layout: layout, ports: ports, issues: issues)
                    Divider()
                    PackageSidebar(chip: chip, stage: stage, part: data, ports: ports, issues: issues)
                        .frame(width: 260)
                }
                .frame(minHeight: 240, idealHeight: 460)
                IOPortsTable(chip: chip, stage: stage)
                    .frame(minHeight: 120, idealHeight: 220)
            }
        }
        .background(Theme.surface)
    }

    // MARK: Toolbar

    private func toolbar(_ data: PartData, layout: PackageLayout) -> some View {
        HStack(spacing: 10) {
            Group {
                Button { viewport.zoom(by: 1.4, about: viewport.center) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
                Button { viewport.zoom(by: 1 / 1.4, about: viewport.center) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                Button { fit(layout) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom Fit")
                Toggle(isOn: $showNames) { Image(systemName: "character.textbox") }
                    .toggleStyle(.button)
                    .help("Show port names on their pins")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 14)
            Text("\(data.part) · \(data.package) package · Top View").font(.caption).foregroundStyle(.secondary)
            if chip.backend.isDemo {
                Pill(text: "Demo data, not the real pinout", color: Accent.warning, symbol: "exclamationmark.triangle.fill")
            }
            Spacer()
            if AppModel.hasDeviceView(stage) {
                Button { model.openDevice(stage) } label: { Label("Device", systemImage: "cpu") }
                    .help("Open the Device window")
            }
            Button {
                chip.fetch(data.part)
            } label: {
                if chip.load(of: data.part) == .loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .disabled(!chip.backend.canFetch || chip.load(of: data.part) == .loading)
            .help(chip.backend.canFetch ? "Get the part data from Vivado again (Vivado \(data.vivado))" : NoBuildMachine.message)
            Text("\(Int(viewport.scale * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func fit(_ layout: PackageLayout) {
        viewport.fit(CGRect(origin: .zero, size: layout.size).insetBy(dx: -10, dy: -10), maxScale: 3)
        needsFit = viewport.size == .zero
    }

    // MARK: Canvas

    private func canvas(_ data: PartData, layout: PackageLayout, ports: [PlannedPort], issues: [PinIssue]) -> some View {
        let byPin = Dictionary(ports.filter(\.isPlaced).map { ($0.pin.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let selectedPorts = Set(model.designSelection.filter { $0.kind == .port }.map(\.name))
        var selectedPins = Set(ports.filter { selectedPorts.contains($0.name) && $0.isPlaced }.map { $0.pin.uppercased() })
        if let pin = chip.selectedPin { selectedPins.insert(pin) }
        let errorPins = Set(issues.filter { $0.severity == .error }.flatMap(\.pins).map { $0.uppercased() })
        let target = dragPoint.flatMap { layout.pin(at: viewport.toModel($0)) }
        let colors = ChipColors.bankColors(data)
        let dark = scheme == .dark

        return GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, _ in
                    ctx.translateBy(x: -viewport.offset.x, y: -viewport.offset.y)
                    ctx.scaleBy(x: viewport.scale, y: viewport.scale)
                    drawPackage(ctx, data: data, layout: layout, byPin: byPin, selectedPins: selectedPins, errorPins: errorPins,
                                target: target, colors: colors, dark: dark)
                }
                ChipCanvasInteraction(
                    onPan: { viewport.pan($0); needsFit = false },
                    onZoom: { viewport.zoom(by: $0, about: $1); needsFit = false },
                    onClick: { at, extend, _ in click(at, extend: extend, layout: layout, byPin: byPin) },
                    onHover: { at in hover = at.flatMap { describe(layout.pin(at: viewport.toModel($0)), data: data, byPin: byPin) } },
                    menu: { at in menu(at, layout: layout, byPin: byPin, ports: ports) },
                    canDrag: { at in
                        guard let pin = layout.pin(at: viewport.toModel(at)), let port = byPin[pin] else { return false }
                        dragPort = port.name
                        return true
                    },
                    onDragMove: { dragPoint = $0 },
                    onDragEnd: { at in
                        if let port = dragPort, let pin = layout.pin(at: viewport.toModel(at)) { model.placePort(port, on: pin, in: stage) }
                        dragPort = nil
                    },
                    onDropName: { name, at in
                        guard model.designs[stage]?.port(named: name) != nil, let pin = layout.pin(at: viewport.toModel(at)) else { return false }
                        return model.placePort(name, on: pin, in: stage)
                    })
                if let hover { CanvasCaption(text: hover) }
            }
            .clipped()
            .onAppear { viewport.size = geometry.size; if needsFit { fit(layout) } }
            .onChange(of: geometry.size) { _, size in
                viewport.size = size
                if needsFit { fit(layout) }
            }
        }
    }

    private func drawPackage(_ ctx: GraphicsContext, data: PartData, layout: PackageLayout, byPin: [String: PlannedPort],
                             selectedPins: Set<String>, errorPins: Set<String>, target: String?, colors: [String: Color], dark: Bool) {
        let outline = CGRect(origin: .zero, size: layout.size).insetBy(dx: PackageLayout.margin - 8, dy: PackageLayout.margin - 8)
        ctx.fill(Path(roundedRect: outline, cornerRadius: 10), with: .color(dark ? Color(white: 0.13) : Color(white: 0.97)))
        ctx.stroke(Path(roundedRect: outline, cornerRadius: 10), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
        // A1 corner mark, as on the real package.
        var corner = Path()
        corner.move(to: CGPoint(x: outline.minX, y: outline.minY + 22))
        corner.addLine(to: CGPoint(x: outline.minX + 22, y: outline.minY))
        ctx.stroke(corner, with: .color(.secondary.opacity(0.6)), lineWidth: 1)

        for (index, row) in layout.rows.enumerated() {
            ctx.draw(Text(row).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary), at: layout.rowLabel(index))
        }
        for column in 1...max(1, layout.columns) {
            ctx.draw(Text("\(column)").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary), at: layout.columnLabel(column))
        }

        let r = PackageLayout.pitch * 0.36
        for pin in data.pins {
            guard let c = layout.centers[pin.name] else { continue }
            let key = pin.name.uppercased()
            let kind = pin.kind
            let bankColor = colors[pin.bank] ?? ChipColors.color(kind)
            let ball = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            switch kind {
            case .userIO:
                let shape = pin.isClockCapable ? hexagon(c, r) : Path(ellipseIn: ball)
                if byPin[key] != nil {
                    ctx.fill(shape, with: .color(ChipColors.placed))
                    ctx.stroke(shape, with: .color(bankColor), lineWidth: 2)
                } else {
                    ctx.fill(shape, with: .color(bankColor.opacity(dark ? 0.35 : 0.22)))
                    ctx.stroke(shape, with: .color(bankColor), lineWidth: 1)
                }
                if pin.isVREF {
                    ctx.draw(Text("V").font(.system(size: 7, weight: .bold)).foregroundColor(bankColor), at: c)
                }
            case .ground:
                ctx.fill(Path(ellipseIn: ball.insetBy(dx: r * 0.35, dy: r * 0.35)), with: .color(ChipColors.color(kind)))
            case .power:
                ctx.fill(Path(roundedRect: ball.insetBy(dx: r * 0.2, dy: r * 0.2), cornerRadius: 2), with: .color(ChipColors.color(kind).opacity(0.75)))
            case .vcco:
                let square = Path(roundedRect: ball.insetBy(dx: r * 0.2, dy: r * 0.2), cornerRadius: 2)
                ctx.fill(square, with: .color(bankColor.opacity(0.45)))
                ctx.stroke(square, with: .color(ChipColors.color(.vcco)), lineWidth: 1.5)
            case .config:
                var tri = Path()
                tri.move(to: CGPoint(x: c.x, y: c.y - r * 0.9))
                tri.addLine(to: CGPoint(x: c.x + r * 0.85, y: c.y + r * 0.7))
                tri.addLine(to: CGPoint(x: c.x - r * 0.85, y: c.y + r * 0.7))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(ChipColors.color(kind).opacity(0.8)))
            case .transceiver, .analog:
                ctx.fill(diamond(c, r * 0.9), with: .color(ChipColors.color(kind).opacity(0.8)))
            case .noConnect:
                ctx.stroke(Path(ellipseIn: ball.insetBy(dx: r * 0.4, dy: r * 0.4)), with: .color(ChipColors.color(kind)), lineWidth: 1)
            }
            if errorPins.contains(key) {
                ctx.stroke(Path(ellipseIn: ball.insetBy(dx: -3, dy: -3)), with: .color(Accent.error), lineWidth: 2)
            }
            if selectedPins.contains(key) {
                ctx.stroke(Path(ellipseIn: ball.insetBy(dx: -5, dy: -5)), with: .color(ChipColors.selection), lineWidth: 2.5)
            }
            if target == pin.name {
                ctx.stroke(Path(ellipseIn: ball.insetBy(dx: -5, dy: -5)), with: .color(kind == .userIO ? ChipColors.selection : Accent.error),
                           style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            }
            if showNames, let port = byPin[key] {
                ctx.draw(Text(port.name).font(.system(size: 5.5, weight: .semibold)).foregroundColor(.primary),
                         at: CGPoint(x: c.x, y: c.y + r + 3.5))
            }
        }
    }

    private func hexagon(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3
            let point = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if k == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }

    private func diamond(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x + r, y: c.y))
        p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        p.addLine(to: CGPoint(x: c.x - r, y: c.y))
        p.closeSubpath()
        return p
    }

    // MARK: Interaction

    private func click(_ at: CGPoint, extend: Bool, layout: PackageLayout, byPin: [String: PlannedPort]) {
        guard let pin = layout.pin(at: viewport.toModel(at)) else {
            if !extend { model.select(nil); chip.selectedPin = nil }
            return
        }
        if let port = byPin[pin] {
            chip.selectedPin = nil
            model.select(.port(port.name), extend: extend)
        } else {
            model.select(nil)
            chip.selectedPin = pin
        }
    }

    private func describe(_ pin: String?, data: PartData, byPin: [String: PlannedPort]) -> String? {
        guard let pin, let info = data.pin(named: pin) else { return nil }
        var parts = [info.name, info.function]
        if !info.bank.isEmpty { parts.append("bank \(info.bank)") }
        if info.isClockCapable { parts.append("clock-capable") }
        if let port = byPin[pin] { parts.append("\(port.name) (\(port.direction), \(port.standard))") }
        return parts.joined(separator: " · ")
    }

    private func menu(_ at: CGPoint, layout: PackageLayout, byPin: [String: PlannedPort], ports: [PlannedPort]) -> [ChipMenuItem] {
        var items: [ChipMenuItem] = []
        if let pin = layout.pin(at: viewport.toModel(at)) {
            if let port = byPin[pin] {
                model.select(.port(port.name))
                items.append(ChipMenuItem(title: "Unplace \(port.name)") { model.placePort(port.name, on: nil, in: stage) })
                items.append(ChipMenuItem(title: "Schematic") { model.schematicOfSelection() })
            } else {
                let selected = model.designSelection.filter { $0.kind == .port }.map(\.name)
                if selected.count == 1, let name = selected.first {
                    items.append(ChipMenuItem(title: "Place \(name) Here") { model.placePort(name, on: pin, in: stage) })
                }
            }
            items.append(ChipMenuItem(title: "Copy Pin Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pin, forType: .string)
            })
            items.append(ChipMenuItem(title: "-") {})
        }
        items.append(ChipMenuItem(title: "Zoom Fit") { fit(layout) })
        return items
    }
}

// MARK: Sidebar

/// Next to the package: what is selected, the banks and their voltages, the ports still without a pin (drag them
/// onto the package), the problems the rule checks found, and the legend.
private struct PackageSidebar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chip: ChipViews
    let stage: DesignStage
    let part: PartData
    let ports: [PlannedPort]
    let issues: [PinIssue]

    var body: some View {
        List {
            selectionSection
            Section("I/O Banks") {
                let colors = ChipColors.bankColors(part)
                ForEach(part.banks.filter(\.hasUserIO)) { bank in
                    HStack(spacing: 8) {
                        Circle().fill(colors[bank.name] ?? .gray).frame(width: 10, height: 10)
                        Text("Bank \(bank.name)").monospacedDigit()
                        Spacer()
                        Text(vcco(of: bank.name)).font(.caption).foregroundStyle(.secondary)
                    }
                    .help("\(bank.type.title) bank, \(part.pins.filter { $0.bank == bank.name && $0.kind == .userIO }.count) user I/O pins")
                }
            }
            let unplaced = ports.filter { !$0.isPlaced }
            Section("Unplaced Ports (\(unplaced.count))") {
                if unplaced.isEmpty {
                    Text("Every port has a pin.").foregroundStyle(.secondary)
                } else {
                    ForEach(unplaced) { port in
                        HStack {
                            Image(systemName: port.direction == "IN" ? "arrow.right" : port.direction == "OUT" ? "arrow.left" : "arrow.left.arrow.right")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(port.name).font(.callout.monospaced())
                            Spacer()
                            Text(port.standard).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { chip.selectedPin = nil; model.select(.port(port.name)) }
                        .draggable(port.name)
                        .help("Drag onto a pin to place it")
                    }
                }
            }
            Section("Problems (\(issues.count))") {
                if issues.isEmpty {
                    Label("No problems found", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? Accent.error : Accent.warning)
                            Text(issue.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if !issue.ports.isEmpty { chip.selectedPin = nil; model.select(issue.ports.map { .port($0) }) } }
                    }
                }
            }
            Section("Legend") {
                legend("circle.fill", ChipColors.placed, "Placed port")
                legend("circle", .secondary, "User I/O (bank color)")
                legend("hexagon", .secondary, "Clock-capable I/O (MRCC/SRCC)")
                legend("square.fill", ChipColors.color(.vcco), "VCCO")
                legend("square.fill", ChipColors.color(.power), "Power")
                legend("circle.fill", ChipColors.color(.ground), "Ground")
                legend("triangle.fill", ChipColors.color(.config), "Configuration")
                legend("diamond.fill", ChipColors.color(.transceiver), "Transceiver")
                legend("diamond.fill", ChipColors.color(.analog), "Analog (XADC)")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var selectionSection: some View {
        let selected = model.designSelection.filter { $0.kind == .port }.compactMap { ref in ports.first { $0.name == ref.name } }
        if let pinName = chip.selectedPin ?? selected.last.flatMap({ $0.isPlaced ? $0.pin : nil }), let pin = part.pin(named: pinName) {
            Section("Package Pin") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                InfoRow(label: "Name", value: pin.name, monospaced: true)
                InfoRow(label: "Function", value: pin.function, monospaced: true)
                InfoRow(label: "Type", value: pin.kind.title)
                if !pin.bank.isEmpty { InfoRow(label: "Bank", value: pin.bank) }
                if !pin.diffPair.isEmpty { InfoRow(label: pin.isPositive ? "P of pair with" : "N of pair with", value: pin.diffPair, monospaced: true) }
                if pin.isClockCapable { InfoRow(label: "Clock", value: "Clock-capable") }
                if pin.isVREF { InfoRow(label: "VREF", value: "Bank's VREF pin") }
                if !pin.site.isEmpty { InfoRow(label: "Site", value: pin.site, monospaced: true) }
                if let port = ports.first(where: { $0.pin.caseInsensitiveCompare(pin.name) == .orderedSame }) {
                    InfoRow(label: "Port", value: "\(port.name) · \(port.standard)", monospaced: true)
                }
                }
            }
        }
    }

    private func vcco(of bank: String) -> String {
        let pinsInBank = Set(part.pins.filter { $0.bank == bank }.map { $0.name.uppercased() })
        let volts = Set(ports.filter { pinsInBank.contains($0.pin.uppercased()) }.compactMap { port in
            part.standard(named: port.standard)?.vcco(direction: port.direction == "IN" ? "IN" : "OUT")
        })
        if volts.isEmpty { return "unused" }
        return volts.sorted().map { String(format: "%g V", $0) }.joined(separator: " + ")
    }

    private func legend(_ symbol: String, _ color: Color, _ title: String) -> some View {
        Label { Text(title).font(.caption) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
}
