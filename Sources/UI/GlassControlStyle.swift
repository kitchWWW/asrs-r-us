import SwiftUI

/// Shared look for every control in the panel.
///
/// The stock `.glass` / `.glassProminent` button styles pick their own shape
/// and metrics, which left the buttons and the dropdown pills visibly
/// mismatched -- different heights, and a tighter corner radius than the
/// window or the text panes. Owning the style keeps one radius and one height
/// across the whole control set.
struct GlassControlStyle: ButtonStyle {
    var tinted = false
    @Environment(\.isEnabled) private var isEnabled

    static let cornerRadius: CGFloat = 12
    static let height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .glassEffect(
                tinted ? .regular.tint(.accentColor) : .regular,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
            .opacity(opacity(pressed: configuration.isPressed))
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        tinted ? .white : .primary
    }

    private func opacity(pressed: Bool) -> Double {
        if !isEnabled { return 0.45 }
        return pressed ? 0.72 : 1
    }
}

extension ButtonStyle where Self == GlassControlStyle {
    static var glassControl: GlassControlStyle { GlassControlStyle() }
    static var glassControlProminent: GlassControlStyle { GlassControlStyle(tinted: true) }
}
