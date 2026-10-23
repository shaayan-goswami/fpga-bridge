import FPGABridgeCore
import SwiftUI

/// One line of the I/O Ports window.
struct IOPortRow: Identifiable {
    let port: PlannedPort
    /// What the build had, for the columns I/O planning doesn't edit and to tell what changed since.
    let built: DesignPort?
    let pin: PackagePin?
    let issues: [PinIssue]
    let vcco: String
    let vref: String

    var id: String { port.name }
    var severity: PinIssue.Severity? { issues.map(\.severity).max() }
    var changedSinceBuild: Bool {
        guard let built else { return false }
        return built.packagePin.caseInsensitiveCompare(port.pin) != .orderedSame || built.ioStandard != port.standard
    }

    static func rows(_ ports: [PlannedPort], design: DesignSnapshot?, part: PartData?, issues: [PinIssue]) -> [IOPortRow] {
        ports.map { port in
            let pin = port.isPlaced ? part?.pin(named: port.pin) : nil
            let std = part?.standard(named: port.standard)
            let vcco = std?.vcco(direction: port.direction == "INOUT" ? "OUT" : port.direction).map { String(format: "%.3f", $0) } ?? ""
            return IOPortRow(port: port, built: design?.port(named: port.name), pin: pin,
                             issues: issues.filter { $0.ports.contains(port.name) }, vcco: vcco,
                             vref: (std?.hasVREF ?? false) ? String(format: "%.3f", std?.vref ?? 0) : "")
        }
    }
}

/// Vivado's I/O Ports window, with I/O planning: the Package Pin and I/O Std columns can be edited, for the selected
/// ports at once when the edited row is one of them. Edits go into the constraints file. Selection is shared with the
/// Package window, the schematic, the netlist and Properties.
struct IOPortsTable: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chip: ChipViews
    let stage: DesignStage
    @State private var search = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Ports", unplaced = "Unplaced", problems = "With Problems", changed = "Changed Since Build"
        var id: String { rawValue }
    }

    static let commonStandards = ["LVCMOS33", "LVCMOS25", "LVCMOS18", "LVCMOS15", "LVCMOS12", "LVTTL"]

    var body: some View {
        let design = model.designs[stage]
        let part = model.partData(of: stage)
        let ports = model.plannedPorts(stage)
        let issues = part.map { PinRules.check(ports, part: $0) } ?? []
        let all = IOPortRow.rows(ports, design: design, part: part, issues: issues)
        let shown = all.filter { row in
            (search.isEmpty || row.port.name.localizedCaseInsensitiveContains(search) || row.port.pin.localizedCaseInsensitiveContains(search))
                && {
                    switch filter {
                    case .all: true
                    case .unplaced: !row.port.isPlaced
                    case .problems: row.severity != nil
                    case .changed: row.changedSinceBuild
                    }
                }()
        }.sorted { $0.port.name.localizedStandardCompare($1.port.name) == .orderedAscending }

        VStack(spacing: 0) {
            header(all: all, shown: shown.count, part: part)
            Divider()
            if let notice = chip.notice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Accent.warning)
                    Text(notice).font(.callout).lineLimit(2)
                    Spacer()
                    Button { chip.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Accent.warning.opacity(0.1))
                Divider()
            }
            table(shown, part: part)
        }
    }

    private func header(all: [IOPortRow], shown: Int, part: PartData?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by port or pin", text: $search).textFieldStyle(.plain)
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            let unplaced = all.filter { !$0.port.isPlaced }.count
            let errors = all.filter { $0.severity == .error }.count
            if unplaced > 0 { Pill(text: "\(unplaced) without a pin", color: Accent.warning, symbol: "exclamationmark.triangle.fill") }
            if errors > 0 { Pill(text: "\(errors) with errors", color: Accent.error, symbol: "xmark.octagon.fill") }
            if part == nil {
                Text("No rule checks: part data not on this Mac").font(.caption).foregroundStyle(.secondary)
                    .help("Open the Package window to get it from Vivado once.")
            }
            Text("\(shown) of \(all.count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var selection: Binding<Set<String>> {
        Binding(get: { Set(model.designSelection.filter { $0.kind == .port }.map(\.name)) },
                set: { names in
                    chip.selectedPin = nil
                    model.select(names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { .port($0) })
                })
    }

    /// The ports an edit on `row` applies to: the selection if the row is in it, as in Vivado, else the row alone.
    private func targets(_ row: IOPortRow) -> [String] {
        let selected = selection.wrappedValue
        return selected.contains(row.id) ? Array(selected) : [row.id]
    }

    private func standards(for row: IOPortRow, part: PartData?) -> [String] {
        guard let part, !part.standards.isEmpty else { return Self.commonStandards }
        let names = row.pin.map { part.standards(forBank: $0.bank) } ?? part.standards.map(\.name)
        return names.filter { part.standard(named: $0)?.supports(direction: row.port.direction) ?? true }
    }

    private func table(_ rows: [IOPortRow], part: PartData?) -> some View {
        Table(rows, selection: selection) {
            TableColumn("") { row in
                Group {
                    switch row.severity {
                    case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Accent.error)
                    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Accent.warning)
                    case nil: Image(systemName: row.changedSinceBuild ? "pencil.circle" : "checkmark.circle")
                        .foregroundStyle(row.changedSinceBuild ? Accent.active : .secondary)
                    }
                }
                .help(row.issues.map(\.message).joined(separator: "\n").nonEmpty
                      ?? (row.changedSinceBuild ? "Changed since the build: run it again to use the new place." : "No problems found"))
            }.width(22)
            TableColumn("Name") { Text($0.port.name).font(.callout.monospaced()) }.width(min: 90, ideal: 130)
            TableColumn("Direction") { Text($0.port.direction) }.width(min: 60, ideal: 70, max: 90)
            TableColumn("Package Pin") { row in
                PinField(port: row.port.name, pin: row.port.pin) { model.placePort(row.port.name, on: $0, in: stage) }
            }.width(min: 70, ideal: 90, max: 110)
            TableColumn("Fixed") { row in
                if row.port.isPlaced { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }.width(min: 36, ideal: 40, max: 50)
            TableColumn("Bank") { Text($0.pin?.bank ?? "") }.width(min: 40, ideal: 50, max: 60)
            TableColumn("I/O Std") { row in
                Menu(row.port.standard.isEmpty ? "default" : row.port.standard) {
                    ForEach(standards(for: row, part: part), id: \.self) { std in
                        Button(std) { model.setIOStandard(std, of: targets(row), in: stage) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }.width(min: 100, ideal: 130, max: 170)
            Group {
            TableColumn("Vcco") { (row: IOPortRow) in Text(row.vcco).monospacedDigit() }.width(min: 44, ideal: 50, max: 60)
            TableColumn("Vref") { (row: IOPortRow) in Text(row.vref).monospacedDigit() }.width(min: 44, ideal: 50, max: 60)
            TableColumn("Drive Strength") { (row: IOPortRow) in Text(row.built?.drive ?? "") }.width(min: 50, ideal: 60, max: 90)
            TableColumn("Slew Type") { (row: IOPortRow) in Text(row.built?.slew ?? "") }.width(min: 50, ideal: 60, max: 90)
            TableColumn("Pull Type") { (row: IOPortRow) in Text(row.built?.pullType ?? "") }.width(min: 50, ideal: 60, max: 90)
            }
        }
        .contextMenu(forSelectionType: String.self) { names in
            Button("Unplace") { for name in names { model.placePort(name, on: nil, in: stage) } }
                .disabled(names.isEmpty)
            Button("Show in Package") { model.openPackage(stage) }
            Button("Schematic") { model.schematicOfSelection() }
        }
    }
}

/// A package pin typed into the table; the edit is applied on Return or when the field loses focus, and goes back to
/// the current pin if it was refused.
private struct PinField: View {
    let port: String
    let pin: String
    let commit: (String?) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("—"))
            .textFieldStyle(.plain)
            .font(.callout.monospaced())
            .focused($focused)
            .onAppear { text = pin }
            .onChange(of: pin) { _, new in text = new }
            .onSubmit(apply)
            .onChange(of: focused) { _, now in if !now { apply() } }
    }

    private func apply() {
        let value = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard value != pin.uppercased() else { return }
        if !commit(value.isEmpty ? nil : value) { text = pin }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
