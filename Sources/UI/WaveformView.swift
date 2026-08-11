import SwiftUI

/// A compact live waveform driven by a rolling window of input levels.
///
/// Replaces the pulsing red dot: it reads as "we are hearing you" and doubles
/// as feedback that the mic is picking up real signal, not silence.
struct WaveformView: View {
    let levels: [Double]
    var isActive: Bool
    var barCount: Int = 22

    private let barWidth: CGFloat = 2
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 16

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(levels.suffix(barCount).enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: barWidth, height: height(for: level))
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityLabel(isActive ? "Input level" : "Not recording")
    }

    private func height(for level: Double) -> CGFloat {
        let floorHeight: CGFloat = 2
        guard isActive else { return floorHeight }
        // Slight curve so quiet speech still moves the bars visibly.
        let shaped = pow(max(0, min(level, 1)), 0.65)
        return floorHeight + (maxHeight - floorHeight) * CGFloat(shaped)
    }

    /// Matches the adjacent status text rather than introducing an accent
    /// colour, so the header reads as one element instead of two.
    private func color(for index: Int) -> Color {
        guard isActive else { return Color.secondary.opacity(0.35) }
        // Newest bars (on the right) read strongest.
        let recency = Double(index) / Double(max(1, barCount - 1))
        return Color.secondary.opacity(0.35 + 0.65 * recency)
    }
}
