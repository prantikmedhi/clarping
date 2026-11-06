import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Debug.changes { Debug.tick("PopoverView"); Self._printChanges() }
        return VStack(alignment: .leading, spacing: 10) {
            header
            if state.accounts.isEmpty {
                emptyState
            } else {
                ForEach(state.accounts) { a in
                    AccountCard(account: a)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            StatusLine()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.background)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15), value: state.accounts)
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: state.confirmTarget)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Clarping").font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
            Spacer()
            if let last = state.lastPoll {
                Text(state.polling ? "updating" : "updated \(Format.clock(last))")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkSecondary)
                    .contentTransition(.opacity)
            }
            // No repeatForever animation here: inside a MenuBarExtra window it
            // keeps invalidating the scene (and the status item) after polling ends.
            if state.polling {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
            } else {
                Button { Task { await state.pollAll() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.inkSecondary).help("Refresh usage now")
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts linked yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Add the account Claude Code is signed into now. Sign in to another account with `claude`, then add it too.")
                .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let next = state.suggestedNextId, let a = state.accounts.first(where: { $0.id == next }) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hexString: a.colorHex)).frame(width: 6, height: 6)
                    Text("Active account is near its limit. \(a.label) has the most room.")
                        .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                }
            }
            HStack(spacing: 6) {
                Button("Add account") { state.addCurrentAccount() }.buttonStyle(QuietButtonStyle(prominent: state.accounts.isEmpty))
                .disabled(state.adding || state.switchingTo != nil)
                    .help("Link the account Claude Code is signed into right now")
                Spacer()
                Button("Open Clarping") { WindowManager.shared.show(.dashboard) }.buttonStyle(QuietButtonStyle())
                Button { WindowManager.shared.show(.settings) } label: { Image(systemName: "gearshape").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(QuietButtonStyle()).help("Settings (Cmd-,)")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(QuietButtonStyle()).help("Quit Clarping")
            }
        }
    }
}

struct AccountCard: View {
    @EnvironmentObject var state: AppState
    var account: Account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { account.id == state.activeId }
    private var snap: UsageSnapshot? { state.latest(for: account.id) }
    private var isSwitching: Bool { state.switchingTo == account.id }
    private var isConfirming: Bool { state.confirmTarget?.id == account.id }

    var body: some View {
        if Debug.changes { Debug.tick("AccountCard"); Self._printChanges() }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color(hexString: account.colorHex)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text([account.emailDomain, account.orgName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
                Spacer()
                if isSwitching {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.clayDeep).font(.system(size: 14))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            if let err = state.errors[account.id] {
                Text(err).font(.system(size: 11)).foregroundStyle(Theme.clayDeep)
            }
            SoftGauge(label: "5-hour", percent: snap?.fiveHour, detail: resetText(snap?.fiveHourResetsAt), shimmer: state.polling)
            SoftGauge(label: "Weekly", percent: snap?.sevenDay, detail: resetText(snap?.sevenDayResetsAt), shimmer: state.polling)
            ForEach(snap?.models ?? [], id: \.name) { m in
                SoftGauge(label: m.name, percent: m.percent, detail: resetText(m.resetsAt), shimmer: state.polling)
            }
            if isActive, let eta = state.projection(for: account.id) {
                Text("At this pace: limit in ~\(Format.duration(eta))").font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary)
            }
            if isSwitching, let step = state.switchStep {
                Text(step.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.clayDeep).contentTransition(.opacity)
            }
            if isConfirming {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Switch Claude Code\(state.settings.switchDesktop ? " and Desktop" : "") to \(account.label)?")
                            .font(.system(size: 11)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button("Cancel") { state.confirmTarget = nil }.buttonStyle(QuietButtonStyle())
                        Button("Switch") { state.performSwitch(to: account) }.buttonStyle(QuietButtonStyle(prominent: true))
                    }
                    let running = state.runningCLI
                    if running > 0 {
                        Text("\(running) `claude` session\(running == 1 ? " is" : "s are") running: they keep the old login until restarted and may write ~/.claude.json during the switch.")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.clayDeep).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .card(lifted: isActive)
        .scaleEffect(isActive ? 1 : 0.985)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActive, state.switchingTo == nil else { return }
            state.requestSwitch(to: account)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: isActive)
        .accessibilityAddTraits(isActive ? [] : .isButton)
    }

    private func resetText(_ d: Date?) -> String? {
        guard let d else { return nil }
        return "resets in \(Format.duration(d.timeIntervalSinceNow)) · \(Format.dayClock(d))"
    }
}

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
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary).padding(.top, 1)
                }
                Text(s.text).font(.system(size: 11)).foregroundStyle(s.kind == .done ? Theme.calm : Theme.ink)
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
