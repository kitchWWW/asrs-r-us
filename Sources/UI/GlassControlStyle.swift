import SwiftUI

/// Shared look for every control in the panel.
///
/// The stock `.glass` / `.glassProminent` button styles pick their own shape
/// and metrics, which left the buttons and the dropdown pills visibly
/// mismatched -- different heights, and a tighter corner radius than the
/// window or the text panes. Owning the style keeps one radius and one height
/// across the whole control set.
struct GlassControlStyle: ButtonStyle {
    /// Fill colour for a prominent button; nil is plain glass.
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    /// The Use button while the rewriter still owes it something: a request in
    /// flight, or words heard since the last one landed. Grey rather than
    /// disabled, because Enter works exactly the same either way -- this only
    /// says whether what is on screen is the model's last word on the
    /// transcript, or a version it is about to replace.
    static let waitingTint = Color(white: 0.42)

    /// One radius for every rounded surface in the panel -- window, text
    /// panes, buttons and dropdowns -- so nothing reads as a different family.
    static let cornerRadius: CGFloat = 12
    static let height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
            .opacity(opacity(pressed: configuration.isPressed))
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            // Blue <-> grey as the rewriter catches up, without a flash.
            .animation(.easeInOut(duration: 0.25), value: tint)
    }

    private var glass: Glass {
        guard let tint else { return .regular }
        return .regular.tint(tint)
    }

    private var foreground: Color {
        tint == nil ? .primary : .white
    }

    private func opacity(pressed: Bool) -> Double {
        if !isEnabled { return 0.45 }
        return pressed ? 0.72 : 1
    }
}

extension ButtonStyle where Self == GlassControlStyle {
    static var glassControl: GlassControlStyle { GlassControlStyle() }
    static var glassControlProminent: GlassControlStyle { GlassControlStyle(tint: .accentColor) }
    /// Prominent, but greyed: the action still works, the result is not final.
    static var glassControlWaiting: GlassControlStyle {
        GlassControlStyle(tint: GlassControlStyle.waitingTint)
    }
}
