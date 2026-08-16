import AppKit
import SwiftUI

/// The profile prompt box, with spell checking turned on.
///
/// A SwiftUI `TextEditor` cannot do this: macOS leaves continuous spell
/// checking off for it and exposes no modifier to turn it on, so the prompt
/// gets an `NSTextView` of its own instead. The red underline is the whole
/// point -- a prompt is prose the model reads literally, and a typo in it is
/// invisible from the outside until the rewrites start coming back subtly
/// wrong.
///
/// Every *automatic* substitution is deliberately off. Autocorrect, smart
/// quotes, and smart dashes would rewrite the prompt as it is typed, and this
/// prompt is full of characters that have to survive exactly as written: the
/// straight quotes its punctuation rules quote, the `--` it uses for dashes,
/// the `->` in its examples. Flagging a mistake is wanted here; silently
/// making one is not.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor

        textView.isContinuousSpellCheckingEnabled = true
        // Spelling only. Grammar underlines are noisy on prompt prose, which is
        // full of fragments and bullet lists by design.
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

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
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only write when it differs: assigning `string` resets the insertion
        // point, which would fight the user mid-keystroke.
        guard textView.string != text else { return }
        textView.string = text
        // Continuous checking is driven by editing, so text that arrives any
        // other way -- switching profiles, "Reset prompt", the first load --
        // lands unmarked until this kicks a pass off by hand.
        textView.checkTextInDocument(nil)
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
