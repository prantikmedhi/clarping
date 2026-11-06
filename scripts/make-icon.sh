#!/bin/bash
# Draws the app icon in code (clay spark on cream, rounded squircle) and
# packages it as build/AppIcon.icns with sips + iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT/AppIcon.iconset"
TMP="$(mktemp -d)"

cat > "$TMP/icon.swift" <<'SWIFT'
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
    let squircle = NSBezierPath(roundedRect: inset, xRadius: size * 0.22, yRadius: size * 0.22)
    NSColor(red: 0.961, green: 0.941, blue: 0.910, alpha: 1).setFill()   // cream F5F0E8
    squircle.fill()
    // soft inner vignette
    let g = NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.clear])!
    squircle.addClip()
    g.draw(in: inset, relativeCenterPosition: NSPoint(x: -0.3, y: 0.5))

    let c = NSPoint(x: rect.midX, y: rect.midY)
    func spark(radius r: CGFloat, waist: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let w = r * waist
        let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
        let waists = [NSPoint(x: c.x + w, y: c.y + w), NSPoint(x: c.x + w, y: c.y - w), NSPoint(x: c.x - w, y: c.y - w), NSPoint(x: c.x - w, y: c.y + w)]
        p.move(to: tips[0])
        for i in 0..<4 {
            p.curve(to: waists[i], controlPoint1: tips[i], controlPoint2: waists[i])
            p.curve(to: tips[(i + 1) % 4], controlPoint1: waists[i], controlPoint2: tips[(i + 1) % 4])
        }
        p.close()
        return p
    }
    // shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(red: 0.788, green: 0.392, blue: 0.259, alpha: 0.35)
    shadow.shadowBlurRadius = size * 0.04
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.02)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1).setFill()   // clay D97757
    spark(radius: size * 0.34, waist: 0.20).fill()
    NSGraphicsContext.restoreGraphicsState()
    // highlight tip
    NSColor(red: 0.788, green: 0.392, blue: 0.259, alpha: 1).setFill()   // C96442
    let small = spark(radius: size * 0.34, waist: 0.20)
    small.transform(using: AffineTransform(translationByX: 0, byY: -size * 0.012))
    NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1).setFill()
    small.fill()
    return true
}
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swiftc -O -o "$TMP/icon" "$TMP/icon.swift" 2>/dev/null
"$TMP/icon" "$OUT/icon-1024.png"

for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon-1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$OUT/icon-1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
rm -rf "$TMP"
echo "Wrote $OUT/AppIcon.icns"
