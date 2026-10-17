import FPGABridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Which window a Hardware Manager is in. The Program sheet is shown only by the window that asked for it.
private struct HardwareHostKey: EnvironmentKey { static let defaultValue = "main" }

extension EnvironmentValues {
    var hardwareHost: String {
        get { self[HardwareHostKey.self] }
        set { self[HardwareHostKey.self] = newValue }
    }
}

/// Vivado's Hardware Manager: a banner to open a target, the devices on it, their properties, and a log.
struct HardwareManagerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hardware: HardwareManager

    var body: some View {
        VStack(spacing: 0) {
            TargetBanner()
            Divider()
            HStack(spacing: 0) {
                HardwareTree()
                    .frame(width: 300)
                    .background(Theme.surface)
                Divider()
                DeviceProperties()
                    .background(Theme.surface)
            }
            Divider()
            HardwareLog()
                .frame(height: 130)
        }
    }
}

/// What the Hardware Manager has done and said, so a failure is visible even with no console on screen.
private struct HardwareLog: View {
    @EnvironmentObject private var hardware: HardwareManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Log")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 26)
            Divider()
            if hardware.lines.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
            } else {
                ConsoleLines(lines: hardware.lines)
            }
        }
    }
}

/// The Hardware Manager in a window of its own, for programming a board with no project open (Quick Start).
struct HardwareManagerWindow: View {
    @EnvironmentObject private var hardware: HardwareManager

    var body: some View {
        HardwareManagerView()
            .environment(\.hardwareHost, "standalone")
            .background(Theme.surface)
            .sheet(item: Binding(get: { hardware.sheetHost == "standalone" ? hardware.sheet : nil }, set: { hardware.sheet = $0 })) { kind in
                ProgramDeviceSheet(kind: kind)
            }
    }
}

// MARK: Banner

private struct TargetBanner: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hardware: HardwareManager

    var body: some View {
        StatusBanner(title: title, detail: detail, tint: tint) { icon } actions: { actions }
    }

    @ViewBuilder private var icon: some View {
        switch hardware.target {
        case .opening: ProgressView().controlSize(.small).frame(width: 20)
        default: Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
        }
    }

    private var symbol: String {
        switch hardware.target {
        case .closed: "cable.connector.slash"
        case .opening, .open: "cable.connector"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch hardware.target {
        case .closed, .opening: .secondary
        case .open: Accent.success
        case .failed: Accent.error
        }
    }

    private var title: String {
        switch hardware.target {
        case .closed: "No target is open"
        case .opening: "Connecting to the board…"
        case .open: "Connected: \(hardware.devices.count) device\(hardware.devices.count == 1 ? "" : "s") on the cable"
        case .failed: "Couldn't open a target"
        }
    }

    private var detail: String? {
        switch hardware.target {
        case .closed: "Plug the board in, turn it on, then choose Auto Connect."
        case .opening: nil
        case .open: model.projectBoard.map { "Using the \($0.displayName) settings" } ?? "Using the Digilent cable"
        case .failed(let reason): reason
        }
    }

    @ViewBuilder private var actions: some View {
        switch hardware.target {
        case .closed, .failed:
            Menu {
                Button("Auto Connect") { model.autoConnectHardware() }
                Button("Open New Target…") {}
                    .disabled(true)
                Button("Open Recent Target") {}
                    .disabled(true)
            } label: {
                Text(hardware.target == .closed ? "Open target" : "Try again")
            } primaryAction: {
                model.autoConnectHardware()
            }
            .fixedSize()
            .help("Auto Connect finds the board on USB. Choosing a specific target isn't needed with one board.")
        case .opening:
            EmptyView()
        case .open:
            Button("Refresh") { model.autoConnectHardware() }
                .disabled(hardware.isProgramming)
            Button("Close Target") { hardware.closeTarget() }
                .disabled(hardware.isProgramming)
        }
    }
}

// MARK: Hardware tree

private struct HardwareTree: View {
    @EnvironmentObject private var hardware: HardwareManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle("Hardware")
            Divider()
            if hardware.target == .open {
                List(selection: $hardware.selectedID) {
                    Label("Digilent USB cable", systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                    ForEach(hardware.devices) { device in
                        DeviceRow(device: device)
                            .padding(.leading, 18)
                            .tag(device.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                Text("No hardware target is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hardware: HardwareManager
    @Environment(\.hardwareHost) private var host
    let device: HardwareDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").foregroundStyle(Accent.source)
            Text(device.name)
            Spacer(minLength: 4)
            StatusPill(status: hardware.status(of: device))
        }
        .contextMenu {
            Button(ProgramKind.device.title + "…") { hardware.selectedID = device.id; hardware.present(.device, host: host) }
            Button(ProgramKind.memory.title + "…") { hardware.selectedID = device.id; hardware.present(.memory, host: host) }
        }
    }
}

private struct StatusPill: View {
    let status: ProgramStatus

    var body: some View {
        switch status {
        case .unknown: EmptyView()
        case .programming: ProgressView().controlSize(.mini)
        case .programmed(_, let persistent):
            Pill(text: persistent ? "Flash written" : "Programmed", color: Accent.success, symbol: "checkmark")
        case .failed: Pill(text: "Failed", color: Accent.error, symbol: "xmark")
        }
    }
}

// MARK: Properties

private struct DeviceProperties: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hardware: HardwareManager
    @Environment(\.hardwareHost) private var host

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle("Hardware Device Properties")
            Divider()
            if let device = hardware.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            InfoRow(label: "Name", value: device.name)
                            InfoRow(label: "ID code", value: device.device.idcode, monospaced: true)
                            InfoRow(label: "Family", value: device.device.family.capitalized)
                            InfoRow(label: "Part", value: device.device.partName)
                            InfoRow(label: "Board", value: boardText(for: device))
                            InfoRow(label: "Status", value: statusText(hardware.status(of: device)))
                        }
                        HStack(spacing: 10) {
                            Button(ProgramKind.device.title + "…") { hardware.present(.device, host: host) }
                                .buttonStyle(.bordered)
                            Button(ProgramKind.memory.title + "…") { hardware.present(.memory, host: host) }
                                .buttonStyle(.bordered)
                        }
                        .disabled(hardware.isProgramming)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(hardware.target == .open ? "Select a device." : "Open a target to see its devices.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func boardText(for device: HardwareDevice) -> String {
        if let board = model.projectBoard { return board.displayName }
        let matches = Programmer.boards(matching: device.device).map(\.displayName)
        return matches.isEmpty ? "Unknown" : "Could be \(matches.joined(separator: ", "))"
    }

    private func statusText(_ status: ProgramStatus) -> String {
        switch status {
        case .unknown: "Not programmed in this session"
        case .programming: "Programming…"
        case .programmed(let date, let persistent):
            "\(persistent ? "Configuration memory written" : "Programmed") at \(date.formatted(date: .omitted, time: .shortened))"
        case .failed: "Programming failed"
        }
    }
}

private struct PaneTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Program Device

/// Vivado's Program Device dialog: pick the bitstream, then download it.
struct ProgramDeviceSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hardware: HardwareManager
    @Environment(\.dismiss) private var dismiss
    let kind: ProgramKind
    @State private var path = ""
    /// What the chosen bitstream was built from, when its build left a manifest; `noRecord` when it didn't.
    @State private var built: BuildManifest.Summary?
    @State private var noRecord = false

    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "memorychip").font(.system(size: 28)).foregroundStyle(Accent.source)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.title3.weight(.semibold))
                    Text(kind.persistent
                         ? "Write the bitstream to the board's flash, so the design loads every time the board powers on."
                         : "Choose a bitstream programming file and download it to the device. The design is lost when the board powers off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Device").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(hardware.selected?.name ?? "—")
                }
                GridRow {
                    Text("Bitstream file").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack {
                        TextField("", text: $path)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                        Button("Choose…") { choose() }
                    }
                }
                GridRow {
                    Text("Debug probes file").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("Not supported on the Mac", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
            }

            if let built {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(built.lines, id: \.self) { Text($0) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                ForEach(built.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Accent.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if noRecord && exists {
                Text("This bitstream has no build record next to it, so what it was built from is unknown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !path.isEmpty && !exists && !hardware.backend.isDemo {
                Label("That file doesn't exist. Run Generate Bitstream first, or choose a .bit file.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Accent.warning)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Program") {
                    model.programHardware(bitstream: path, kind: kind)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty || (!hardware.backend.isDemo && !exists))
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear { if path.isEmpty { path = model.defaultBitstreamPath } }
        .task(id: path) { await describe() }
    }

    /// Reads the manifest of the build the bitstream came from, and checks it against the project and the device.
    private func describe() async {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard !path.isEmpty, let manifest = BuildManifest.load(from: folder) else {
            built = nil
            noRecord = !path.isEmpty
            return
        }
        let project = model.project, root = model.projectURL, part = hardware.selected?.device.partName
        let summary = await Task.detached {
            let changes = project.flatMap { p in root.map { manifest.changes(project: p, root: $0) } } ?? []
            return manifest.summary(changes: changes, project: project, devicePart: part)
        }.value
        built = summary
        noRecord = false
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Bitstream"
        panel.allowedContentTypes = [UTType(filenameExtension: "bit")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let url = model.projectURL { panel.directoryURL = url.appendingPathComponent(Remote.localOutputDir) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
