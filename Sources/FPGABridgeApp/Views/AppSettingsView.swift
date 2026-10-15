import SwiftUI

/// FPGA Bridge > Settings… (⌘,): appearance and editor preferences. Project settings stay in Flow > Settings, as in
/// Vivado.
struct AppSettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            EditorSettings()
                .tabItem { Label("Text Editor", systemImage: "character.cursor.ibeam") }
        }
        .frame(width: 560)
        .modifier(AppearanceRoot())
    }
}

private struct AppearanceSettings: View {
    @AppStorage(AppearanceKey.theme) private var theme = ThemeChoice.system
    @AppStorage(AppearanceKey.accent) private var accent = AccentChoice.system
    @AppStorage(AppearanceKey.glass) private var glass = GlassChoice.regular
    @AppStorage(AppearanceKey.background) private var background = BackgroundChoice.ambient

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Accent color") {
                    HStack(spacing: 8) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button { accent = choice } label: {
                                Circle()
                                    .fill(choice == .system
                                          ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                                                                          center: .center))
                                          : AnyShapeStyle(choice.resolved))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: accent == choice ? 2.5 : 0))
                                    .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                                    .shadow(color: .black.opacity(accent == choice ? 0.25 : 0), radius: 2)
                            }
                            .buttonStyle(.plain)
                            .help(choice.title)
                        }
                    }
                }
            }

            Section {
                Picker("Liquid Glass", selection: $glass) {
                    ForEach(GlassChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Window background", selection: $background) {
                    ForEach(BackgroundChoice.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Tinted glass picks up the accent color. Ambient adds soft color behind panels so the glass has something to refract. Liquid Glass needs macOS 26 or later; earlier systems use translucent materials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                ZStack {
                    AmbientBackground()
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
        .frame(height: 480)
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
