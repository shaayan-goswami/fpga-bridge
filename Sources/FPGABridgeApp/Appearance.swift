import AppKit
import SwiftUI

// MARK: Settings keys and choices

/// UserDefaults keys for the settings on the Appearance and Text Editor pages.
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
    /// Clear Liquid Glass on large surfaces (the window, the sidebar). The default.
    case liquid
    /// Stronger blur.
    case frosted
    case clear
    case off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liquid: "Liquid Glass"
        case .frosted: "Frosted"
        case .clear: "Clear"
        case .off: "Off (solid)"
        }
    }
}

/// Accent colors, each with one meaning. The light values were sampled from Vivado 2023.1 screenshots (run green
/// #4DBD33, error #F33321, critical warning #FCA602, link blue #0072FA, message link #00A6FD, hierarchy teal #58A6BB,
/// top-module green #3BBA6A, tool-icon navy #406294). The dark values are the same hues, lighter. Accents mark small
/// things only (icons, dots, thin bars, command text) and can be turned off in Settings.
enum Accent {
    static var enabled: Bool { UserDefaults.standard.object(forKey: AppearanceKey.accents) as? Bool ?? true }

    /// Done, timing met (Vivado's top-module green).
    static var success: Color { make(light: 0x3BBA6A, dark: 0x6FD394) }
    /// Warnings, out-of-date runs, utilization over 70% (Vivado's critical-warning amber).
    static var warning: Color { make(light: 0xFCA602, dark: 0xFFBE45) }
    /// Errors, failed runs, failed timing (Vivado's error red).
    static var error: Color { make(light: 0xF33321, dark: 0xFF6F60) }
    /// Something in progress, and Tcl commands in the console (Vivado's link blue).
    static var active: Color { make(light: 0x0072FA, dark: 0x5AA2FF) }
    /// Work that happens on the build machine in Vivado: the run icons (Vivado's green play button).
    static var remote: Color { make(light: 0x4DBD33, dark: 0x7BD566) }
    /// Design sources and modules (Vivado's hierarchy teal).
    static var source: Color { make(light: 0x58A6BB, dark: 0x8CC8D9) }
    /// Constraint files (Vivado's tool-icon navy).
    static var constraint: Color { make(light: 0x406294, dark: 0x7FA0D0) }
    /// Simulation sources (Vivado's message-link cyan).
    static var simulation: Color { make(light: 0x00A6FD, dark: 0x5CC8FF) }

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

    /// AppKit versions of the colors the code editor uses.
    static var sourceNS: NSColor { makeNS(light: 0x58A6BB, dark: 0x8CC8D9) }
    static var remoteNS: NSColor { makeNS(light: 0x4DBD33, dark: 0x7BD566) }
    static var constraintNS: NSColor { makeNS(light: 0x406294, dark: 0x7FA0D0) }

    /// Computed each time (not cached) so turning accents off in Settings takes effect when views are rebuilt.
    private static func make(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: makeNS(light: light, dark: dark))
    }

    private static func makeNS(light: UInt32, dark: UInt32) -> NSColor {
        let on = enabled
        return NSColor(name: nil) { appearance in
            guard on else { return .secondaryLabelColor }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Surface colors. Light mode uses the system's; dark mode is near-black rather than the system's dark grey.
enum Theme {
    private static func dynamic(light: NSColor, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : light
        }
    }

    /// The window and the home page.
    static let nsWindow = dynamic(light: .windowBackgroundColor, dark: 0x0A0B0F)
    /// Editors, the console, lists and tables: a step lighter than the window so panes read as panes.
    static let nsSurface = dynamic(light: .textBackgroundColor, dark: 0x0E0F14)
    /// The Flow Navigator and the Sources column.
    static let nsSidebar = dynamic(light: .underPageBackgroundColor, dark: 0x08090C)

    static let window = Color(nsColor: nsWindow)
    static let surface = Color(nsColor: nsSurface)
    static let sidebar = Color(nsColor: nsSidebar)
}

/// The grey tint for controls.
enum Mono {
    /// Graphite: readable in both light and dark mode.
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
    @AppStorage(AppearanceKey.glass) private var glass = GlassChoice.liquid

    func body(content: Content) -> some View {
        if glass == .off {
            content
                .background(shape.fill(Theme.surface))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(liquidGlass, in: shape)
        } else {
            content
                .background(glass == .frosted ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial), in: shape)
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

extension View {
    /// Floats the view on glass when selected and leaves it flat otherwise, for tab strips.
    @ViewBuilder
    func glassWhenSelected(_ selected: Bool) -> some View {
        if selected { glassSurface(Capsule(), interactive: true) } else { self }
    }
}

/// The fill for large surfaces such as the window and the sidebar: Liquid Glass (macOS 26+) tinted toward the window
/// color so text stays readable over a busy desktop, or a thin material on older systems, or a solid color when glass
/// is off. Frosted keeps the system's own, stronger blur and needs no tint.
struct GlassFill: View {
    var solid: Color = Theme.window
    @AppStorage(AppearanceKey.glass) private var glass = GlassChoice.liquid
    @Environment(\.colorScheme) private var scheme

    /// Dark glass in dark mode, light glass in light mode.
    private var tint: Color { scheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.6) }

    var body: some View {
        if glass == .off {
            solid
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(glass == .frosted ? .regular : Glass.clear.tint(tint), in: Rectangle())
        } else {
            Rectangle().fill(glass == .frosted ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial))
                .overlay(tint.opacity(0.5))
        }
    }
}

extension View {
    /// Puts a list or pane on a large glass surface instead of the system's sidebar background.
    func paneGlass(solid: Color = Theme.sidebar) -> some View {
        scrollContentBackground(.hidden).background { GlassFill(solid: solid) }
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
        Theme.window.ignoresSafeArea()
    }
}

extension View {
    /// The background of toolbars and pane headers: the system bar material in light mode, near-black in dark mode.
    func barBackground() -> some View { modifier(BarBackground()) }

    /// Lists and tables on the app's surface color instead of the system's.
    func surfaceBackground(_ color: Color = Theme.surface) -> some View {
        scrollContentBackground(.hidden).background(color)
    }
}

private struct BarBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if scheme == .dark {
            content.background(Theme.window)
        } else {
            content.background(.bar)
        }
    }
}

/// A grey text button for secondary actions ("Edit", "Report", "Show All"). The built-in link style uses the system
/// accent color, which would clash with the rest of the UI.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
    }
}

// MARK: Root modifier

/// Applies the theme and the control tint. Used on every scene's root view.
struct AppearanceRoot: ViewModifier {
    @AppStorage(AppearanceKey.theme) private var theme = ThemeChoice.system
    @AppStorage(AppearanceKey.accents) private var accents = true

    func body(content: Content) -> some View {
        content
            .tint(Mono.tint)
            .preferredColorScheme(theme.colorScheme)
            // Accent colors are read from UserDefaults, not observed, so rebuild the tree when the setting changes.
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

    /// The pre-rendered image for this style. Tinted depends on the user's tint color, which can't be pre-rendered, so
    /// it uses the neutral Clear rendering. The packaged app's Dock icon gets the real tinted one from macOS.
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
