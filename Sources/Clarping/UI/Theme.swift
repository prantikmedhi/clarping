import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    init(hexString: String) {
        self.init(hex: UInt32(hexString.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xD97757)
    }
    /// Light/dark adaptive color.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            let isDark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Clarping palette: warm cream and charcoal surfaces, clay accent, calm sage
/// for low usage easing through amber into clay as a limit fills.
enum Theme {
    static let clay = Color(hex: 0xD97757)
    static let clayDeep = Color(hex: 0xC96442)
    static let background = Color.adaptive(light: 0xF5F0E8, dark: 0x1F1C1A)
    static let card = Color.adaptive(light: 0xFFFCF7, dark: 0x2A2623)
    static let cardLifted = Color.adaptive(light: 0xFFFFFF, dark: 0x332E2A)
    static let hairline = Color.adaptive(light: 0xE6DED2, dark: 0x3B3531)
    static let ink = Color.adaptive(light: 0x2B2724, dark: 0xF0EAE0)
    static let inkSecondary = Color.adaptive(light: 0x7A726A, dark: 0xA39A90)
    static let track = Color.adaptive(light: 0xEBE4D9, dark: 0x3A3430)
    static let calm = Color(hex: 0x6F8F7A)
    static let amber = Color(hex: 0xD9A441)

    /// 0...100 -> sage until 55, blends to amber by 80, to clay by 100.
    static func gauge(_ pct: Double) -> Color {
        let p = min(max(pct, 0), 100)
        if p <= 55 { return calm }
        if p <= 80 { return mix(calm, amber, (p - 55) / 25) }
        return mix(amber, clayDeep, (p - 80) / 20)
    }

    private static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = NSColor(a).usingColorSpace(.sRGB)!, cb = NSColor(b).usingColorSpace(.sRGB)!
        let t = CGFloat(min(max(t, 0), 1))
        return Color(nsColor: NSColor(red: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                                      green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                                      blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t, alpha: 1))
    }

    static let familyColors: [String: Color] = [
        "Opus": clayDeep, "Sonnet": Color(hex: 0x5C7A99), "Fable": Color(hex: 0x8A6A8F), "Haiku": calm, "Other": Color(hex: 0x9A928A),
    ]
}

struct CardStyle: ViewModifier {
    var lifted = false
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(lifted ? Theme.cardLifted : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(lifted ? 0.10 : 0.03), radius: lifted ? 10 : 2, y: lifted ? 4 : 1)
    }
}

extension View {
    func card(lifted: Bool = false) -> some View { modifier(CardStyle(lifted: lifted)) }
}

/// Small text button with a press scale, matching the popover's quiet tone.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? Theme.clayDeep : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(prominent ? .clear : Theme.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Local view state holder. The Command Line Tools toolchain ships no SwiftUI
/// macro plugin, so `@State` is unavailable; `@StateObject` + Box stands in.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}
