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

// MARK: - Liquid Glass surfaces
//
// Real system glass (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`)
// on macOS 26 and later; on older systems, or with Reduce Transparency on, the
// same views fall back to solid cream cards. Every animation in the app is a
// settle spring that runs once when a value changes; nothing loops.

extension Theme {
    /// Warm tint laid into the glass so it reads as cream, not grey.
    static let glassTint = Color.adaptive(light: 0xFFF9F0, dark: 0x2A2623)
    /// Tint for the active (lifted) account card.
    static let glassTintActive = Color.adaptive(light: 0xFFF4EA, dark: 0x3A2E27)

    /// One-shot settle when a gauge value or layout changes.
    static let settle = Animation.spring(duration: 0.45, bounce: 0.12)
    /// Card lift / morph on switch.
    static let lift = Animation.spring(duration: 0.4, bounce: 0.2)
    /// Quick crossfades (status text, tab content).
    static let quick = Animation.smooth(duration: 0.25)

    /// Debug only: CLARPING_DEBUG_FLAT=1 forces the solid fallback everywhere
    /// (`cacheDisplay` snapshots cannot draw system glass, so documentation
    /// screenshots are rendered flat).
    static let forceSolid = ProcessInfo.processInfo.environment["CLARPING_DEBUG_FLAT"] == "1"

    /// Whether system Liquid Glass can be drawn right now.
    static func glassAvailable(reduceTransparency: Bool) -> Bool {
        if reduceTransparency || forceSolid { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// A glass panel (regular variant, cream tint) that falls back to a solid card.
/// `lifted` adds a warmer tint and a soft shadow for the active account.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = 14
    var lifted = false
    var interactive = false
    var tint: Color? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency, !Theme.forceSolid {
            content
                .glassEffect(.regular.tint((tint ?? (lifted ? Theme.glassTintActive : Theme.glassTint)).opacity(lifted ? 0.85 : 0.7)).interactive(interactive), in: shape)
                .shadow(color: .black.opacity(lifted ? 0.08 : 0), radius: lifted ? 14 : 0, y: lifted ? 6 : 0)
        } else {
            content
                .background(shape.fill(lifted ? Theme.cardLifted : Theme.card))
                .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(lifted ? 0.10 : 0.03), radius: lifted ? 10 : 2, y: lifted ? 4 : 1)
        }
    }
}

extension View {
    /// Glass panel with the given corner radius; solid card when glass is unavailable.
    func glassSurface(radius: CGFloat = 14, lifted: Bool = false, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassSurface(radius: radius, lifted: lifted, interactive: interactive, tint: tint))
    }

    /// Groups sibling glass shapes so they blend and morph together
    /// (`GlassEffectContainer`); a plain group elsewhere.
    @ViewBuilder
    func glassGroup<Content: View>(spacing: CGFloat = 16, @ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26.0, *), !Theme.forceSolid {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Wraps content in a GlassEffectContainer when available. Use around a stack
/// of glass surfaces so neighbouring shapes merge as they move.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *), !Theme.forceSolid {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Small text button: system glass (`.glass` / `.glassProminent`, clay tinted)
/// when available, the quiet cream style otherwise. 12 pt medium label.
struct SoftButton<Label: View>: View {
    var prominent = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(prominent: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.prominent = prominent; self.action = action; self.label = label
    }

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency, !Theme.forceSolid {
            if prominent {
                Button(action: action) { label().font(.system(size: 12, weight: .medium)).padding(.horizontal, 2) }
                    .buttonStyle(.glassProminent).tint(Theme.clayDeep).controlSize(.small)
            } else {
                Button(action: action) { label().font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink).padding(.horizontal, 2) }
                    .buttonStyle(.glass).controlSize(.small)
            }
        } else {
            Button(action: action, label: label).buttonStyle(QuietButtonStyle(prominent: prominent))
        }
    }
}

extension SoftButton where Label == Text {
    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.init(prominent: prominent, action: action) { Text(title) }
    }
}

/// Plan badge ("Max 5x", "Pro"): a quiet capsule, clay on cream.
struct PlanBadge: View {
    var name: String
    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(Theme.clayDeep)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.clay.opacity(0.14)))
            .accessibilityLabel("Plan \(name)")
    }
}

/// Window / popover background: cream with two very soft warm pools so glass
/// above it has something to refract. Static; nothing animates here.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.clay.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Theme.amber.opacity(0.07), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}
