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

    /// One template image holding the glyph and the optional usage text, so the
    /// MenuBarExtra label is a plain `Image`: SwiftUI then sets it on the status
    /// button directly instead of snapshotting a hosted view on every update.
    /// Keyed by (whole-percent fill, text); the cache is bounded.
    private static var cache: [String: NSImage] = [:]
    static func labelImage(fill: Int?, text: String?) -> NSImage {
        let key = "\(fill.map(String.init) ?? "-")|\(text ?? "")"
        if let img = cache[key] { return img }
        if cache.count > 64 { cache.removeAll() }
        let glyph = image(fill: fill.map(Double.init), angle: 0, scale: 1)
        let img: NSImage
        if let text, !text.isEmpty {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let str = NSAttributedString(string: text, attributes: attrs)
            let tw = ceil(str.size().width)
            let h: CGFloat = 18, gap: CGFloat = 4
            img = NSImage(size: NSSize(width: 18 + gap + tw, height: h), flipped: false) { rect in
                glyph.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                let th = ceil(font.ascender - font.descender)
                str.draw(at: NSPoint(x: 18 + gap, y: ((h - th) / 2).rounded()))
                return true
            }
        } else {
            img = glyph
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}

/// The only state the status item label depends on. AppState writes it
/// solely when a value actually changes, so the label (and the expensive
/// MenuBarExtra button re-render behind it) is not invalidated by every
/// @Published change in the app.
final class MenuBarModel: ObservableObject {
    @Published var fill: Int?        // whole-percent 5-hour utilization of the active account
    @Published var text: String?
    @Published var switching = false
}

struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Debug.changes { Debug.tick("MenuBarLabel"); Self._printChanges() }
        return Group {
            if model.switching && !reduceMotion {
                // Only while a switch runs: a 20 fps spin of the glyph alone.
                TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Image(nsImage: SparkIcon.image(fill: model.fill.map(Double.init), angle: (t * 60).truncatingRemainder(dividingBy: 360),
                                                   scale: 0.9 + 0.1 * (0.5 + 0.5 * sin(t * 4))))
                }
            } else {
                Image(nsImage: SparkIcon.labelImage(fill: model.fill, text: model.text))
            }
        }
    }
}
