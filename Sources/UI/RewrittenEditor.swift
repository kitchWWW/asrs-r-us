import AppKit
import SwiftUI

/// The editable "Rewritten" box.
///
/// This is a hand-rolled `NSTextView` rather than a SwiftUI `TextEditor`
/// because the pending caret has to sit exactly after the last character.
/// Overlaying a caret on a `TextEditor` means guessing its internal text
/// container insets and re-deriving line layout, which drifts out of alignment.
/// Owning the text view lets the caret be positioned from the layout manager
/// itself, and lets the placeholder use the identical origin so the two can
/// never disagree.
struct RewrittenEditor: NSViewRepresentable {
    @Binding var text: String
    var showsPendingCaret: Bool
    var placeholder: String

    static let font = NSFont.systemFont(ofSize: 13)
    static let inset = NSSize(width: 5, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CaretTextView()
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textContainerInset = Self.inset
        textView.placeholder = placeholder
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CaretTextView else { return }
        // Only write when it actually differs: assigning `string` resets the
        // insertion point, which would fight the user mid-keystroke.
        if textView.string != text {
            textView.string = text
        }
        textView.placeholder = placeholder
        textView.showsPendingCaret = showsPendingCaret
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Draws the blinking "more is coming" caret after the last character, plus the
/// placeholder, both positioned from the same layout the text itself uses.
final class CaretTextView: NSTextView {

    var placeholder: String = "" { didSet { needsDisplay = true } }

    var showsPendingCaret = false {
        didSet {
            guard showsPendingCaret != oldValue else { return }
            showsPendingCaret ? startBlinking() : stopBlinking()
            needsDisplay = true
        }
    }

    private var blinkOn = true
    private var blinkTimer: Timer?
    /// Roughly the system text-cursor blink interval.
    private let blinkInterval: TimeInterval = 0.53

    private func startBlinking() {
        blinkOn = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: blinkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkOn.toggle()
            self.needsDisplay = true
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
    }

    deinit { blinkTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if string.isEmpty, !placeholder.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? RewrittenEditor.font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            // Same origin the first glyph would occupy, so the placeholder and
            // real text sit on exactly the same baseline.
            placeholder.draw(at: NSPoint(x: textContainerInset.width,
                                         y: textContainerInset.height),
                             withAttributes: attributes)
        }

        guard showsPendingCaret, blinkOn, let rect = pendingCaretRect() else { return }
        NSColor.controlAccentColor.setFill()
        rect.fill()
    }

    /// Position immediately after the final glyph, from the layout manager --
    /// so it follows line wraps and font metrics without any hard-coded offsets.
    private func pendingCaretRect() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let width: CGFloat = 2
        let lineHeight = layoutManager.defaultLineHeight(for: font ?? RewrittenEditor.font)

        guard !string.isEmpty else {
            return NSRect(x: textContainerInset.width, y: textContainerInset.height,
                          width: width, height: lineHeight)
        }

        let lastCharacter = NSRange(location: (string as NSString).length - 1, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lastCharacter,
                                                  actualCharacterRange: nil)
        var bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return NSRect(
            x: bounds.maxX + textContainerInset.width + 1,
            y: bounds.minY + textContainerInset.height,
            width: width,
            height: bounds.height > 0 ? bounds.height : lineHeight
        )
    }
}
