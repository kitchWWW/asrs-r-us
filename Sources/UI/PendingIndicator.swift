import SwiftUI

/// A blinking caret that sits immediately after the last character of the
/// rewritten text while more of it is still on the way.
///
/// Positioned by laying out an invisible copy of the same text in the same
/// font, then concatenating the caret onto it: `Text + Text` is a single
/// paragraph, so the caret lands exactly where the next character would. That
/// is far more robust than trying to compute a glyph position by hand.
///
/// Its absence is the signal that matters: no caret means everything you have
/// said has been rewritten and you are clear to hit Enter.
struct InlineCaret: View {
    /// The text to mirror for layout. Rendered fully transparent.
    let text: String
    var font: Font = .system(size: 13)

    /// Roughly the macOS text-cursor blink interval.
    private let blinkInterval: TimeInterval = 0.53

    var body: some View {
        TimelineView(.periodic(from: .now, by: blinkInterval)) { context in
            let on = Int(
                context.date.timeIntervalSinceReferenceDate / blinkInterval
            ).isMultiple(of: 2)

            (Text(text).foregroundColor(.clear)
                + Text("\u{258F}").foregroundColor(.accentColor.opacity(on ? 1 : 0)))
                .font(font)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Rewriting in progress")
    }
}
