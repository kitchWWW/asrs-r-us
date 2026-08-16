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
        // Any of these means the user has taken the box over; see `followsBottom`.
        textView.onUserTakeover = { [weak coordinator = context.coordinator] in
            coordinator?.followsBottom = false
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CaretTextView else { return }
        // A cleared box is a fresh session, so start following again -- losing
        // the behaviour for one edit should not lose it for every rewrite after.
        if text.isEmpty { context.coordinator.followsBottom = true }
        // Only write when it actually differs: assigning `string` resets the
        // insertion point, which would fight the user mid-keystroke.
        if textView.string != text {
            textView.string = text
            if context.coordinator.followsBottom {
                // Lay out before scrolling. The text was replaced a moment ago
                // and scrolling against stale layout stops short of the real
                // end, leaving the newest line just out of sight.
                if let layoutManager = textView.layoutManager,
                   let container = textView.textContainer {
                    layoutManager.ensureLayout(for: container)
                }
                textView.scrollToEndOfDocument(nil)
            }
        }
        textView.placeholder = placeholder
        textView.showsPendingCaret = showsPendingCaret
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        /// Whether the box still auto-scrolls to show the newest text.
        ///
        /// On by default so a long rewrite streaming in stays readable without
        /// being chased. It switches off the moment the user does anything in
        /// here -- typing, clicking in, or scrolling by hand -- because yanking
        /// the view back to the bottom while someone is reading or editing
        /// higher up is worse than not following at all. Lives on the
        /// coordinator so it survives the many `updateNSView` passes.
        var followsBottom = true

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Only user edits land here -- assigning `string` in `updateNSView`
            // does not notify the delegate -- so this is a genuine takeover.
            followsBottom = false
            text.wrappedValue = textView.string
        }
    }
}

/// Draws the blinking "more is coming" caret after the last character, plus the
/// placeholder, both positioned from the same layout the text itself uses.
final class CaretTextView: NSTextView {

    var placeholder: String = "" { didSet { needsDisplay = true } }

    /// Called when the user clicks in, focuses, or scrolls this box by hand.
    var onUserTakeover: (() -> Void)?

    var showsPendingCaret = false {
        didSet {
            guard showsPendingCaret != oldValue else { return }
            showsPendingCaret ? startBlinking() : stopBlinking()
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        onUserTakeover?()
        super.mouseDown(with: event)
    }

    /// Scrolling up by hand and being dragged straight back down is the exact
    /// thing auto-following gets wrong, so treat it as a takeover too.
    override func scrollWheel(with event: NSEvent) {
        onUserTakeover?()
        super.scrollWheel(with: event)
    }

    /// Focus only ever arrives here from the user -- nothing in the panel
    /// focuses this box programmatically.
    override func becomeFirstResponder() -> Bool {
        onUserTakeover?()
        return super.becomeFirstResponder()
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
