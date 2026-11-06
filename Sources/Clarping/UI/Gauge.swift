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
        VStack(alignment: .leading, spacing: 4) {
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
                    if shimmer && !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                            let x = CGFloat((ctx.date.timeIntervalSinceReferenceDate * 0.6).truncatingRemainder(dividingBy: 1))
                            Capsule()
                                .fill(LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * 0.35)
                                .offset(x: -geo.size.width * 0.35 + x * geo.size.width * 1.35)
                        }
                        .clipShape(Capsule())
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
