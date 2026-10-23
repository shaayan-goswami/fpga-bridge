import AppKit
import SwiftUI

/// A transparent layer over the traces that turns the mouse and trackpad into time-axis actions. SwiftUI has no
/// scroll-wheel or pinch events that give a position on macOS 14, so this is an NSView.
struct WaveformInteraction: NSViewRepresentable {
    /// A click or drag at x, in points from the left edge of the traces.
    var onCursor: (CGFloat) -> Void
    /// Horizontal scrolling, in points. Positive moves the window to later times.
    var onPan: (CGFloat) -> Void
    /// Pinching or Command-scrolling: a factor (> 1 zooms in) about x.
    var onZoom: (CGFloat, CGFloat) -> Void
    /// A key typed while the traces have focus (after a click); true if it was used. `M` adds a marker.
    var onKey: (String) -> Bool = { _ in false }

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.onCursor = onCursor
        view.onPan = onPan
        view.onZoom = onZoom
        view.onKey = onKey
    }

    final class InteractionView: NSView {
        var onCursor: (CGFloat) -> Void = { _ in }
        var onPan: (CGFloat) -> Void = { _ in }
        var onZoom: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onKey: (String) -> Bool = { _ in false }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func x(_ event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onCursor(x(event))
        }

        override func keyDown(with event: NSEvent) {
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            if plain, let key = event.charactersIgnoringModifiers?.lowercased(), onKey(key) { return }
            super.keyDown(with: event)
        }
        override func mouseDragged(with event: NSEvent) { onCursor(x(event)) }

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                onZoom(exp(event.scrollingDeltaY * 0.01), x(event))
            } else if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                onPan(-event.scrollingDeltaX)
            } else {
                super.scrollWheel(with: event)        // vertical: let the list of signals scroll
            }
        }

        override func magnify(with event: NSEvent) { onZoom(1 + event.magnification, x(event)) }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    }
}
