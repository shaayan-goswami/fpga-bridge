import AppKit
import SwiftUI

// MARK: Settings keys and choices

/// Everything on the Appearance settings page. Stored in UserDefaults via @AppStorage.
enum AppearanceKey {
    static let theme = "appearance.theme"
    static let accent = "appearance.accent"
    static let glass = "appearance.glass"
    static let background = "appearance.background"
    static let editorFontSize = "editor.fontSize"
    static let editorLineNumbers = "editor.lineNumbers"
    static let consoleFontSize = "console.fontSize"
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system, blue, indigo, purple, pink, red, orange, yellow, green, teal, graphite
    var id: String { rawValue }
    var title: String { self == .system ? "Multicolor" : rawValue.capitalized }

    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }

    /// The colour to tint glass and the ambient background with.
    var resolved: Color { color ?? .accentColor }
}

enum GlassChoice: String, CaseIterable, Identifiable {
    case regular, clear, tinted, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regular: "Regular"
        case .clear: "Clear"
        case .tinted: "Tinted"
        case .off: "Off (solid)"
        }
    }
}

enum BackgroundChoice: String, CaseIterable, Identifiable {
    case ambient, plain
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: Glass surfaces

extension View {
    /// A Liquid Glass surface (macOS 26+), following the user's glass setting. Falls back to a material on older
    /// systems and to a solid panel when glass is turned off.
    func glassSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }

    func glassSurface(cornerRadius: CGFloat = 12, interactive: Bool = false) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), interactive: interactive)
    }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @AppStorage(AppearanceKey.glass) private var glass = GlassChoice.regular
    @AppStorage(AppearanceKey.accent) private var accent = AccentChoice.system

    func body(content: Content) -> some View {
        if glass == .off {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(liquidGlass, in: shape)
        } else {
            content
                .background(glass == .clear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
        }
    }

    @available(macOS 26.0, *)
    private var liquidGlass: Glass {
        var result: Glass = glass == .clear ? .clear : .regular
        if glass == .tinted { result = result.tint(accent.resolved.opacity(0.28)) }
        if interactive { result = result.interactive() }
        return result
    }
}

/// Groups nearby glass shapes so they blend and morph together (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension View {
    /// The prominent Liquid Glass button style where available.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: Ambient background

/// Soft colour pools behind content, so glass has something to refract. Turned off by the "Plain" background.
struct AmbientBackground: View {
    @AppStorage(AppearanceKey.background) private var background = BackgroundChoice.ambient
    @AppStorage(AppearanceKey.accent) private var accent = AccentChoice.system
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if background == .ambient {
                let strength = scheme == .dark ? 0.22 : 0.16
                GeometryReader { geo in
                    ZStack {
                        RadialGradient(colors: [accent.resolved.opacity(strength), .clear], center: .topLeading,
                                       startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.7)
                        RadialGradient(colors: [Color.purple.opacity(strength * 0.8), .clear], center: .bottomTrailing,
                                       startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.6)
                        RadialGradient(colors: [Color.cyan.opacity(strength * 0.6), .clear], center: .topTrailing,
                                       startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.45)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: Root modifiers

/// Applies theme and accent from settings. Used on every scene's root view.
struct AppearanceRoot: ViewModifier {
    @AppStorage(AppearanceKey.theme) private var theme = ThemeChoice.system
    @AppStorage(AppearanceKey.accent) private var accent = AccentChoice.system

    func body(content: Content) -> some View {
        content
            .tint(accent.color)
            .preferredColorScheme(theme.colorScheme)
    }
}

// MARK: App icon

enum AppIcon {
    /// The icon artwork. In the .app it is the bundle icon; under `swift run` it comes from the resource bundle.
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") { return NSImage(contentsOf: url) }
        let executableDirectory = Bundle.main.bundleURL
        for name in ["fpga-bridge_FPGABridgeApp.bundle"] {
            let candidates = [executableDirectory.appendingPathComponent(name),
                              Bundle.main.resourceURL?.appendingPathComponent(name)].compactMap { $0 }
            for url in candidates {
                if let bundle = Bundle(url: url), let image = bundle.url(forResource: "AppIcon", withExtension: "png") {
                    return NSImage(contentsOf: image)
                }
            }
        }
        return nil
    }()
}

/// The icon as a view, with a gradient fallback if the artwork is missing.
struct AppIconView: View {
    var size: CGFloat = 64

    var body: some View {
        if let image = AppIcon.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "cpu")
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }
}
