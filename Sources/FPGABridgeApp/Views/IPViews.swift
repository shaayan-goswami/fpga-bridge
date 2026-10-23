import AppKit
import FPGABridgeCore
import SwiftUI

// MARK: IP Catalog tab

/// Vivado's IP Catalog: a category tree, search, the IP that match, and details with Customize IP.
struct IPCatalogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var onlySupported = true
    @State private var category = ""            // "" is all IP
    @State private var selection: String?
    @State private var customizing: IPDefinition?
    @State private var collapsed: Set<String> = []

    var body: some View {
        Group {
            switch model.ipLoad {
            case .loading:
                ProgressView("Asking Vivado for its IP catalog…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load the IP catalog", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { model.loadIPCatalog(refresh: true) }
                }
            case .idle:
                if let catalog = model.ipCatalog { content(catalog) }
                else {
                    ContentUnavailableView {
                        Label("IP Catalog", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("The catalog comes from Vivado on the build machine.")
                    } actions: {
                        Button("Load Catalog") { model.loadIPCatalog() }
                    }
                }
            }
        }
        .background(Theme.surface)
        .sheet(item: $customizing) { CustomizeIPSheet(definition: $0) }
        #if DEBUG
        .task(id: model.ipCatalog?.definitions.count) {
            // Screenshot scenarios: pick the Binary Counter, and for "ipcustomize" open its settings.
            guard let scenario = DebugHooks.scenario, scenario.hasPrefix("ip"), let catalog = model.ipCatalog else { return }
            selection = "xilinx.com:ip:c_counter_binary:12.0"
            search = "counter"
            if scenario == "ipcustomize" { customizing = catalog.definitions.first { $0.id == selection } }
        }
        #endif
    }

    private func visible(_ catalog: IPCatalog) -> [IPDefinition] {
        let matching = catalog.search(search, onlySupported: onlySupported)
        guard !category.isEmpty else { return matching }
        return matching.filter { def in def.categoryPaths.contains { path in ("/" + path.joined(separator: "/")).hasPrefix(category) } }
    }

    private func content(_ catalog: IPCatalog) -> some View {
        let results = visible(catalog)
        let tree = IPCatalog.categories(of: catalog.search("", onlySupported: onlySupported))
        return HStack(spacing: 0) {
            List(selection: Binding(get: { category as String? }, set: { category = $0 ?? "" })) {
                Label("All IP (\(catalog.search("", onlySupported: onlySupported).count))", systemImage: "square.grid.2x2").tag("")
                ForEach(flatten(tree)) { row in
                    HStack(spacing: 4) {
                        Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                        if row.node.children.isEmpty { Color.clear.frame(width: 12, height: 1) }
                        else {
                            Button {
                                if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                            } label: {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 12)
                                    .rotationEffect(.degrees(collapsed.contains(row.id) ? 0 : 90))
                            }
                            .buttonStyle(.pressable)
                        }
                        Text(row.node.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(row.node.allDefinitions.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(row.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                toolbar(catalog, shown: results.count)
                Divider()
                Table(results, selection: $selection) {
                    TableColumn("Name") { def in
                        HStack(spacing: 6) {
                            Text(def.displayName)
                            if !def.supported { Pill(text: "Not for this part", color: Accent.warning) }
                            if def.requiresLicense { Pill(text: "License", color: .secondary) }
                        }
                    }
                    TableColumn("Version") { Text($0.version) }.width(min: 50, ideal: 60, max: 80)
                    TableColumn("IP name") { Text($0.name).font(.callout.monospaced()) }.width(min: 100, ideal: 160, max: 240)
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let def = catalog.definitions.first(where: { $0.id == id }) { customizing = def }
                }
                Divider()
                details(catalog)
                    .frame(height: 150)
            }
        }
    }

    private func toolbar(_ catalog: IPCatalog, shown: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search IP", text: $search).textFieldStyle(.plain)
            Toggle("Only for \(catalog.part.isEmpty ? "this part" : catalog.part)", isOn: $onlySupported).toggleStyle(.checkbox)
            Text("\(shown) shown").font(.caption).foregroundStyle(.secondary)
            Button { model.loadIPCatalog(refresh: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Ask Vivado for the catalog again")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    @ViewBuilder private func details(_ catalog: IPCatalog) -> some View {
        if let def = catalog.definitions.first(where: { $0.id == selection }) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(def.displayName).font(.headline)
                    Text(def.vlnv).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(def.description.isEmpty ? "No description." : def.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    Text(def.categoryPaths.map { $0.joined(separator: " › ").replacingOccurrences(of: "_", with: " ") }.joined(separator: "   ·   "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Button("Customize IP…") { customizing = def }
                        .buttonStyle(.borderedProminent)
                        .disabled(!def.supported)
                        .help(def.supported ? "Choose its settings and add it to the project" : "This IP doesn't support the project's device")
                    if model.ipCatalog?.vivado.contains("demo") == true { Text("Sample data").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .padding(14)
        } else {
            Text("Select an IP to see what it does.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Category rows

    private struct CategoryRow: Identifiable {
        let node: IPCategory
        let depth: Int
        var id: String { node.id }
    }

    private func flatten(_ nodes: [IPCategory], depth: Int = 0) -> [CategoryRow] {
        nodes.flatMap { node in
            [CategoryRow(node: node, depth: depth)] + (collapsed.contains(node.id) ? [] : flatten(node.children, depth: depth + 1))
        }
    }
}

// MARK: Customize IP

/// Vivado's Customize IP: name the instance and change its settings, then add it. The settings come from Vivado with
/// their defaults; only the ones you change are saved.
struct CustomizeIPSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let definition: IPDefinition

    @State private var instance = ""
    @State private var properties: [IPProperty] = []
    @State private var values: [String: String] = [:]
    @State private var loading = true
    @State private var adding = false
    @State private var problem: String?
    @State private var filter = ""

    private var changed: [String: String] {
        Dictionary(uniqueKeysWithValues: properties.compactMap { p in values[p.name].flatMap { $0 != p.value ? (p.name, $0) : nil } })
    }

    private var candidate: ProjectIP { ProjectIP(name: instance, vlnv: definition.vlnv, config: changed) }

    private var invalid: String? {
        do { try candidate.validate(); return nil } catch { return error.userMessage }
    }

    private var shown: [IPProperty] {
        filter.isEmpty ? properties : properties.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize IP").font(.title2.weight(.bold))
                Text("\(definition.displayName)  ·  \(definition.vlnv)").font(.callout).foregroundStyle(.secondary)
            }
            .padding(22)
            Divider()
            Form {
                LabeledContent("Instance name:") {
                    TextField("", text: $instance)
                        .labelsHidden()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(invalid == nil || instance.isEmpty ? Color.primary : Accent.error)
                }
                Section {
                    if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the settings from Vivado…").foregroundStyle(.secondary) }
                    } else if properties.isEmpty {
                        Text("This IP has no settings.").foregroundStyle(.secondary)
                    } else {
                        TextField("Filter settings", text: $filter)
                        ForEach(shown) { property in row(property) }
                    }
                } header: {
                    Text("Settings\(changed.isEmpty ? "" : "  (\(changed.count) changed)")")
                } footer: {
                    Text("Values are checked by Vivado when you add the IP. Settings you don't change stay at Vivado's defaults.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Accent.error).lineLimit(3)
                } else if adding {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the settings with Vivado…").foregroundStyle(.secondary) }
                } else if let invalid, !instance.isEmpty {
                    Label(invalid, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Accent.error).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add IP") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || adding || invalid != nil)
            }
            .controlSize(.large)
            .padding(14)
        }
        .frame(width: 640, height: 640)
        .task { await load() }
    }

    @ViewBuilder private func row(_ property: IPProperty) -> some View {
        let value = values[property.name] ?? property.value
        HStack {
            Text(property.title).foregroundStyle(value == property.value ? Color.primary : Accent.active)
            Spacer(minLength: 8)
            if property.isBoolean {
                Toggle("", isOn: Binding(get: { value == "true" }, set: { values[property.name] = $0 ? "true" : "false" })).labelsHidden()
            } else {
                TextField("", text: Binding(get: { value }, set: { values[property.name] = $0 }))
                    .labelsHidden()
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 200)
                    .foregroundStyle(ProjectIP.isPlainValue(value) ? Color.primary : Accent.error)
            }
            Button { values[property.name] = property.value } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .opacity(value == property.value ? 0 : 1)
                .help("Back to the default (\(property.value))")
        }
    }

    private func load() async {
        let taken = Set((model.project?.ips ?? []).map(\.name))
        var n = 0
        while taken.contains("\(definition.name)_\(n)") { n += 1 }
        instance = "\(definition.name)_\(n)"
        do {
            properties = try await model.ipProperties(of: definition)
            values = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.value) })
        } catch {
            problem = error.userMessage
        }
        loading = false
    }

    private func add() {
        problem = nil
        adding = true
        Task {
            do {
                try await model.addIP(candidate)
                dismiss()
            } catch {
                problem = error.userMessage
            }
            adding = false
        }
    }
}

// MARK: Instantiation template

/// The code to paste into your design to use an IP, in the project's language.
struct IPTemplateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ip: ProjectIP
    @State private var output: IPScriptOutput?
    @State private var problem: String?
    @State private var vhdl = false

    private var text: String {
        guard let output else { return "" }
        return IPScripts.cutSection(of: vhdl ? output.vhdlTemplate : output.verilogTemplate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Instantiation Template").font(.title2.weight(.bold))
                Text("\(ip.name)  ·  \(ip.vlnv)").font(.callout).foregroundStyle(.secondary)
            }
            Picker("Language", selection: $vhdl) {
                Text("Verilog").tag(false)
                Text("VHDL").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Accent.error)
            } else if output == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking Vivado…").foregroundStyle(.secondary) }
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                Text("Change your_instance_name and connect the ports to your own signals.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(text.isEmpty)
                Button("Insert in Editor") { model.insertTemplate(text); dismiss() }
                    .disabled(text.isEmpty || !model.canInsertTemplate)
                    .help(model.canInsertTemplate ? "Insert at the cursor of the file you were editing" : "Open a source file first")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
        .task {
            vhdl = model.project?.targetLanguage == "VHDL"
            do { output = try await model.ipTemplate(for: ip) } catch { problem = error.userMessage }
        }
    }
}

// MARK: IP Sources

/// The IP the project uses, in the Sources window's IP Sources tab.
struct IPSourcesList: View {
    @EnvironmentObject private var model: AppModel
    @State private var showing: ProjectIP?

    var body: some View {
        let ips = model.project?.ips ?? []
        if ips.isEmpty {
            ContentUnavailableView {
                Label("No IP", systemImage: "puzzlepiece.extension")
            } description: {
                Text("IP from Vivado's catalog that the design uses appears here.")
            } actions: {
                Button("Open IP Catalog") { model.openIPCatalog() }
            }
        } else {
            VStack(spacing: 0) {
                List(ips) { ip in
                    HStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension").foregroundStyle(Accent.source)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ip.name).fontWeight(.medium)
                            Text(ip.vlnvParts.map { "\($0[2]) \($0[3])" } ?? ip.vlnv).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !ip.config.isEmpty { Pill(text: "\(ip.config.count) changed", color: .secondary) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { showing = ip }
                    .contextMenu {
                        Button("Instantiation Template…") { showing = ip }
                        Divider()
                        Button("Remove IP", role: .destructive) { model.removeIP(named: ip.name) }
                    }
                }
                .listStyle(.inset)
                .surfaceBackground()
                Divider()
                HStack {
                    Button { model.openIPCatalog() } label: { Label("Add IP…", systemImage: "plus") }.buttonStyle(.borderless)
                    Spacer()
                    Text("Rebuilt by every synthesis").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            .sheet(item: $showing) { IPTemplateSheet(ip: $0) }
        }
    }
}
