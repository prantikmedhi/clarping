import SwiftUI
import AppKit

/// The menu bar glyph: the Split Spark (assets/brand/menubar-glyph.svg) drawn
/// as a template image. The upper-right half is always solid; when the active
/// account has a 5-hour utilization the lower-left half becomes a gauge: a
/// faint track with a solid level rising from its bottom tip.
enum SparkIcon {
    /// assets/brand/menubar-glyph.svg: 18 x 18 pt box, y down. Two subpaths:
    /// the upper-right half, then the lower-left half (1.35 pt S-shaped cut).
    static let glyphSVG = "M8.026 1.347Q7.601 2.933 6.936 4.096Q6.76 4.404 7.034 4.629Q8.599 5.917 9.632 8.771Q10.516 11.216 11.761 12.272Q12.053 12.52 12.327 12.252Q13.899 10.712 16.653 9.974Q17.107 9.852 17.306 9.426Q17.504 9 17.306 8.574Q17.107 8.148 16.653 8.026Q11.385 6.615 9.974 1.347Q9.852 0.893 9.426 0.694Q9 0.496 8.574 0.694Q8.148 0.893 8.026 1.347ZM5.673 5.748Q4.101 7.288 1.347 8.026Q0.893 8.148 0.694 8.574Q0.496 9 0.694 9.426Q0.893 9.852 1.347 9.974Q6.615 11.385 8.026 16.653Q8.148 17.107 8.574 17.306Q9 17.504 9.426 17.306Q9.852 17.107 9.974 16.653Q10.399 15.067 11.064 13.904Q11.24 13.596 10.966 13.371Q9.401 12.083 8.368 9.229Q7.484 6.784 6.239 5.728Q5.947 5.48 5.673 5.748Z"
    /// The same spark with the app icon's narrower cut (assets/brand/icon-1024.svg,
    /// 1024 canvas, y down); used for large in-app drawings of the mark.
    static let iconMarkSVG = "M478.97 252.35Q462.03 315.57 433.66 359.25Q429.41 365.78 435.53 370.61Q487.96 412.02 522.72 508.12Q555.05 597.52 602.14 634.92Q608.45 639.94 613.83 633.93Q668.67 572.63 771.65 545.03Q787.06 540.91 793.8 526.45Q800.54 512 793.8 497.55Q787.06 483.09 771.65 478.97Q592.92 431.08 545.03 252.35Q540.91 236.94 526.45 230.2Q512 223.46 497.55 230.2Q483.09 236.94 478.97 252.35ZM410.17 390.07Q355.33 451.37 252.35 478.97Q236.94 483.09 230.2 497.55Q223.46 512 230.2 526.45Q236.94 540.91 252.35 545.03Q431.08 592.92 478.97 771.65Q483.09 787.06 497.55 793.8Q512 800.54 526.45 793.8Q540.91 787.06 545.03 771.65Q561.97 708.43 590.34 664.75Q594.59 658.22 588.47 653.39Q536.04 611.98 501.28 515.88Q468.95 426.48 421.86 389.08Q415.55 384.06 410.17 390.07Z"

    /// Glyph halves in the 18 pt box, y down (SwiftUI) and flipped to AppKit's
    /// y-up space (status item); parsed once.
    static let glyphHalvesYDown: [CGPath] = SVGPath.subpaths(glyphSVG)
    static let glyphHalves: [CGPath] = glyphHalvesYDown.compactMap {
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 18)
        return $0.copy(using: &flip)
    }
    static let iconHalves: [CGPath] = SVGPath.subpaths(iconMarkSVG)

    static func image(fill: Double?, angle: Double, scale: Double, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext, glyphHalves.count == 2 else { return false }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            let c = CGPoint(x: rect.midX, y: rect.midY)
            // Rotation and scale about the centre; the gauge level turns with the glyph.
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: CGFloat(angle) * .pi / 180)
            ctx.scaleBy(x: CGFloat(scale) * size / 18, y: CGFloat(scale) * size / 18)
            ctx.translateBy(x: -9, y: -9)
            let upper = glyphHalves[0], lower = glyphHalves[1]
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(upper)
            ctx.fillPath()
            guard let fill else {
                ctx.addPath(lower)
                ctx.fillPath()
                return true
            }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.addPath(lower)
            ctx.fillPath()
            let f = CGFloat(min(max(fill, 0), 100)) / 100
            if f > 0 {
                let b = lower.boundingBoxOfPath
                // Snapped to the 2x pixel grid so the level edge stays crisp.
                let level = f >= 1 ? b.maxY : ((b.minY + b.height * f) * 2).rounded() / 2
                ctx.saveGState()
                ctx.clip(to: CGRect(x: b.minX - 1, y: b.minY - 1, width: b.width + 2, height: level - b.minY + 1))
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.addPath(lower)
                ctx.fillPath()
                ctx.restoreGState()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// One template image holding the glyph and the optional usage text; it is
    /// set on the status item button directly. Keyed by (whole-percent fill,
    /// text, switching); the cache is bounded. While a switch runs the glyph is
    /// drawn turned and slightly smaller; the pulse is a layer animation.
    private static var cache: [String: NSImage] = [:]
    static func labelImage(fill: Int?, text: String?, switching: Bool = false) -> NSImage {
        let key = "\(fill.map(String.init) ?? "-")|\(text ?? "")|\(switching)"
        if let img = cache[key] { return img }
        if cache.count > 64 { cache.removeAll() }
        let glyph = image(fill: fill.map(Double.init), angle: switching ? 45 : 0, scale: switching ? 0.9 : 1)
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

/// Minimal SVG path-data reader for the brand paths: absolute M, L, Q, C, Z.
enum SVGPath {
    /// One CGPath per subpath, in the SVG's own coordinates.
    static func subpaths(_ d: String) -> [CGPath] {
        var result: [CGPath] = []
        var path = CGMutablePath()
        var nums: [CGFloat] = []
        var cmd: Character = " "
        var token = ""
        func flushNumber() {
            if let v = Double(token) { nums.append(CGFloat(v)) }
            token = ""
        }
        func apply() {
            let n = nums
            switch cmd {
            case "M" where n.count >= 2:
                if !path.isEmpty { result.append(path); path = CGMutablePath() }
                path.move(to: CGPoint(x: n[0], y: n[1]))
                for i in stride(from: 2, to: n.count - 1, by: 2) { path.addLine(to: CGPoint(x: n[i], y: n[i + 1])) }
            case "L":
                for i in stride(from: 0, to: n.count - 1, by: 2) { path.addLine(to: CGPoint(x: n[i], y: n[i + 1])) }
            case "Q":
                for i in stride(from: 0, to: n.count - 3, by: 4) {
                    path.addQuadCurve(to: CGPoint(x: n[i + 2], y: n[i + 3]), control: CGPoint(x: n[i], y: n[i + 1]))
                }
            case "C":
                for i in stride(from: 0, to: n.count - 5, by: 6) {
                    path.addCurve(to: CGPoint(x: n[i + 4], y: n[i + 5]), control1: CGPoint(x: n[i], y: n[i + 1]),
                                  control2: CGPoint(x: n[i + 2], y: n[i + 3]))
                }
            case "Z", "z":
                path.closeSubpath()
            default:
                break
            }
            nums = []
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flushNumber(); apply(); cmd = ch
            } else if ch == " " || ch == "," || ch == "\n" {
                flushNumber()
            } else if ch == "-" && !token.isEmpty && token.last != "e" && token.last != "E" {
                flushNumber(); token = "-"
            } else {
                token.append(ch)
            }
        }
        flushNumber(); apply()
        if !path.isEmpty { result.append(path) }
        return result
    }
}

/// The Clarping mark in brand colour: clay upper half, deep terracotta lower
/// half, same geometry as the app icon. Small sizes use the menu bar glyph's
/// wider cut so the split still reads.
struct BrandMark: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let glyph = side < 40
            ZStack {
                MarkHalf(glyph: glyph, index: 0)
                    .fill(LinearGradient(colors: [Color(hex: 0xE58E6C), Color(hex: 0xCF6A47)],
                                         startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)))
                MarkHalf(glyph: glyph, index: 1)
                    .fill(LinearGradient(colors: [Color(hex: 0xBE5B3A), Color(hex: 0x9C4528)],
                                         startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The app's own icon (build/AppIcon.icns, from assets/brand/icon-1024.png),
/// as macOS shows it; used where the app introduces itself.
struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// One half of the mark, scaled so the whole mark (both halves) fills the rect.
private struct MarkHalf: Shape {
    var glyph: Bool
    var index: Int
    func path(in rect: CGRect) -> Path {
        let paths = glyph ? SparkIcon.glyphHalvesYDown : SparkIcon.iconHalves
        guard index < paths.count else { return Path() }
        let bounds = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
        let s = min(rect.width / bounds.width, rect.height / bounds.height)
        let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return Path(paths[index]).applying(t)
    }
}

/// The only state the status item depends on. AppState writes it solely when a
/// value actually changes; StatusItemController sets the button image from it.
final class MenuBarModel: ObservableObject {
    @Published var fill: Int?        // whole-percent 5-hour utilization of the active account
    @Published var text: String?
    @Published var switching = false
}
