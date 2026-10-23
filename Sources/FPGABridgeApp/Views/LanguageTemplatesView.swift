import FPGABridgeCore
import SwiftUI

/// Vivado's Language Templates window: a tree of HDL and XDC snippets, with a preview and Insert Template.
struct LanguageTemplatesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppearanceKey.editorFontSize) private var fontSize = 12.5
    @State private var query = ""

    private var results: [LanguageTemplate] { LanguageTemplates.search(query) }
    private var selected: LanguageTemplate? { model.selectedTemplateID.flatMap(LanguageTemplates.template(id:)) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search templates", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.pressable)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider()
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    List(LanguageTemplates.tree, children: \.children, selection: $model.selectedTemplateID) { node in
                        Label(node.title, systemImage: symbol(for: node))
                            .tag(node.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                } else if results.isEmpty {
                    Text("No templates match “\(query)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results, selection: $model.selectedTemplateID) { template in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(template.name)
                            Text("\(template.language.rawValue) · \(template.group)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(template.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 300)
            .background(Theme.surface)
            Divider()
            preview
                .background(Theme.surface)
        }
    }

    @ViewBuilder private var preview: some View {
        if let template = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.title3.weight(.semibold))
                        Text(template.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Pill(text: template.language.rawValue, color: .secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(template.text, forType: .string)
                    }
                    Button("Insert Template") { model.insertTemplate(template.text) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canInsertTemplate)
                        .help(model.canInsertTemplate
                              ? "Insert at the cursor in \((model.lastFile ?? "") as NSString)"
                              : "Open a source file first. The template goes in at the cursor.")
                }
                .padding(14)
                Divider()
                CodeEditor(text: .constant(template.text), language: template.language.highlighting,
                           fontSize: CGFloat(fontSize), showLineNumbers: true, focusOnAppear: false, isEditable: false)
                    .id(template.id)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                Text("Choose a template").font(.headline)
                Text("Pick one from the list to see it. Insert Template puts it in the file you're editing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func symbol(for node: TemplateNode) -> String {
        if node.template != nil { return "doc.plaintext" }
        return TemplateLanguage(rawValue: node.title) != nil ? "chevron.left.forwardslash.chevron.right" : "folder"
    }
}
