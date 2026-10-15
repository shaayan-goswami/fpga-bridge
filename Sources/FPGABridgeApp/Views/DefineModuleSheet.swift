import FPGABridgeCore
import SwiftUI

// MARK: Create Source File

/// Vivado's Create Source File dialog: file type, file name, file location.
struct CreateSourceFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sourceSet: SourceSet
    let defaultLanguage: String
    let onCreate: (String) -> Void

    @State private var fileType = ""
    @State private var fileName = ""

    private var fileTypes: [(String, String)] {
        sourceSet == .constraints
            ? [("XDC", "xdc")]
            : [("Verilog", "v"), ("Verilog Header", "vh"), ("SystemVerilog", "sv"), ("VHDL", "vhd")]
    }

    private var ext: String { fileTypes.first { $0.0 == fileType }?.1 ?? fileTypes[0].1 }

    private var problem: String? {
        let name = fileName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        if name.contains(" ") { return "Spaces aren't allowed in file names." }
        if !Project.isPlain((name as NSString).deletingPathExtension) { return "Use only letters, digits, '_' and '-'." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Create Source File").font(.title3.weight(.bold))
                Text("Create a new source file and add it to your project.").foregroundStyle(.secondary)
            }
            .padding(20)

            Form {
                Picker("File type:", selection: $fileType) {
                    ForEach(fileTypes, id: \.0) { Text($0.0).tag($0.0) }
                }
                TextField("File name:", text: $fileName, prompt: Text(sourceSet == .constraints ? "constraints" : "top"))
                LabeledContent("File location:") {
                    Text("<Local to Project>").foregroundStyle(.secondary)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    let base = (fileName.trimmingCharacters(in: .whitespaces) as NSString).deletingPathExtension
                    onCreate("\(base).\(ext)")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fileName.trimmingCharacters(in: .whitespaces).isEmpty || problem != nil)
            }
            .padding(14)
        }
        .frame(width: 480, height: 340)
        .onAppear {
            if fileType.isEmpty {
                fileType = sourceSet == .constraints ? "XDC" : (defaultLanguage == "VHDL" ? "VHDL" : "Verilog")
            }
        }
    }
}

// MARK: Define Module

/// One new HDL file waiting for its module definition.
struct ModuleDraft: Identifiable {
    let id = UUID()
    let fileName: String
    let set: SourceSet
    var module: ModuleDefinition

    var isVHDL: Bool { ["vhd", "vhdl"].contains((fileName as NSString).pathExtension.lowercased()) }

    init(fileName: String, set: SourceSet) {
        self.fileName = fileName
        self.set = set
        let base = (fileName as NSString).deletingPathExtension
        module = ModuleDefinition(name: HDLTemplate.isIdentifier(base) ? base : "\(base)_module")
    }
}

/// Vivado's Define Module dialog, shown after new design or simulation sources are created. With several new
/// files, each one is listed on the left and defined in turn.
struct DefineModuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var drafts: [ModuleDraft]
    let onOK: ([ModuleDraft]) -> Void

    @State private var current: ModuleDraft.ID?
    @State private var selectedPort: PortDefinition.ID?
    @State private var error: String?

    private var index: Int { drafts.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(drafts.count > 1 ? "Define Modules" : "Define Module").font(.title2.weight(.bold))
                Text("Define a module and specify I/O Ports to add to your source file. For each port specified, MSB and LSB values will be ignored unless its Bus column is checked. Ports with blank names will not be written.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 0) {
                if drafts.count > 1 {
                    List(selection: $current) {
                        Section("New Source Files") {
                            ForEach(drafts) { draft in
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(draft.fileName, systemImage: "doc.text")
                                    Text(draft.set == .simulation ? "Simulation source" : "Design source")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 26)
                                }
                                .tag(draft.id)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 210)
                    Divider()
                }
                editor
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { ok() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(14)
        }
        .frame(width: drafts.count > 1 ? 900 : 720, height: 580)
        .onAppear { if current == nil { current = drafts.first?.id } }
    }

    @ViewBuilder
    private var editor: some View {
        if !drafts.isEmpty {
            let draft = $drafts[index]
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text(draft.wrappedValue.isVHDL ? "Entity name:" : "Module name:").gridColumnAlignment(.trailing)
                            TextField("", text: draft.module.name).labelsHidden()
                        }
                        if draft.wrappedValue.isVHDL {
                            GridRow {
                                Text("Architecture name:")
                                TextField("", text: draft.module.architecture).labelsHidden()
                            }
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Module Definition").font(.headline)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("I/O Port Definitions").font(.headline)
                        Spacer()
                        Button { addPort(to: draft) } label: { Image(systemName: "plus") }
                            .help("Add a port")
                        Button { removePort(from: draft) } label: { Image(systemName: "minus") }
                            .disabled(selectedPort == nil)
                            .help("Remove the selected port")
                        Button { movePort(in: draft, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(selectedPort == nil)
                            .help("Move up")
                        Button { movePort(in: draft, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(selectedPort == nil)
                            .help("Move down")
                    }
                    .buttonStyle(.borderless)

                    PortTable(ports: draft.module.ports, selection: $selectedPort)
                }
            }
            .id(draft.wrappedValue.id)
        }
    }

    private func addPort(to draft: Binding<ModuleDraft>) {
        let port = PortDefinition()
        draft.wrappedValue.module.ports.append(port)
        selectedPort = port.id
    }

    private func removePort(from draft: Binding<ModuleDraft>) {
        guard let selectedPort, let i = draft.wrappedValue.module.ports.firstIndex(where: { $0.id == selectedPort }) else { return }
        draft.wrappedValue.module.ports.remove(at: i)
        let ports = draft.wrappedValue.module.ports
        self.selectedPort = ports.isEmpty ? nil : ports[min(i, ports.count - 1)].id
    }

    private func movePort(in draft: Binding<ModuleDraft>, by offset: Int) {
        guard let selectedPort, let i = draft.wrappedValue.module.ports.firstIndex(where: { $0.id == selectedPort }) else { return }
        let j = i + offset
        guard draft.wrappedValue.module.ports.indices.contains(j) else { return }
        draft.wrappedValue.module.ports.swapAt(i, j)
    }

    private func ok() {
        for draft in drafts {
            do {
                try draft.module.validate()
            } catch {
                current = draft.id
                self.error = "\(draft.fileName): \(error)"
                return
            }
        }
        onOK(drafts)
        dismiss()
    }
}

/// The editable I/O Port Definitions table: Port Name, Direction, Bus, MSB, LSB.
private struct PortTable: View {
    @Binding var ports: [PortDefinition]
    @Binding var selection: PortDefinition.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Port Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Direction").frame(width: 110, alignment: .leading)
                Text("Bus").frame(width: 34)
                Text("MSB").frame(width: 56, alignment: .leading)
                Text("LSB").frame(width: 56, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($ports) { $port in
                        HStack(spacing: 10) {
                            TextField("", text: $port.name, prompt: Text("name"))
                                .textFieldStyle(.plain)
                                .font(.body.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Picker("", selection: $port.direction) {
                                ForEach(PortDefinition.Direction.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            Toggle("", isOn: $port.isBus)
                                .labelsHidden()
                                .frame(width: 34)
                            TextField("", value: $port.msb, format: .number)
                                .frame(width: 56)
                                .disabled(!port.isBus)
                                .opacity(port.isBus ? 1 : 0.4)
                            TextField("", value: $port.lsb, format: .number)
                                .frame(width: 56)
                                .disabled(!port.isBus)
                                .opacity(port.isBus ? 1 : 0.4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selection == port.id ? Color.primary.opacity(0.08) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = port.id }
                        Divider().opacity(0.5)
                    }
                }
            }
            .overlay {
                if ports.isEmpty {
                    Text("No ports. Click + to add one.").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 200)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
