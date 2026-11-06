import SwiftUI
import AppKit

/// First-run setup guide: seven short steps in a fixed 760 x 540 window.
/// Left, a quiet vector illustration per step on a glass panel; right, the
/// copy, a live check where one helps, the step's action and the navigation.
///
/// Performance: nothing here loops. Live checks run once when a step appears,
/// after a successful Add, and on "Check again"; each is one async call into
/// AppState whose result lands in a Box. Animations run only when a value
/// changes and are dropped entirely with Reduce Motion.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var box = Box(GuideLocal())

    static let stepCount = 7
    private var step: Int { min(max(state.onboardingStep, 0), Self.stepCount - 1) }
    private var isLast: Bool { step == Self.stepCount - 1 }

    var body: some View {
        if Debug.changes { Debug.tick("OnboardingView"); Self._printChanges() }
        // The window's content area is 760 x 540 below a transparent title bar
        // (full-size content). The fixed frame keeps the window that size; the
        // layout inside extends up under the title bar.
        return ZStack {
            AmbientBackground()
            HStack(spacing: 0) {
                illustrationPanel
                rightColumn
            }
        }
        .ignoresSafeArea()
        .frame(width: 760, height: 540)
        .onChange(of: state.addStatus) { _, new in
            // A finished Add changes what the CLI check should say ("already linked").
            if new?.kind == .done { checkCLI() }
        }
    }

    // MARK: Layout

    private var illustrationPanel: some View {
        ZStack {
            RadialGradient(colors: [Theme.clay.opacity(0.09), .clear], center: .center, startRadius: 0, endRadius: 170)
                .offset(y: -18)
                .allowsHitTesting(false)
            ZStack {
                illustration(for: step)
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                            removal: .opacity.combined(with: .scale(scale: 1.02))))
            }
            .offset(y: -14)
            .animation(reduceMotion ? nil : Theme.quick, value: step)
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    BrandMark().frame(width: 13, height: 13)
                    Text("Clarping").font(.system(size: 12.5, weight: .semibold, design: .serif)).foregroundStyle(Theme.inkSecondary)
                    Spacer()
                }
                .padding(.leading, 20).padding(.bottom, 18)
            }
        }
        .frame(width: 292)
        .frame(maxHeight: .infinity)
        .glassSurface(radius: 22)
        .padding(.leading, 10).padding(.vertical, 10)
        .accessibilityHidden(true)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // onAppear sits inside .id so it fires for every step that appears.
                stepContent(step)
                    .onAppear { runChecks(for: step) }
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)),
                                            removal: .opacity.combined(with: .offset(x: -16))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : Theme.quick, value: step)
            bottomBar
        }
        .padding(.top, 60)
        .padding(.leading, 40)
        .padding(.trailing, 36)
        .padding(.bottom, 24)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            HStack {
                if !isLast { SoftButton("Skip") { finish() }.help("Close the guide; reopen it any time from Settings") }
            }
            .frame(width: 96, alignment: .leading)
            Spacer(minLength: 0)
            StepDots(current: step, count: Self.stepCount, reduceMotion: reduceMotion)
            Spacer(minLength: 0)
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    SoftButton("Back") { go(step - 1) }
                        .opacity(step == 0 ? 0 : 1)
                        .disabled(step == 0)
                        .accessibilityHidden(step == 0)
                    SoftButton(isLast ? "Done" : "Continue", prominent: true) {
                        if isLast { finish() } else { go(step + 1) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 176, alignment: .trailing)
        }
        .frame(height: 32)
    }

    // MARK: Steps

    @ViewBuilder
    private func stepContent(_ s: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Step \(s + 1) of \(Self.stepCount)")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.bottom, 8)
            switch s {
            case 0: welcome
            case 1: cliStep
            case 2: desktopStep
            case 3: moreAccountsStep
            case 4: keychainStep
            case 5: switchingStep
            default: doneStep
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Welcome to Clarping")
            paragraph("Switch the Claude account that Claude Code CLI and Claude Desktop use, in one click. The menu bar shows each account's 5-hour and weekly limits.")
            paragraph("Nothing of Claude's is changed until you switch.", secondary: true)
            VStack(alignment: .leading, spacing: 10) {
                point("person.crop.circle.badge.plus", "Link each Claude account once")
                point("key", "Allow one keychain prompt on the first switch")
                point("menubar.rectangle", "Switch and watch limits from the menu bar")
            }
            .padding(.top, 6)
        }
    }

    private var cliStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Sign in to Claude Code")
            paragraph("Sign in with `claude /login` in Terminal, then add this account. Clarping checks the login with Anthropic and stores a copy; nothing of Claude's is changed.")
            commandRow
            cliRow
            addAction
        }
    }

    private var desktopStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Claude Desktop")
            paragraph("Sign in to the same account in Claude Desktop, then add it.")
            paragraph("During a switch Clarping quits Claude Desktop, swaps its login files and reopens it. The first time, macOS asks to allow Clarping to control Claude (System Settings → Privacy & Security → Automation).", secondary: true)
            desktopRow
            note("info.circle", "Add skips Desktop while it is running. Re-capture in Settings, with Desktop switching on, quits and reopens Desktop to copy its login.")
            addAction
        }
    }

    private var moreAccountsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Add more accounts")
            paragraph("Run `claude /login` with the next account (and sign in on Desktop), then click Add. Repeat for each account.")
            commandRow
            cliRow
            addAction
            linkedList
        }
    }

    private var keychainStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("One keychain prompt")
            paragraph("On the first real switch, macOS asks whether Clarping may use the \u{201C}Claude Code-credentials\u{201D} keychain item. Choose Always Allow.")
            paragraph("Clarping updates that existing item in place, so Claude Code keeps reading it as before. Other logins stored in it, such as MCP servers, are kept.", secondary: true)
            note("hammer", "Clarping is ad-hoc signed. A rebuild changes its identity, so the prompt returns once.")
        }
    }

    private var switchingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Switching")
            paragraph("Click an account in the menu bar popover, confirm, and you are done. Claude Code, and Claude Desktop if enabled, now use that account.")
            VStack(alignment: .leading, spacing: 10) {
                point("arrow.clockwise", "Restart running `claude` sessions. They keep the old login until restarted.")
                point("folder", "Projects, sessions, MCP logins and settings are not touched.")
            }
            .padding(.top, 4)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("You're set")
            paragraph("Clarping lives in your menu bar. Click the spark to see every account's limits and to switch. Reopen this guide any time from Settings.")
            VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Launch at login").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        Spacer()
                        Toggle("Launch at login", isOn: Binding(get: { state.settings.launchAtLogin },
                                                                set: { state.settings.launchAtLogin = $0; state.saveSettings() }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(Theme.clayDeep)
                    }
                    Text("Works most reliably with Clarping in /Applications.")
                        .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .glassSurface(radius: 12)
                .frame(maxWidth: 384)
            SoftButton("Open the menu bar") { WindowManager.shared.showPopover?() }
                .help("Show the Clarping popover under the menu bar spark")
        }
    }

    // MARK: Building blocks

    private func title(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 24, weight: .semibold, design: .serif))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func paragraph(_ key: LocalizedStringKey, secondary: Bool = false) -> some View {
        Text(key)
            .font(.system(size: secondary ? 12 : 13))
            .lineSpacing(secondary ? 2 : 2.5)
            .foregroundStyle(secondary ? Theme.inkSecondary : Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
    }

    private func point(_ icon: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.clayDeep)
                .frame(width: 18)
            Text(key)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func note(_ icon: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            Text(key)
                .font(.system(size: 11.5))
                .lineSpacing(1.5)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var commandRow: some View {
        HStack(spacing: 10) {
            Text("claude /login")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            SoftButton(box.value.copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("claude /login", forType: .string)
                box.value.copied = true
            }
            .help("Copy the command")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.track.opacity(0.75)))
        .frame(maxWidth: 384)
    }

    private var cliRow: some View {
        let l = box.value
        let icon: String, tint: Color, title: String, detail: LocalizedStringKey?
        if !l.cliChecked {
            icon = "circle.dashed"; tint = Theme.inkSecondary; title = "Checking Claude Code…"; detail = nil
        } else if let cli = l.cli {
            if !cli.hasToken {
                icon = "exclamationmark.circle"; tint = Theme.amber
                title = "Signed in, but the token is missing"; detail = "Run `claude` once, then check again."
            } else {
                icon = "checkmark.circle.fill"; tint = Theme.calm
                title = cli.email.isEmpty ? "Signed in" : "Signed in as \(cli.email)"
                detail = cli.linked ? "Already linked in Clarping" : "Ready to add"
            }
        } else {
            icon = "circle.dashed"; tint = Theme.inkSecondary
            title = "Not signed in"; detail = "Run `claude /login` in Terminal, then check again."
        }
        return LiveRow(icon: icon, tint: tint, title: title, detail: detail, checking: l.checkingCLI, recheck: { checkCLI() })
            .animation(reduceMotion ? nil : Theme.quick, value: l.cli)
    }

    private var desktopRow: some View {
        let l = box.value
        let icon: String, tint: Color, title: String, detail: LocalizedStringKey?
        if let d = l.desktop {
            if !d.installed {
                icon = "circle.dashed"; tint = Theme.inkSecondary
                title = "Claude Desktop is not installed"; detail = "Only using Claude Code? Skip this step."
            } else if d.running {
                switch d.signedIn {
                case .some(true): icon = "checkmark.circle.fill"; tint = Theme.calm; title = "Running, signed in"
                case .some(false): icon = "exclamationmark.circle"; tint = Theme.amber; title = "Running, signed out"
                case .none: icon = "circle.dashed"; tint = Theme.inkSecondary; title = "Running"
                }
                detail = d.captured ? "Desktop login captured" : nil
            } else {
                icon = "moon"; tint = Theme.inkSecondary
                title = d.signedIn == true ? "Not running, signed in" : "Not running"
                detail = d.captured ? "Desktop login captured" : nil
            }
        } else {
            icon = "circle.dashed"; tint = Theme.inkSecondary; title = "Checking Claude Desktop…"; detail = nil
        }
        return LiveRow(icon: icon, tint: tint, title: title, detail: detail, checking: l.checkingDesktop, recheck: { checkDesktop() })
            .animation(reduceMotion ? nil : Theme.quick, value: l.desktop)
    }

    private var addAction: some View {
        let l = box.value
        let signedIn = l.cli != nil
        return VStack(alignment: .leading, spacing: 8) {
            SoftButton("Add this account", prominent: true) { state.addCurrentAccount() }
                .modifier(FallbackDim())
                .disabled(state.adding || !signedIn || state.switchingTo != nil)
                .help(signedIn ? "Link the account Claude Code is signed into right now" : "Sign in with claude /login first")
            AddFeedback()
        }
    }

    private var linkedList: some View {
        let shown = Array(state.accounts.prefix(4))
        let extra = state.accounts.count - shown.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Linked so far")
                .font(.system(size: 11, weight: .medium)).tracking(0.4)
                .foregroundStyle(Theme.inkSecondary)
            if shown.isEmpty {
                Text("No accounts linked yet.")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 28) }
                        HStack(spacing: 8) {
                            Circle().fill(Color(hexString: a.colorHex)).frame(width: 8, height: 8)
                            Text(a.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            if let plan = a.planName { PlanBadge(name: plan) }
                            Spacer(minLength: 8)
                            Text(a.emailDomain).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                    }
                    if extra > 0 {
                        Text("and \(extra) more")
                            .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.bottom, 7)
                    }
                }
                .padding(.vertical, 2)
                .glassSurface(radius: 12)
                .frame(maxWidth: 384)
            }
            Text("If Add says the account is already linked, sign in to a different account first.")
                .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.top, 4)
        .animation(reduceMotion ? nil : Theme.settle, value: state.accounts)
    }

    @ViewBuilder
    private func illustration(for s: Int) -> some View {
        let l = box.value
        switch s {
        case 0: WelcomeArt()
        case 1: TerminalArt(signedIn: l.cli?.hasToken == true)
        case 2: DesktopArt(signedIn: l.desktop?.signedIn == true)
        case 3: AccountStackArt()
        case 4: KeychainArt()
        case 5: SwitchArt()
        default: DoneArt()
        }
    }

    // MARK: Actions

    private func go(_ s: Int) {
        state.onboardingStep = min(max(s, 0), Self.stepCount - 1)
    }

    private func finish() {
        state.finishOnboarding()
        WindowManager.shared.closeOnboarding()
    }

    /// Live checks for the step that just appeared (one call each, never in body).
    private func runChecks(for s: Int) {
        Debug.log("onboarding: step \(s + 1) appeared")
        box.value.copied = false
        switch s {
        case 1, 3: checkCLI()
        case 2: checkCLI(); checkDesktop()
        default: break
        }
    }

    private func checkCLI() {
        guard !box.value.checkingCLI else { return }
        Debug.log("onboarding: CLI check start")
        box.value.checkingCLI = true
        let box = self.box, state = self.state
        Task { @MainActor in
            let r = await state.detectCLILogin()
            box.value.cli = r
            box.value.cliChecked = true
            box.value.checkingCLI = false
            Debug.log("onboarding: CLI check done")
        }
    }

    private func checkDesktop() {
        guard !box.value.checkingDesktop else { return }
        box.value.checkingDesktop = true
        let box = self.box, state = self.state
        Task { @MainActor in
            let r = await state.detectDesktop()
            box.value.desktop = r
            box.value.checkingDesktop = false
        }
    }
}

/// Local, per-window state of the guide (no `@State` on this toolchain).
private struct GuideLocal {
    var cli: AppState.CLILogin?
    var cliChecked = false
    var checkingCLI = false
    var desktop: AppState.DesktopStatus?
    var checkingDesktop = false
    var copied = false
}

// MARK: - Pieces

/// Dims a disabled SoftButton in the solid fallback (system glass buttons dim themselves).
private struct FallbackDim: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.opacity(!isEnabled && !Theme.glassAvailable(reduceTransparency: reduceTransparency) ? 0.45 : 1)
    }
}

/// A live check: state icon (or a small spinner while checking), a one-line
/// result, an optional hint and "Check again", on a glass panel.
private struct LiveRow: View {
    var icon: String
    var tint: Color
    var title: String
    var detail: LocalizedStringKey?
    var checking: Bool
    var recheck: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
                        .transition(.opacity)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .contentTransition(.opacity)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: recheck) {
                Text("Check again").font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(checking ? Theme.inkSecondary : Theme.clayDeep)
            .disabled(checking)
            .help("Run the check again")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassSurface(radius: 12)
        .frame(maxWidth: 384)
        .accessibilityElement(children: .combine)
    }
}

/// Add progress / result / error / capture note, styled like the popover's StatusLine.
private struct AddFeedback: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = state.addStatus {
                HStack(alignment: .top, spacing: 6) {
                    if s.kind == .working {
                        ProgressView().controlSize(.mini).padding(.top, 1)
                    } else {
                        Image(systemName: s.kind == .done ? "checkmark.circle" : "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(s.kind == .done ? Theme.calm : Theme.inkSecondary)
                            .padding(.top, 1)
                    }
                    Text(inline(s.text)).font(.system(size: 11.5)).foregroundStyle(s.kind == .done ? Theme.calm : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            if let err = state.errors["_add"] {
                Text(inline(err)).font(.system(size: 11.5)).foregroundStyle(Theme.clayDeep).fixedSize(horizontal: false, vertical: true)
            } else if let note = state.captureNote {
                Text(inline(note)).font(.system(size: 11.5)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 384, alignment: .leading)
    }

    /// Renders `code` spans (status texts mention `claude /login`); plain text otherwise.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Seven dots; the current one stretches into a short clay capsule.
private struct StepDots: View {
    var current: Int
    var count: Int
    var reduceMotion: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.clay : (i < current ? Theme.clay.opacity(0.35) : Theme.track))
                    .frame(width: i == current ? 16 : 6, height: 6)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .modifier(DotsGlass())
        .animation(reduceMotion ? nil : Theme.settle, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The page indicator sits on a small clear-glass capsule (macOS 26+); no
/// background on older systems or with Reduce Transparency.
private struct DotsGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, !Theme.forceSolid {
            content.glassEffect(.regular.tint(Theme.glassTint.opacity(0.5)), in: Capsule())
        } else {
            content
        }
    }
}

// MARK: - Illustrations
//
// Quiet vector drawings, one idea per step. Each runs a single settle
// animation when it appears (Reduce Motion: drawn in place).

/// A plain four-point spark; stands in for Claude in the Desktop illustration.
private struct SparkShape: Shape {
    var waist: CGFloat = 0.22
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let w = r * waist
        let tips = [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)]
        let waists = [CGPoint(x: c.x + w, y: c.y - w), CGPoint(x: c.x + w, y: c.y + w), CGPoint(x: c.x - w, y: c.y + w), CGPoint(x: c.x - w, y: c.y - w)]
        var p = Path()
        p.move(to: tips[0])
        for i in 0..<4 {
            let next = tips[(i + 1) % 4], mid = waists[i]
            p.addCurve(to: mid, control1: tips[i], control2: mid)
            p.addCurve(to: next, control1: mid, control2: next)
        }
        p.closeSubpath()
        return p
    }
}

/// One-shot "drawn" flag for an illustration.
private struct Appear: ViewModifier {
    @ObservedObject var drawn: Box<Bool>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.onAppear {
            guard !drawn.value else { return }
            if reduceMotion { drawn.value = true } else { withAnimation(Theme.settle.delay(0.1)) { drawn.value = true } }
        }
    }
}

private struct Bar: View {
    var width: CGFloat
    var height: CGFloat = 6
    var color: Color = Theme.track
    var body: some View { Capsule().fill(color).frame(width: width, height: height) }
}

private struct ArtCard: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // A blur-free offset shade instead of .shadow: same quiet depth, no
        // per-frame blur pass during step transitions.
        content
            .background(shape.fill(Theme.cardLifted))
            .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
            .background(shape.fill(Color.black.opacity(0.05)).offset(y: 2.5))
    }
}

private extension View {
    func artCard(radius: CGFloat = 14) -> some View { modifier(ArtCard(radius: radius)) }
}

/// Step 1: the app icon inside two thin usage arcs (5-hour, weekly).
private struct WelcomeArt: View {
    @StateObject private var drawn = Box(false)
    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 5).frame(width: 176, height: 176)
            Circle().trim(from: 0, to: drawn.value ? 0.42 : 0)
                .stroke(Theme.clay, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 176, height: 176)
            Circle().stroke(Theme.track, lineWidth: 3).frame(width: 146, height: 146)
            Circle().trim(from: 0, to: drawn.value ? 0.68 : 0)
                .stroke(Theme.calm, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 146, height: 146)
            AppIconView().frame(width: 124, height: 124)
                .scaleEffect(drawn.value ? 1 : 0.9)
        }
        .frame(width: 220, height: 220)
        .modifier(Appear(drawn: drawn))
    }
}

/// Step 2: a small terminal card with the login command.
private struct TerminalArt: View {
    var signedIn: Bool
    @StateObject private var drawn = Box(false)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.hairline).frame(width: 7, height: 7) }
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 24)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(">").foregroundStyle(Theme.clay)
                    Text("claude /login").foregroundStyle(Theme.ink)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                Bar(width: 128).opacity(drawn.value ? 1 : 0)
                HStack(spacing: 6) {
                    if signedIn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.calm)
                    }
                    Bar(width: 92, color: signedIn ? Theme.calm.opacity(0.4) : Theme.track)
                }
                .opacity(drawn.value ? 1 : 0)
                HStack(spacing: 6) {
                    Text(">").foregroundStyle(Theme.clay)
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.clay.opacity(0.75)).frame(width: 7, height: 13)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .padding(14)
        }
        .frame(width: 214)
        .artCard()
        .offset(y: drawn.value ? 0 : 6)
        .modifier(Appear(drawn: drawn))
    }
}

/// Step 3: a desktop window outline with a window-control row.
private struct DesktopArt: View {
    var signedIn: Bool
    @StateObject private var drawn = Box(false)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Theme.clay.opacity(0.55)).frame(width: 7, height: 7)
                Circle().fill(Theme.amber.opacity(0.55)).frame(width: 7, height: 7)
                Circle().fill(Theme.calm.opacity(0.55)).frame(width: 7, height: 7)
                Spacer()
            }
            .padding(.horizontal, 11).frame(height: 22)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Bar(width: 34, height: 5)
                    Bar(width: 26, height: 5)
                    Bar(width: 30, height: 5)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(signedIn ? Theme.calm : Theme.inkSecondary.opacity(0.4)).frame(width: 9, height: 9)
                        Bar(width: 20, height: 4)
                    }
                }
                .padding(10)
                .frame(width: 60, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(Theme.track.opacity(0.55))
                VStack(spacing: 10) {
                    SparkShape().fill(Theme.clay).frame(width: 30, height: 30)
                        .rotationEffect(.degrees(drawn.value ? 0 : -20))
                    Bar(width: 84, height: 5)
                    Bar(width: 58, height: 5)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 124)
        }
        .frame(width: 224)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .artCard(radius: 12)
        .offset(y: drawn.value ? 0 : 6)
        .modifier(Appear(drawn: drawn))
    }
}

/// Step 4: a stack of three account cards fanning out.
private struct AccountStackArt: View {
    @StateObject private var drawn = Box(false)
    private let colors = [Color(hex: 0x5C7A99), Theme.calm, Theme.clay]
    private let fills: [CGFloat] = [0.3, 0.55, 0.4]
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let depth = CGFloat(2 - i)  // 2 = back, 0 = front
                card(color: colors[i], fill: fills[i])
                    .scaleEffect(1 - depth * 0.06)
                    .offset(y: drawn.value ? -depth * 30 : -depth * 10)
                    .opacity(1 - Double(depth) * 0.12)
            }
        }
        .frame(width: 220, height: 200)
        .offset(y: 24)
        .modifier(Appear(drawn: drawn))
    }

    private func card(color: Color, fill: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 9, height: 9)
                Bar(width: 70, height: 6, color: Theme.ink.opacity(0.18))
                Spacer()
                Capsule().fill(Theme.clay.opacity(0.14)).frame(width: 30, height: 12)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 5)
                Capsule().fill(Theme.gauge(Double(fill) * 100)).frame(width: 166 * fill, height: 5)
            }
            .frame(width: 166)
        }
        .padding(14)
        .frame(width: 196)
        .artCard(radius: 12)
    }
}

/// Step 5: a key in a small keychain prompt, "Always Allow" highlighted.
private struct KeychainArt: View {
    @StateObject private var drawn = Box(false)
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.clay.opacity(0.12)).frame(width: 54, height: 54)
                Image(systemName: "key.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.clayDeep)
                    .rotationEffect(.degrees(drawn.value ? -30 : -60))
            }
            VStack(spacing: 6) {
                Bar(width: 150)
                Bar(width: 112)
            }
            HStack(spacing: 6) {
                Text("Always Allow")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.clayDeep))
                    .scaleEffect(drawn.value ? 1 : 0.94)
                Text("Deny").font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.track))
                Text("Allow").font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.track))
            }
        }
        .padding(.vertical, 20).padding(.horizontal, 16)
        .frame(width: 224)
        .artCard(radius: 16)
        .modifier(Appear(drawn: drawn))
    }
}

/// Step 6: two account cards with an arrow; the right one becomes active.
private struct SwitchArt: View {
    @StateObject private var drawn = Box(false)
    var body: some View {
        HStack(spacing: 10) {
            mini(color: Theme.clay, fill: 0.86, active: !drawn.value)
            Image(systemName: "arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.clayDeep)
                .offset(x: drawn.value ? 0 : -4)
                .opacity(drawn.value ? 1 : 0.3)
            mini(color: Theme.calm, fill: 0.18, active: drawn.value)
        }
        .frame(width: 240, height: 200)
        .modifier(Appear(drawn: drawn))
    }

    private func mini(color: Color, fill: CGFloat, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(color).frame(width: 9, height: 9)
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.clayDeep)
                    .opacity(active ? 1 : 0)
            }
            Bar(width: 52, height: 5, color: Theme.ink.opacity(0.18))
            VStack(alignment: .leading, spacing: 5) {
                gauge(fill)
                gauge(fill * 0.6)
            }
        }
        .padding(12)
        .frame(width: 96)
        .artCard(radius: 12)
        .scaleEffect(active ? 1 : 0.94)
        .opacity(active ? 1 : 0.8)
    }

    private func gauge(_ f: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.track).frame(width: 72, height: 4)
            Capsule().fill(Theme.gauge(Double(f) * 100)).frame(width: 72 * f, height: 4)
        }
    }
}

/// Step 7: the Split Spark mark with a checkmark badge, ring complete.
private struct DoneArt: View {
    @StateObject private var drawn = Box(false)
    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 5).frame(width: 176, height: 176)
            Circle().trim(from: 0, to: drawn.value ? 1 : 0)
                .stroke(Theme.calm, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 176, height: 176)
            BrandMark().frame(width: 112, height: 112)
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.calm))
                .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                .offset(x: 34, y: 34)
                .scaleEffect(drawn.value ? 1 : 0.6)
                .opacity(drawn.value ? 1 : 0)
        }
        .frame(width: 220, height: 220)
        .modifier(Appear(drawn: drawn))
    }
}
