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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
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

        let ruler = LineNumberRuler(scrollView: scroll, textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true

        context.coordinator.textView = textView
        context.coordinator.apply(settings: self, to: textView, scroll: scroll)
        textView.string = text
        context.coordinator.highlight(textView)
        if focusOnAppear {
            DispatchQueue.main.async { scroll.window?.makeFirstResponder(textView) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        // Only replace the text when it changed from outside (not while the user is typing).
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        context.coordinator.apply(settings: self, to: textView, scroll: scroll)
        context.coordinator.highlight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        private var lastStyle: String?

        init(_ parent: CodeEditor) { self.parent = parent }

        func apply(settings: CodeEditor, to textView: CodeTextView, scroll: NSScrollView) {
            textView.language = settings.language
            scroll.rulersVisible = settings.showLineNumbers
            (scroll.verticalRulerView as? LineNumberRuler)?.fontSize = settings.fontSize
            textView.baseFont = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
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
            let bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
            for token in SyntaxHighlighter.tokens(in: storage.string, language: textView.language) where NSMaxRange(token.range) <= storage.length {
                switch token.kind {
                case .keyword: storage.addAttributes([.foregroundColor: Accent.sourceNS, .font: bold], range: token.range)
                case .number: storage.addAttributes([.foregroundColor: NSColor.labelColor], range: token.range)
                case .directive: storage.addAttributes([.foregroundColor: Accent.remoteNS, .font: bold], range: token.range)
                case .string: storage.addAttributes([.foregroundColor: Accent.constraintNS], range: token.range)
                case .comment:
                    storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .obliqueness: 0.15], range: token.range)
                }
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
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
        // Replace through the text system so the change is undoable.
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: result.text) else { return }
        textStorage?.replaceCharacters(in: whole, with: result.text)
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

/// Line numbers in the left margin.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    var fontSize: CGFloat = 12.5 { didSet { if fontSize != oldValue { needsDisplay = true } } }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        Theme.nsSurface.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, fontSize - 1.5), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        func draw(_ number: Int, lineY: CGFloat, height: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = convert(NSPoint(x: 0, y: lineY), from: textView).y + (height - size.height) / 2
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 8, y: y), withAttributes: attributes)
        }

        // The first visible line is one more than the number of line breaks above it.
        var number = 1
        if chars.location > 0 { number += text.substring(to: chars.location).filter { $0 == "\n" }.count }

        var index = chars.location
        while index < text.length, index <= NSMaxRange(chars) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(number, lineY: fragment.minY + textView.textContainerInset.height, height: fragment.height)
            number += 1
            index = NSMaxRange(lineRange)
        }
        // The empty line after a final newline, or an empty file.
        if text.length == 0 || text.character(at: text.length - 1) == 10 {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { draw(number, lineY: extra.minY + textView.textContainerInset.height, height: extra.height) }
        }
    }
}
