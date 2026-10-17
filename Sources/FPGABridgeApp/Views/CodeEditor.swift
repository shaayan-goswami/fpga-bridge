import AppKit
import FPGABridgeCore
import SwiftUI

/// An editable source view: line numbers, syntax colors, undo/redo, find (⌘F), auto-indent and comment toggling.
/// The text view owns the text while you type; `text` is updated on every change so unsaved edits survive
/// switching tabs.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: HDLLanguage
    var fontSize: CGFloat
    var showLineNumbers: Bool
    /// Move the cursor into the editor when it first appears.
    var focusOnAppear = true
    /// Called with the caret's UTF-16 offset whenever it moves.
    var onCaretMove: ((Int) -> Void)?
    /// Where to put the caret when the editor opens, e.g. where it was last time.
    var initialCaret: Int?
    /// False for a read-only view, such as the Language Templates preview.
    var isEditable = true
    /// A range to select and scroll to, e.g. from Go To Source. Applied once per token.
    var reveal: EditorReveal?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorContainer {
        let textView = CodeTextView()
        textView.language = language
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.nsSurface
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // No wrapping: long lines scroll sideways, as in Vivado.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.nsSurface
        scroll.contentView.postsBoundsChangedNotifications = true
        // The window's toolbar would otherwise push the text down by its own height.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        let container = EditorContainer(scroll: scroll, gutter: LineNumberGutter(textView: textView, scroll: scroll))
        context.coordinator.textView = textView
        context.coordinator.apply(settings: self, to: textView, container: container)
        textView.string = text
        if let caret = initialCaret {
            let location = min(caret, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            // The text isn't laid out yet; scroll once it is.
            DispatchQueue.main.async { textView.scrollRangeToVisible(NSRange(location: location, length: 0)) }
        }
        context.coordinator.highlight(textView)
        context.coordinator.applyReveal(reveal, to: textView)
        if focusOnAppear {
            DispatchQueue.main.async { container.window?.makeFirstResponder(textView) }
        }
        return container
    }

    func updateNSView(_ container: EditorContainer, context: Context) {
        guard let textView = container.scroll.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        // Only replace the text when it changed from outside (not while the user is typing).
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        context.coordinator.apply(settings: self, to: textView, container: container)
        context.coordinator.highlight(textView)
        context.coordinator.applyReveal(reveal, to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        private var lastStyle: String?

        private var lastRevealToken: Int?

        init(_ parent: CodeEditor) { self.parent = parent }

        /// Selects and scrolls to a range the first time its token is seen, and flashes it like Find does.
        func applyReveal(_ reveal: EditorReveal?, to textView: CodeTextView) {
            guard let reveal, reveal.token != lastRevealToken else { return }
            lastRevealToken = reveal.token
            let length = (textView.string as NSString).length
            let location = min(reveal.range.location, length)
            let range = NSRange(location: location, length: min(reveal.range.length, length - location))
            textView.setSelectedRange(range)
            // The text may not be laid out yet; scroll and flash once it is.
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(range)
                if range.length > 0 { textView.showFindIndicator(for: range) }
            }
        }

        func apply(settings: CodeEditor, to textView: CodeTextView, container: EditorContainer) {
            textView.language = settings.language
            textView.isEditable = settings.isEditable
            container.showsGutter = settings.showLineNumbers
            container.gutter.fontSize = settings.fontSize
            textView.baseFont = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? CodeTextView else { return }
            parent.onCaretMove?(textView.selectedRange().location)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        /// Return keeps the indentation, Tab inserts spaces.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let code = textView as? CodeTextView else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let ns = code.string as NSString
                let caret = code.selectedRange().location
                let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
                let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
                let indent = AutoIndent.indentation(afterLine: before, language: code.language)
                code.insertText("\n" + indent, replacementRange: code.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)):
                code.insertText("    ", replacementRange: code.selectedRange())
                return true
            default:
                return false
            }
        }

        func highlight(_ textView: CodeTextView) {
            let font = textView.baseFont
            let key = "\(textView.string.hashValue)-\(textView.language)-\(font.pointSize)-\(textView.effectiveAppearance.name.rawValue)"
            guard key != lastStyle else { return }
            lastStyle = key

            guard let storage = textView.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88)], range: whole)
            for token in SyntaxHighlighter.tokens(in: storage.string, language: textView.language) where NSMaxRange(token.range) <= storage.length {
                storage.addAttributes(SyntaxStyle.attributes(for: token.kind, size: font.pointSize), range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }
    }
}

/// How each kind of token is colored.
enum SyntaxStyle {
    static func attributes(for kind: SyntaxToken.Kind, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        switch kind {
        case .keyword: return [.foregroundColor: Accent.sourceNS, .font: bold]
        case .number: return [.foregroundColor: NSColor.labelColor]
        case .directive: return [.foregroundColor: Accent.remoteNS, .font: bold]
        case .string: return [.foregroundColor: Accent.constraintNS]
        case .comment: return [.foregroundColor: NSColor.secondaryLabelColor, .obliqueness: 0.15]
        }
    }
}

/// The text view. It adds Toggle Comment, which the Edit menu reaches through the responder chain.
final class CodeTextView: NSTextView {
    var language: HDLLanguage = .verilog
    var baseFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) {
        didSet { if baseFont != oldValue { font = baseFont } }
    }

    @objc func toggleComment(_ sender: Any?) {
        let result = CommentToggler.toggle(string, selection: selectedRange(), language: language)
        guard result.text != string else { return }
        // Replace only the lines that changed, through the text system so the change is undoable.
        guard shouldChangeText(in: result.replacedRange, replacementString: result.replacement) else { return }
        textStorage?.replaceCharacters(in: result.replacedRange, with: result.replacement)
        didChangeText()
        setSelectedRange(result.selection)
    }

    /// Shift-Tab outdents every selected line by up to four spaces.
    override func insertBacktab(_ sender: Any?) {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let block = ns.substring(with: lines)
        let outdented = block.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(min(4, line.prefix { $0 == " " }.count)))
        }.joined(separator: "\n")
        guard outdented != block, shouldChangeText(in: lines, replacementString: outdented) else { return }
        textStorage?.replaceCharacters(in: lines, with: outdented)
        didChangeText()
        setSelectedRange(NSRange(location: lines.location, length: (outdented as NSString).length))
    }
}

/// Holds the line-number gutter next to the scroll view. A plain view rather than NSRulerView, which laid itself out
/// above the editor, through the window's toolbar.
final class EditorContainer: NSView {
    let scroll: NSScrollView
    let gutter: LineNumberGutter
    var showsGutter = true {
        didSet {
            gutter.isHidden = !showsGutter
            needsLayout = true
        }
    }

    init(scroll: NSScrollView, gutter: LineNumberGutter) {
        self.scroll = scroll
        self.gutter = gutter
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scroll)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let width = showsGutter ? LineNumberGutter.width : 0
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}

/// Line numbers in the left margin. Flipped, like the text view, so a line's y position is the same in both.
final class LineNumberGutter: NSView {
    static let width: CGFloat = 46

    private weak var textView: NSTextView?
    var fontSize: CGFloat = 12.5 { didSet { if fontSize != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    init(textView: NSTextView, scroll: NSScrollView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.nsSurface.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, fontSize - 1.5), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // A line's y in the text view, minus how far the text has scrolled, is its y here.
        func draw(_ number: Int, fragment: NSRect) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + textView.textContainerInset.height - visible.minY + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 8, y: y), withAttributes: attributes)
        }

        // The first visible line is one more than the number of line breaks above it.
        var number = 1
        // Count line breaks the way lineRange(for:) sees them: a CR LF from Windows is one Character that isn't "\n".
        if chars.location > 0 { number += text.substring(to: chars.location).filter(\.isNewline).count }

        var index = chars.location
        while index < text.length, index <= NSMaxRange(chars) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            draw(number, fragment: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
            number += 1
            index = NSMaxRange(lineRange)
        }
        // The empty line after a final newline, or an empty file.
        if text.length == 0 || text.character(at: text.length - 1) == 10 {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { draw(number, fragment: extra) }
        }
    }
}
