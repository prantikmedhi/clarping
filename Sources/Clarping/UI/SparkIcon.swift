import SwiftUI
import AppKit

/// The menu bar glyph: a four-point spark drawn as a template image with a
/// thin arc around it showing the active account's 5-hour utilization.
enum SparkIcon {
    static func sparkPath(center c: CGPoint, radius r: CGFloat, waist: CGFloat = 0.22) -> NSBezierPath {
        let p = NSBezierPath()
        let w = r * waist
        let tips = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
        let waists = [CGPoint(x: c.x + w, y: c.y + w), CGPoint(x: c.x + w, y: c.y - w), CGPoint(x: c.x - w, y: c.y - w), CGPoint(x: c.x - w, y: c.y + w)]
        p.move(to: tips[0])
        for i in 0..<4 {
            let next = tips[(i + 1) % 4], mid = waists[i]
            p.curve(to: mid, controlPoint1: tips[i], controlPoint2: mid)
            p.curve(to: next, controlPoint1: mid, controlPoint2: next)
        }
        p.close()
        return p
    }

    static func image(fill: Double?, angle: Double, scale: Double, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let t = NSAffineTransform()
            t.translateX(by: c.x, yBy: c.y)
            t.rotate(byDegrees: CGFloat(angle))
            t.scale(by: CGFloat(scale))
            t.translateX(by: -c.x, yBy: -c.y)
            let spark = sparkPath(center: c, radius: size * 0.30)
            spark.transform(using: t as AffineTransform)
            spark.fill()
            if let fill {
                let ring = NSBezierPath()
                ring.lineWidth = 1.3
                ring.lineCapStyle = .round
                let r = size * 0.44
                let sweep = CGFloat(min(max(fill, 0), 100)) * 3.6
                ring.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                ring.stroke()
                NSColor.black.withAlphaComponent(0.25).setStroke()
                let track = NSBezierPath()
                track.lineWidth = 1.0
                track.appendArc(withCenter: c, radius: r, startAngle: 90 - sweep, endAngle: 90 - 360, clockwise: true)
                track.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Static glyphs keyed by whole-percent fill, so the status item image is
    /// only redrawn when the value actually changes.
    private static var cache: [Int: NSImage] = [:]
    static func cached(fill: Double?) -> NSImage {
        let key = fill.map { Int(min(max($0, 0), 100).rounded()) } ?? -1
        if let img = cache[key] { return img }
        let img = image(fill: fill, angle: 0, scale: 1)
        cache[key] = img
        return img
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fill = state.activeSnapshot?.fiveHour
        HStack(spacing: 4) {
            if state.switchingTo != nil && !reduceMotion {
                // Only while a switch runs: a 20 fps spin on an 18 pt image.
                TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Image(nsImage: SparkIcon.image(fill: fill, angle: (t * 60).truncatingRemainder(dividingBy: 360),
                                                   scale: 0.9 + 0.1 * (0.5 + 0.5 * sin(t * 4))))
                }
            } else {
                Image(nsImage: SparkIcon.cached(fill: fill))
            }
            if let text = state.menuBarText {
                Text(text).font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
    }
}
