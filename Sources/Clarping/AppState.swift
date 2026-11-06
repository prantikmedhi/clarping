import Foundation
import AppKit
import ServiceManagement
import UserNotifications

enum MainTab: String, CaseIterable { case dashboard = "Dashboard", settings = "Settings" }

@MainActor
final class AppState: ObservableObject {
    let paths: Paths
    let vault: Vault
    let switcher: Switcher

    @Published var accounts: [Account] = []
    @Published var settings: Settings
    @Published var snapshots: [UsageSnapshot] = []
    @Published var switchLog: [SwitchLogEntry] = []
    @Published var tokenStats = TokenStats()
    @Published var activeId: String?
    @Published var polling = false
    @Published var switchingTo: String?
    @Published var switchStep: SwitchStep?
    @Published var switchError: String?
    @Published var confirmTarget: Account?
    @Published var errors: [String: String] = [:]
    @Published var mainTab: MainTab = .dashboard
    @Published var lastPoll: Date?

    private var pollTask: Task<Void, Never>?
    private var ingesting = false
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init(paths: Paths) {
        self.paths = paths
        vault = Vault(paths: paths)
        switcher = Switcher(paths: paths, vault: vault)
        settings = vault.loadSettings()
        accounts = vault.loadAccounts()
        snapshots = vault.loadSnapshots()
        switchLog = vault.loadSwitchLog()
        tokenStats = vault.loadTokenStats()
        activeId = switcher.currentAccountUUID()
    }

    func start() {
        if AppState.isBundled, settings.notifyThresholds {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        restartPolling()
        ingestTokens()
    }

    // MARK: Accounts

    func addCurrentAccount() {
        do {
            var list = accounts
            let a = try switcher.captureCurrent(into: &list)
            accounts = list
            vault.saveAccounts(accounts)
            activeId = a.id
            errors[a.id] = nil
            Task { await poll(account: a) }
            ingestTokens()
        } catch {
            errors["_add"] = error.localizedDescription
        }
    }

    func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        vault.saveAccounts(accounts)
    }

    func remove(_ account: Account) {
        try? vault.removeAccount(id: account.id)
        accounts.removeAll { $0.id == account.id }
        snapshots.removeAll { $0.accountId == account.id }
        vault.saveSnapshots(snapshots)
    }

    func recapture(_ account: Account) {
        guard account.id == activeId else { errors[account.id] = "Only the active account can be re-captured"; return }
        addCurrentAccount()
    }

    func saveSettings() {
        vault.saveSettings(settings)
        restartPolling()
        if AppState.isBundled {
            do {
                if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { errors["_settings"] = error.localizedDescription }
        }
    }

    // MARK: Polling

    func restartPolling() {
        pollTask?.cancel()
        let minutes = max(1, settings.pollMinutes)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            }
        }
    }

    func pollAll() async {
        guard !polling, switchingTo == nil else { return }
        polling = true
        defer { polling = false; lastPoll = Date() }
        activeId = switcher.currentAccountUUID()
        for a in accounts where switchingTo == nil { await poll(account: a) }
        ingestTokens()
    }

    /// Active account reads straight from the Claude Code keychain item and is
    /// never refreshed by Clarping (its refresh token belongs to the CLI).
    /// Other accounts are refreshed from the vault when near expiry.
    func poll(account: Account) async {
        guard switchingTo == nil else { return }
        do {
            var creds: CLICreds
            if account.id == activeId {
                creds = try switcher.readCLICreds()
                // The keychain item and ~/.claude.json can disagree (failed switch, a
                // running CLI of the old account); never file tokens under the wrong id.
                if let token = creds.accessToken {
                    let profile = try await ClaudeAPI.profile(token: token)
                    guard profile.accountId == account.id else {
                        throw SwitchError(message: "Keychain login belongs to a different account; not saved")
                    }
                }
                guard switchingTo == nil else { return }
                try vault.saveCLICreds(creds, for: account.id)
            } else {
                guard let stored = try vault.cliCreds(for: account.id) else { throw SwitchError(message: "No stored login") }
                creds = stored
                if let exp = creds.expiresAt, exp < Date().addingTimeInterval(60) {
                    creds = try await ClaudeAPI.refresh(creds)
                    try vault.saveCLICreds(creds, for: account.id)
                }
            }
            guard let token = creds.accessToken else { throw APIError.reloginNeeded }
            let snap = try await ClaudeAPI.usage(token: token, accountId: account.id)
            record(snap, previous: latest(for: account.id), account: account)
            errors[account.id] = nil
            if account.needsRelogin { var a = account; a.needsRelogin = false; update(a) }
        } catch APIError.reloginNeeded {
            var a = account
            a.needsRelogin = true
            update(a)
            errors[account.id] = account.id == activeId ? "Token expired. Run `claude` once to refresh." : "Re-login needed"
        } catch {
            errors[account.id] = error.localizedDescription
        }
    }

    private func record(_ snap: UsageSnapshot, previous: UsageSnapshot?, account: Account) {
        snapshots.append(snap)
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        snapshots.removeAll { $0.at < cutoff }
        vault.saveSnapshots(snapshots)
        guard settings.notifyThresholds, let prev = previous else { return }
        for t in [80.0, 95.0] {
            if let p = prev.fiveHour, let n = snap.fiveHour, p < t, n >= t {
                notify("\(account.label): 5-hour usage at \(Int(n))%", body: "Resets \(snap.fiveHourResetsAt.map(Format.dayClock) ?? "soon")")
            }
            if let p = prev.sevenDay, let n = snap.sevenDay, p < t, n >= t {
                notify("\(account.label): weekly usage at \(Int(n))%", body: "Resets \(snap.sevenDayResetsAt.map(Format.dayClock) ?? "soon")")
            }
        }
    }

    private func notify(_ title: String, body: String) {
        guard AppState.isBundled else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Derived

    func latest(for id: String) -> UsageSnapshot? { snapshots.last { $0.accountId == id } }
    var activeAccount: Account? { accounts.first { $0.id == activeId } }
    var activeSnapshot: UsageSnapshot? { activeId.flatMap(latest(for:)) }

    /// Seconds until the 5-hour limit is hit at the current burn rate, from the
    /// last hour of samples. nil when flat, falling, or too few samples.
    func projection(for id: String) -> TimeInterval? {
        let recent = snapshots.filter { $0.accountId == id && $0.at > Date().addingTimeInterval(-3600) }
        guard let first = recent.first, let last = recent.last, last.at.timeIntervalSince(first.at) > 120,
              let u0 = first.fiveHour, let u1 = last.fiveHour, u1 > u0, u1 < 100 else { return nil }
        let rate = (u1 - u0) / last.at.timeIntervalSince(first.at)   // percent per second
        guard rate > 0 else { return nil }
        let eta = (100 - u1) / rate
        if let reset = last.fiveHourResetsAt, reset.timeIntervalSinceNow < eta { return nil }
        return eta
    }

    var suggestedNextId: String? {
        guard settings.suggestNext, let active = activeSnapshot, (active.fiveHour ?? 0) >= 95 else { return nil }
        return accounts.filter { $0.id != activeId && !$0.needsRelogin }
            .min { (latest(for: $0.id)?.fiveHour ?? 101) < (latest(for: $1.id)?.fiveHour ?? 101) }?.id
    }

    var menuBarText: String? {
        guard settings.menuBarText, let s = activeSnapshot, let u = s.fiveHour else { return nil }
        var t = "\(Int(u.rounded()))%"
        if let r = s.fiveHourResetsAt { t += " · \(Format.duration(r.timeIntervalSinceNow))" }
        return t
    }

    // MARK: Switching

    func requestSwitch(to account: Account) { confirmTarget = account }

    func performSwitch(to account: Account) {
        confirmTarget = nil
        guard switchingTo == nil else { return }
        switchingTo = account.id
        switchError = nil
        let from = activeId
        Task {
            var list = accounts
            do {
                try await switcher.switchTo(account, accounts: &list, includeDesktop: settings.switchDesktop) { step in
                    Task { @MainActor in self.switchStep = step }
                }
                merge(list)
                activeId = switcher.currentAccountUUID()
                switchLog.append(SwitchLogEntry(at: Date(), fromId: from, toId: account.id, ok: true, note: nil))
            } catch {
                merge(list)
                switchError = error.localizedDescription
                switchLog.append(SwitchLogEntry(at: Date(), fromId: from, toId: account.id, ok: false, note: error.localizedDescription))
            }
            vault.saveSwitchLog(switchLog)
            switchingTo = nil
            switchStep = nil
            await poll(account: account)
        }
    }

    /// Folds re-captured accounts back in without discarding edits made meanwhile.
    private func merge(_ list: [Account]) {
        for a in list {
            if let i = accounts.firstIndex(where: { $0.id == a.id }) {
                accounts[i].oauthAccount = a.oauthAccount
                accounts[i].lastCaptured = a.lastCaptured
                accounts[i].hasDesktopSnapshot = a.hasDesktopSnapshot
                accounts[i].needsRelogin = a.needsRelogin
            }
        }
        vault.saveAccounts(accounts)
    }

    // MARK: Tokens

    func ingestTokens() {
        guard !ingesting else { return }
        ingesting = true
        let input = tokenStats
        let projects = paths.claudeProjects
        let attribute = TokenIngest.attributor(log: switchLog, activeId: activeId)
        Task.detached(priority: .utility) { [weak self] in
            var result = input
            TokenIngest.ingest(stats: &result, projects: projects, attribute: attribute)
            await MainActor.run {
                guard let self else { return }
                self.tokenStats = result
                self.vault.saveTokenStats(result)
                self.ingesting = false
            }
        }
    }
}
