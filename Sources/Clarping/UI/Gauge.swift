import SwiftUI

/// Soft horizontal gauge: label, percentage with monospaced digits, and a bar
/// whose color eases from sage through amber to clay.
struct SoftGauge: View {
    var label: String
    var percent: Double?
    var detail: String? = nil
    var shimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Debug.changes { Debug.tick("SoftGauge"); Self._printChanges() }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(Theme.inkSecondary) }
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(Theme.gauge(percent ?? 0))
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(percent ?? 0, 0), 100)) / 100))
                        .opacity(percent == nil ? 0 : 1)
                    // While polling the bar is lightly veiled; a per-gauge TimelineView
                    // shimmer re-rendered the whole popover scene 30 times a second.
                    if shimmer {
                        Capsule().fill(Theme.track.opacity(0.35))
                    }
                }
            }
            .frame(height: 6)
            .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.1), value: percent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(percent.map { "\(Int($0)) percent" } ?? "unknown")")
    }
}
