import SwiftUI

/// FPGA Bridge > Settings… (⌘,): appearance and editor preferences. Project settings stay in Flow > Settings, as in
/// Vivado.
struct AppSettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            EditorSettings()
                .tabItem { Label("Text Editor", systemImage: "character.cursor.ibeam") }
        }
        .frame(width: 540)
        .modifier(AppearanceRoot())
    }
}

private struct AppearanceSettings: View {
    @AppStorage(AppearanceKey.theme) private var theme = ThemeChoice.system
    @AppStorage(AppearanceKey.glass) private var glass = GlassChoice.frosted
    @AppStorage(AppearanceKey.accents) private var accents = true

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Liquid Glass", selection: $glass) {
                    ForEach(GlassChoice.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Frosted glass blurs more than Clear. Liquid Glass needs macOS 26 or later; earlier systems use translucent materials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Accent colors", isOn: $accents)
                if accents {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 8) {
                        ForEach(Accent.legend) { entry in
                            HStack(spacing: 8) {
                                Circle().fill(entry.color).frame(width: 9, height: 9)
                                Text(entry.name).font(.callout)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Muted colours that each mean one thing. Turn them off for an all-grey app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                ZStack {
                    Backdrop()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 12) {
                        Label("Run Synthesis", systemImage: "play.fill")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassSurface(Capsule())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Timing").font(.headline)
                            Text("+5.231 ns").font(.title3.weight(.semibold)).monospacedDigit()
                        }
                        .padding(12)
                        .glassSurface(cornerRadius: 12)
                    }
                }
                .frame(height: 110)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

private struct EditorSettings: View {
    @AppStorage(AppearanceKey.editorFontSize) private var editorFontSize = 12.5
    @AppStorage(AppearanceKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(AppearanceKey.consoleFontSize) private var consoleFontSize = 12.0

    var body: some View {
        Form {
            Section("Text Editor") {
                LabeledContent("Font size") {
                    Stepper(value: $editorFontSize, in: 9...24, step: 0.5) {
                        Text(String(format: "%.1f pt", editorFontSize)).monospacedDigit()
                    }
                }
                Toggle("Show line numbers", isOn: $lineNumbers)
                Text("module blinky (input clk, output [3:0] led);")
                    .font(.system(size: editorFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Section("Tcl Console, Messages and Log") {
                LabeledContent("Font size") {
                    Stepper(value: $consoleFontSize, in: 9...20, step: 0.5) {
                        Text(String(format: "%.1f pt", consoleFontSize)).monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }
}
