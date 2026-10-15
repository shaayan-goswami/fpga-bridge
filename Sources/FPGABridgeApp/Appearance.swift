import AppKit
import SwiftUI

// MARK: Settings keys and choices

/// The app is monochrome: black, gray and white, following light or dark mode. Colour is only used where it carries
/// meaning (run status, errors, warnings, failed timing).
enum AppearanceKey {
    static let theme = "appearance.theme"
    static let glass = "appearance.glass"
    static let accents = "appearance.accents"
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

/// Muted accents, each with one meaning. They only colour small things (icons, dots, thin bars, command text), never
/// large areas, and can be turned off in Settings for a fully grey app. Each has a lighter shade for dark mode.
enum Accent {
    static var enabled: Bool { UserDefaults.standard.object(forKey: AppearanceKey.accents) as? Bool ?? true }

    /// Done, timing met.
    static var success: Color { make(light: 0x4F8A63, dark: 0x86B596) }
    /// Warnings, out-of-date runs, utilization over 70%.
    static var warning: Color { make(light: 0xA87A2E, dark: 0xD4AC64) }
    /// Errors, failed runs, failed timing.
    static var error: Color { make(light: 0xB5504A, dark: 0xDB857F) }
    /// Something in progress, and Tcl commands in the console.
    static var active: Color { make(light: 0x4A6F9E, dark: 0x8CABD1) }
    /// Work that happens on the build machine in Vivado (synthesis, implementation, bitstream).
    static var remote: Color { make(light: 0x76689C, dark: 0xA99DCC) }
    /// Design sources and modules.
    static var source: Color { make(light: 0x5B7896, dark: 0x97B0CA) }
    /// Constraint files.
    static var constraint: Color { make(light: 0x9A6B4F, dark: 0xC69C81) }
    /// Simulation sources.
    static var simulation: Color { make(light: 0x4E8A86, dark: 0x86B9B4) }

    struct Entry: Identifiable {
        let name: String
        let color: Color
        var id: String { name }
    }

    /// For the legend in Settings.
    static var legend: [Entry] {
        [Entry(name: "Done, timing met", color: success), Entry(name: "Warning, out-of-date", color: warning),
         Entry(name: "Error, failed", color: error), Entry(name: "Running, Tcl commands", color: active),
         Entry(name: "Runs on the build machine", color: remote), Entry(name: "Design sources", color: source),
         Entry(name: "Constraints", color: constraint), Entry(name: "Simulation sources", color: simulation)]
    }

    /// Computed each time (not cached) so turning accents off in Settings takes effect when views are rebuilt.
    private static func make(light: UInt32, dark: UInt32) -> Color {
        let on = enabled
        return Color(nsColor: NSColor(name: nil) { appearance in
            guard on else { return .secondaryLabelColor }
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
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
    @AppStorage(AppearanceKey.accents) private var accents = true

    func body(content: Content) -> some View {
        content
            .tint(Mono.tint)
            .preferredColorScheme(theme.colorScheme)
            // Rebuild when accents are switched, so every accent colour is resolved again.
            .id(accents)
    }
}

// MARK: App icon

/// The system's Icon & widget style (System Settings > Appearance): Default, Dark, Clear or Tinted. The app icon
/// follows this, not the window's light or dark mode.
enum IconStyle: Equatable {
    case regularLight, regularDark, clearLight, clearDark, tintedLight, tintedDark

    /// Read from the global `AppleIconAppearanceTheme` preference; absent means Default.
    static var current: IconStyle {
        switch UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") {
        case "RegularDark": .regularDark
        case "ClearLight": .clearLight
        case "ClearDark": .clearDark
        case "TintedLight": .tintedLight
        case "TintedDark": .tintedDark
        default: .regularLight
        }
    }

    /// The pre-rendered image for this style. Tinted uses the user's own tint colour, which can't be pre-rendered,
    /// so it shows the neutral Clear rendering; the packaged app's Dock icon gets the real tinted one from macOS.
    var resourceName: String {
        switch self {
        case .regularLight: "AppIcon-Default"
        case .regularDark: "AppIcon-Dark"
        case .clearLight, .tintedLight: "AppIcon-ClearLight"
        case .clearDark, .tintedDark: "AppIcon-ClearDark"
        }
    }
}

/// Keeps the current icon style, re-reading it whenever the app comes to the front (after the user changes it).
@MainActor
final class IconStyleObserver: ObservableObject {
    static let shared = IconStyleObserver()
    @Published private(set) var style = IconStyle.current
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { IconStyleObserver.shared.refresh() }
        }
    }

    func refresh() {
        let latest = IconStyle.current
        guard latest != style else { return }
        style = latest
        AppIcon.updateDockIcon()
    }
}

enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    /// Renderings of AppIcon.icon (made with Icon Composer). In the .app they sit in Resources; under `swift run`
    /// they come from SwiftPM's resource bundle.
    static func image(for style: IconStyle) -> NSImage? {
        if let cached = cache[style.resourceName] { return cached }
        let image = load(style.resourceName) ?? load("AppIcon-Default")
        cache[style.resourceName] = image
        return image
    }

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

    /// Under `swift run` there is no app bundle, so set the Dock icon by hand, with macOS's standard margin (an
    /// 824-point body on a 1024-point canvas; Icon Composer's export fills the whole canvas). The packaged app
    /// leaves this to the system, which draws it from Assets.car in every style.
    @MainActor
    static func updateDockIcon() {
        guard Bundle.main.bundleIdentifier == nil, let artwork = image(for: IconStyle.current) else { return }
        let inset = (1024 - 824) / 2.0
        NSApp.applicationIconImage = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            artwork.draw(in: NSRect(x: inset, y: inset, width: 824, height: 824))
            return true
        }
    }
}

/// The app icon in the system's current Icon & widget style.
struct AppIconView: View {
    var size: CGFloat = 64
    @ObservedObject private var iconStyle = IconStyleObserver.shared

    var body: some View {
        if let image = AppIcon.image(for: iconStyle.style) {
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
