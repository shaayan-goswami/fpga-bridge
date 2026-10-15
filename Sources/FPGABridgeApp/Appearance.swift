import AppKit
import SwiftUI

// MARK: Settings keys and choices

/// The app is monochrome: black, gray and white, following light or dark mode. Colour is only used where it carries
/// meaning (run status, errors, warnings, failed timing).
enum AppearanceKey {
    static let theme = "appearance.theme"
    static let glass = "appearance.glass"
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

enum GlassChoice: String, CaseIterable, Identifiable {
    case frosted, clear, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .frosted: "Frosted"
        case .clear: "Clear"
        case .off: "Off (solid)"
        }
    }
}

/// Neutral greys used for highlights and the control tint.
enum Mono {
    /// Tint for controls: graphite, readable in both modes.
    static let tint = Color(nsColor: .systemGray)
}

// MARK: Glass surfaces

extension View {
    /// A Liquid Glass surface (macOS 26+), following the glass setting. Falls back to a material on older systems
    /// and to a solid panel when glass is off.
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
    @AppStorage(AppearanceKey.glass) private var glass = GlassChoice.frosted

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
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: Backdrop

/// The flat window background behind glass panels: white in light mode, near-black in dark mode.
struct Backdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    }
}

/// A plain, grey text button for secondary actions ("Edit", "Report", "Show All"). macOS link buttons are always
/// blue, which would break the monochrome look.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
    }
}

// MARK: Root modifier

/// Applies the theme and the monochrome control tint. Used on every scene's root view.
struct AppearanceRoot: ViewModifier {
    @AppStorage(AppearanceKey.theme) private var theme = ThemeChoice.system

    func body(content: Content) -> some View {
        content
            .tint(Mono.tint)
            .preferredColorScheme(theme.colorScheme)
    }
}

// MARK: App icon

enum AppIcon {
    /// Light and dark renderings of AppIcon.icon (made with Icon Composer). In the .app they sit in Resources; under
    /// `swift run` they come from SwiftPM's resource bundle.
    static let light = load("AppIcon-Light")
    static let dark = load("AppIcon-Dark")

    private static func load(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") { return NSImage(contentsOf: url) }
        let bundleName = "fpga-bridge_FPGABridgeApp.bundle"
        let candidates = [Bundle.main.bundleURL.appendingPathComponent(bundleName),
                          Bundle.main.resourceURL?.appendingPathComponent(bundleName)].compactMap { $0 }
        for url in candidates {
            if let bundle = Bundle(url: url), let image = bundle.url(forResource: name, withExtension: "png") {
                return NSImage(contentsOf: image)
            }
        }
        return nil
    }

    static func image(dark isDark: Bool) -> NSImage? { isDark ? (dark ?? light) : (light ?? dark) }

    /// The icon with macOS's standard margin (an 824-point body on a 1024-point canvas), for the Dock under
    /// `swift run`. Icon Composer's export fills the whole canvas, which would draw larger than other Dock icons.
    /// The packaged app doesn't need this: the system draws its icon from Assets.car.
    static func dockImage(dark isDark: Bool) -> NSImage? {
        guard let artwork = image(dark: isDark) else { return nil }
        let canvas = NSSize(width: 1024, height: 1024)
        let inset = (1024 - 824) / 2.0
        return NSImage(size: canvas, flipped: false) { _ in
            artwork.draw(in: NSRect(x: inset, y: inset, width: 824, height: 824))
            return true
        }
    }
}

/// The app icon, matching the current light or dark appearance.
struct AppIconView: View {
    var size: CGFloat = 64
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image = AppIcon.image(dark: scheme == .dark) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "cpu")
                .font(.system(size: size * 0.45, weight: .medium))
                .frame(width: size, height: size)
                .glassSurface(cornerRadius: size * 0.22)
        }
    }
}
