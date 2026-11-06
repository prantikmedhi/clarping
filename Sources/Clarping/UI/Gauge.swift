import SwiftUI
import AppKit

/// Liquid horizontal gauge: label on the left, reset detail and percentage on
/// the right, and a capsule fill that reads as liquid (vertical gradient plus a
/// thin highlight along its top). The fill settles once when the value changes;
/// nothing animates otherwise. Color eases from sage through amber to clay.
struct SoftGauge: View {
    var label: String
    var percent: Double?
    var detail: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barHeight: CGFloat = 8

    var body: some View {
        if Debug.changes { Debug.tick("SoftGauge"); Self._printChanges() }
        let pct = min(max(percent ?? 0, 0), 100)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkSecondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .frame(minWidth: 32, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.track)
                        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.05), lineWidth: 0.5))
                    LiquidFill(color: Theme.gauge(pct), height: Self.barHeight)
                        .frame(width: percent == nil ? 0 : max(Self.barHeight, geo.size.width * CGFloat(pct) / 100))
                        .opacity(percent == nil ? 0 : 1)
                }
            }
            .frame(height: Self.barHeight)
            .animation(reduceMotion ? nil : Theme.settle, value: percent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(percent.map { "\(Int($0)) percent" } ?? "unknown")")
    }
}

/// The filled part of a gauge: lighter at the top, full color at the bottom,
/// with a thin white highlight across the top third so it reads as liquid.
private struct LiquidFill: View {
    var color: Color
    var height: CGFloat

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [lighter(color, 0.18), color], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.32))
                    .frame(height: max(1.5, height * 0.26))
                    .padding(.horizontal, height * 0.4)
                    .padding(.top, height * 0.14)
            }
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
            .clipShape(Capsule())
            .shadow(color: color.opacity(0.28), radius: 2, y: 1)
    }

    private func lighter(_ c: Color, _ fraction: CGFloat) -> Color {
        guard let ns = NSColor(c).usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: .white) else { return c }
        return Color(nsColor: ns)
    }
}
