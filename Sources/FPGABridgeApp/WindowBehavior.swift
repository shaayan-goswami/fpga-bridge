import AppKit
import SwiftUI

/// Whether the app's window is fullscreen. Glass has no desktop to show through there, so surfaces go solid.
/// A single observer on the notification center, rather than one per view: views inside `containerBackground`
/// didn't reliably hear the notifications.
@MainActor
final class FullScreenState: ObservableObject {
    static let shared = FullScreenState()

    @Published private(set) var isFullScreen = false

    private init() {
        let center = NotificationCenter.default
        // "Will", so the surface is already solid when the animation starts and no glass rim flashes.
        center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FullScreenState.shared.isFullScreen = true }
        }
        center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FullScreenState.shared.isFullScreen = false }
        }
        isFullScreen = NSApp?.windows.contains { $0.styleMask.contains(.fullScreen) } ?? false
    }
}

extension View {
    /// Allows or forbids fullscreen for the window this view is in. The home screen can't go fullscreen, a project can,
    /// and a window that is fullscreen when it becomes forbidden leaves fullscreen.
    func allowsFullScreen(_ allowed: Bool) -> some View {
        background(FullScreenPolicy(allowed: allowed))
    }
}

private struct FullScreenPolicy: NSViewRepresentable {
    let allowed: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The view isn't in a window yet during the first update.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if allowed {
                window.collectionBehavior.remove(.fullScreenNone)
                window.collectionBehavior.insert(.fullScreenPrimary)
            } else {
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
        }
    }
}
