import AppKit
import FPGABridgeCore
import SwiftUI

/// The zoom and scroll position of a drawing (the package or the die), in the same terms as the schematic's: a model
/// point p is drawn at p × scale − offset.
struct CanvasViewport: Equatable {
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
    var size: CGSize = .zero

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    func toModel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x + offset.x) / scale, y: (p.y + offset.y) / scale) }

    mutating func zoom(by factor: CGFloat, about point: CGPoint, limits: ClosedRange<CGFloat> = 0.1...12) {
        let new = min(max(scale * factor, limits.lowerBound), limits.upperBound)
        let model = toModel(point)
        scale = new
        offset = CGPoint(x: model.x * new - point.x, y: model.y * new - point.y)
    }

    mutating func pan(_ d: CGSize) { offset.x -= d.width; offset.y -= d.height }

    mutating func fit(_ rect: CGRect, maxScale: CGFloat) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        scale = min(size.width / rect.width, size.height / rect.height, maxScale)
        offset = CGPoint(x: rect.midX * scale - size.width / 2, y: rect.midY * scale - size.height / 2)
    }
}

struct ChipMenuItem {
    let title: String
    var enabled = true
    let action: () -> Void
}

/// The mouse handling over a chip drawing: drag to scroll (or, from a placed port, to move the port), pinch or ⌘-scroll
/// to zoom, click to select, right-click for a menu, and drops of port names dragged from the ports list.
struct ChipCanvasInteraction: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onClick: (CGPoint, Bool, Int) -> Void
    var onHover: (CGPoint?) -> Void
    var menu: (CGPoint) -> [ChipMenuItem] = { _ in [] }
    /// Whether a press here picks something up (a placed port) rather than scrolling.
    var canDrag: (CGPoint) -> Bool = { _ in false }
    /// Where a picked-up port is being dragged, nil when the drag ends.
    var onDragMove: (CGPoint?) -> Void = { _ in }
    var onDragEnd: (CGPoint) -> Void = { _ in }
    /// A port name dragged in from elsewhere: dropped at a point. Returns whether it was taken.
    var onDropName: (String, CGPoint) -> Bool = { _, _ in false }

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.registerForDraggedTypes([.string])
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.owner = self
    }

    final class InteractionView: NSView {
        var owner: ChipCanvasInteraction?
        private var pressAt: CGPoint?
        private var moved = false
        private var draggingPort = false
        private var actions: [() -> Void] = []

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            let p = point(event)
            pressAt = p
            moved = false
            draggingPort = owner?.canDrag(p) ?? false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressAt else { return }
            let now = point(event)
            if !moved, hypot(now.x - start.x, now.y - start.y) < 3 { return }
            moved = true
            if draggingPort {
                owner?.onDragMove(now)
                NSCursor.closedHand.set()
            } else {
                owner?.onPan(CGSize(width: now.x - start.x, height: now.y - start.y))
                pressAt = now
                NSCursor.closedHand.set()
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressAt = nil; draggingPort = false }
            if moved {
                NSCursor.arrow.set()
                if draggingPort {
                    owner?.onDragMove(nil)
                    owner?.onDragEnd(point(event))
                }
                return
            }
            let extend = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
            owner?.onClick(point(event), extend, event.clickCount)
        }

        override func mouseMoved(with event: NSEvent) { owner?.onHover(point(event)) }
        override func mouseExited(with event: NSEvent) { owner?.onHover(nil) }

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                owner?.onZoom(exp(event.scrollingDeltaY * 0.01), point(event))
            } else {
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
                owner?.onPan(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            }
        }

        override func magnify(with event: NSEvent) { owner?.onZoom(1 + event.magnification, point(event)) }

        override func rightMouseDown(with event: NSEvent) {
            guard let items = owner?.menu(point(event)), !items.isEmpty else { return }
            let menu = NSMenu()
            actions = items.map(\.action)
            for (k, item) in items.enumerated() {
                if item.title == "-" { menu.addItem(.separator()); continue }
                let entry = NSMenuItem(title: item.title, action: item.enabled ? #selector(choose(_:)) : nil, keyEquivalent: "")
                entry.target = self
                entry.tag = k
                entry.isEnabled = item.enabled
                menu.addItem(entry)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func choose(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }

        // MARK: Drops from the ports list

        private func dropPoint(_ sender: NSDraggingInfo) -> CGPoint { convert(sender.draggingLocation, from: nil) }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.onDragMove(dropPoint(sender))
            return .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { owner?.onDragMove(nil) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            owner?.onDragMove(nil)
            guard let name = sender.draggingPasteboard.string(forType: .string) else { return false }
            return owner?.onDropName(name, dropPoint(sender)) ?? false
        }
    }
}

/// A floating line of text over a drawing: what is under the pointer, or a notice.
struct CanvasCaption: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .allowsHitTesting(false)
    }
}

/// What a view of the chip shows when the part's data isn't on this Mac yet: why, and the button that gets it.
struct PartDataMissing: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chip: ChipViews
    let part: String
    let window: String

    var body: some View {
        ContentUnavailableView {
            Label("\(window) data for \(part.isEmpty ? "this part" : part)", systemImage: "cpu")
        } description: {
            switch chip.load(of: part) {
            case .loading:
                Text("Asking Vivado on the build machine… This takes about a minute, once per part.")
            case .failed(let message):
                Text(message)
            case .idle:
                Text(chip.backend.canFetch
                     ? "The package pins, I/O banks and die layout come from Vivado once per part and are then kept on this Mac, so this works with the build machine asleep."
                     : "The package pins, I/O banks and die layout come from Vivado once per part. \(NoBuildMachine.message)")
            }
        } actions: {
            if chip.load(of: part) == .loading {
                ProgressView().controlSize(.small)
            } else {
                Button("Get Part Data from Vivado") { chip.fetch(part) }
                    .disabled(!chip.backend.canFetch || part.isEmpty)
            }
        }
        .background(Theme.surface)
    }
}
