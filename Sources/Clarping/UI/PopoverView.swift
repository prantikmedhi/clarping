import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Identity space for the account glass shapes, so cards morph rather
    /// than pop when accounts are added or removed.
    @Namespace private var glassSpace

    var body: some View {
        if Debug.changes { Debug.tick("PopoverView"); Self._printChanges() }
        return VStack(alignment: .leading, spacing: 14) {
            header
            if state.accounts.isEmpty {
                emptyState
            } else {
                GlassGroup(spacing: 8) {
                    VStack(spacing: 10) {
                        ForEach(state.accounts) { a in
                            AccountCard(account: a, glassSpace: glassSpace)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                }
            }
            StatusLine()
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 344)
        .background(AmbientBackground())
        .animation(reduceMotion ? nil : Theme.lift, value: state.accounts)
        .animation(reduceMotion ? nil : Theme.quick, value: state.confirmTarget)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Clarping")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
            Spacer()
            if state.polling || state.lastPoll != nil {
                Text(state.polling ? "updating" : state.lastPoll.map { "updated \(Format.clock($0))" } ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .contentTransition(.opacity)
            }
            // System indeterminate control only; no custom repeatForever here
            // (it kept invalidating the popover scene after polling ended).
            Group {
                if state.polling {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await state.pollAll() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkSecondary)
                    .help("Refresh usage now")
                    .accessibilityLabel("Refresh usage")
                }
            }
            .frame(width: 16, height: 16)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
        }
        .animation(reduceMotion ? nil : Theme.quick, value: state.polling)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link your first account")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
            Text("Add the account Claude Code uses now. Sign in to another with `claude`, then add it too.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SoftButton("Add account", prominent: true) { state.addCurrentAccount() }
                .disabled(state.adding || state.switchingTo != nil)
                .help("Link the account Claude Code is signed into right now")
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: 16)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let next = state.suggestedNextId, let a = state.accounts.first(where: { $0.id == next }) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(Color(hexString: a.colorHex)).frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                    Text("Active account is near its limit. \(a.label) has the most room.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            HStack(spacing: 6) {
                // The empty state carries its own prominent "Add account".
                if !state.accounts.isEmpty {
                    SoftButton("Add account") { state.addCurrentAccount() }
                        .disabled(state.adding || state.switchingTo != nil)
                        .help("Link the account Claude Code is signed into right now")
                }
                Spacer()
                SoftButton("Open Clarping") { WindowManager.shared.show(.dashboard) }
                    .help("Open the dashboard")
                SoftButton(action: { WindowManager.shared.show(.settings) }) {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .semibold))
                }
                .help("Settings (Cmd-,)")
                .accessibilityLabel("Settings")
                SoftButton(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power").font(.system(size: 11, weight: .semibold))
                }
                .help("Quit Clarping")
                .accessibilityLabel("Quit Clarping")
            }
        }
    }
}

// MARK: - Account card

struct AccountCard: View {
    @EnvironmentObject var state: AppState
    var account: Account
    var glassSpace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { account.id == state.activeId }
    private var snap: UsageSnapshot? { state.latest(for: account.id) }
    private var isSwitching: Bool { state.switchingTo == account.id }
    private var isConfirming: Bool { state.confirmTarget?.id == account.id }

    var body: some View {
        if Debug.changes { Debug.tick("AccountCard"); Self._printChanges() }
        return VStack(alignment: .leading, spacing: 8) {
            identity
                .padding(.bottom, 2)
            if let err = state.errors[account.id] {
                Label { Text(err).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.clayDeep)
            }
            VStack(alignment: .leading, spacing: 9) {
                SoftGauge(label: "5-hour", percent: snap?.fiveHour, detail: resetText(snap?.fiveHourResetsAt))
                SoftGauge(label: "Weekly", percent: snap?.sevenDay, detail: resetText(snap?.sevenDayResetsAt))
                ForEach(snap?.models ?? [], id: \.name) { m in
                    SoftGauge(label: m.name, percent: m.percent, detail: resetText(m.resetsAt))
                }
            }
            .opacity(isActive ? 1 : 0.86)
            if isActive, let eta = state.projection(for: account.id) {
                HStack(spacing: 5) {
                    Image(systemName: "timer").font(.system(size: 10, weight: .medium))
                    Text("At this pace: limit in ~\(Format.duration(eta))").font(.system(size: 11))
                }
                .foregroundStyle(Theme.inkSecondary)
            }
            if isSwitching, let step = state.switchStep {
                Text(step.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.clayDeep)
                    .contentTransition(.opacity)
            }
            if isConfirming {
                confirmPanel
                    .padding(.top, 2)
                    .modifier(MaterializeTransition())
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(12)
        .glassSurface(radius: 16, lifted: isActive)
        .modifier(GlassIdentity(id: account.id, space: glassSpace))
        .scaleEffect(isActive ? 1 : 0.985)
        .opacity(isActive ? 1 : 0.94)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActive, state.switchingTo == nil else { return }
            state.requestSwitch(to: account)
        }
        .animation(reduceMotion ? nil : Theme.lift, value: isActive)
        .accessibilityAddTraits(isActive ? [] : .isButton)
        .accessibilityHint(isActive ? "" : "Switch to this account")
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(Color(hexString: account.colorHex))
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let plan = account.planName { PlanBadge(name: plan) }
                }
                let sub = [account.emailDomain, account.orgName].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Group {
                if isSwitching {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.clayDeep)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .accessibilityLabel("Active")
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(Theme.inkSecondary.opacity(0.45))
                        .transition(.opacity)
                }
            }
            .frame(width: 18, height: 18)
        }
    }

    private var confirmPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Switch Claude Code\(state.settings.switchDesktop ? " and Desktop" : "") to \(account.label)?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                SoftButton("Cancel") { state.confirmTarget = nil }
                SoftButton("Switch", prominent: true) { state.performSwitch(to: account) }
            }
            let running = state.runningCLI
            if running > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
                    Text("\(running) `claude` session\(running == 1 ? " is" : "s are") running: they keep the old login until restarted and may write ~/.claude.json during the switch.")
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.clayDeep)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: 12, tint: Theme.clay.opacity(0.14))
    }

    private func resetText(_ d: Date?) -> String? {
        guard let d else { return nil }
        return "resets in \(Format.duration(d.timeIntervalSinceNow)) · \(Format.dayClock(d))"
    }
}

/// Glass shapes appear by materializing (macOS 26+); no-op elsewhere.
private struct MaterializeTransition: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !Theme.forceSolid {
            content.glassEffectTransition(.materialize)
        } else {
            content
        }
    }
}

/// Ties a card's glass to a stable identity inside the GlassEffectContainer
/// so it morphs with its neighbours (macOS 26+); no-op elsewhere.
private struct GlassIdentity: ViewModifier {
    var id: String
    var space: Namespace.ID
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !Theme.forceSolid {
            content.glassEffectID(id, in: space)
        } else {
            content
        }
    }
}

// MARK: - Status line

/// Inline feedback under the cards: add/re-capture progress, errors, notes.
/// Replaces sheets and alerts, which do not present reliably from a
/// MenuBarExtra window.
struct StatusLine: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let _ = { if Debug.changes { Debug.tick("StatusLine"); Self._printChanges() } }()
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
                Text(s.text)
                    .font(.system(size: 11))
                    .foregroundStyle(s.kind == .done ? Theme.calm : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
        if let err = state.switchError ?? state.errors["_add"] {
            Text(err).font(.system(size: 11)).foregroundStyle(Theme.clayDeep).fixedSize(horizontal: false, vertical: true)
        } else if let note = state.captureNote {
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
