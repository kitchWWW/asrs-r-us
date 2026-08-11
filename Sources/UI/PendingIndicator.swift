import SwiftUI

/// A soft, pulsing caret shown while speech has been captured that the visible
/// rewrite does not yet account for.
///
/// Its absence is the signal that matters: no caret means everything you have
/// said has been rewritten and you are clear to hit Enter.
///
/// Driven by `TimelineView` rather than a `@State` flag toggled in `onAppear`:
/// the view is inserted and removed constantly as work starts and finishes, and
/// a state-driven `repeatForever` animation is not reliably running by the time
/// a short-lived instance is on screen.
struct PendingIndicator: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 3.6) + 1) / 2      // 0...1
            Capsule()
                .fill(Color.primary)
                .frame(width: 3, height: 14)
                .blur(radius: 0.6)
                .opacity(0.22 + 0.68 * phase)
        }
        .frame(width: 3, height: 14)
        .accessibilityLabel("Rewriting in progress")
        .help("Still catching up with what you said — wait for this to clear before using the text.")
    }
}
