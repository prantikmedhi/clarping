import Foundation
import AppKit
import ServiceManagement
import UserNotifications

enum MainTab: String, CaseIterable { case dashboard = "Dashboard", settings = "Settings" }

/// Progress of "Add account" / "Re-capture", shown inline in the popover and
/// in Settings (sheets and alerts do not present reliably from a MenuBarExtra
/// window, so nothing modal is used).
struct AddStatus: Equatable {
    enum Kind { case working, info, done }
    var kind: Kind
    var text: String
}

@MainActor
final class AppState: ObservableObject {
    let paths: Paths
    let vault: Vault
    let switcher: Switcher
    /// All blocking work (keychain, processes, files, log ingest) goes through here.
    let io = IOWorker()

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
    /// Add / re-capture progress; nil when idle and nothing to report.
    @Published var addStatus: AddStatus?
    var adding: Bool { addStatus?.kind == .working }
    /// `claude` CLI processes alive at the last check (refreshed off-main when
    /// a switch is requested and on every poll; never computed in a view body).
    @Published var runningCLI = 0
    /// Burn-rate projection per account, recomputed when a snapshot is recorded
    /// rather than on every render.
    @Published var projections: [String: TimeInterval] = [:]
    @Published var captureNote: String?

    private var pollTask: Task<Void, Never>?
    private var ingesting = false
    private var lastIngestStarted: Date?
    /// Accounts whose stored token is being refreshed right now. A switch to
    /// one of them waits; a refresh never persists over a newer vault entry.
    private var refreshing: Set<String> = []
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init(paths: Paths) {
        self.paths = paths
        vault = Vault(paths: paths)
        switcher = Switcher(paths: paths, vault: vault)
        switcher.identityCheck = { try await ClaudeAPI.profile(token: $0).accountId }
        // Small files only; token stats (megabytes) are loaded in start().
        settings = vault.loadSettings()
        accounts = vault.loadAccounts()
        snapshots = vault.loadSnapshots()
        switchLog = vault.loadSwitchLog()
        activeId = switcher.currentAccountUUID()
        recomputeProjections()
    }

    func start() {
        if AppState.isBundled, settings.notifyThresholds {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let vault = self.vault
        Task { [weak self] in
            let stats = await self?.io.run { vault.loadTokenStats() } ?? TokenStats()
            guard let self else { return }
            self.tokenStats = stats
            self.restartPolling()
        }
    }

    // MARK: Accounts

    /// Links the login Claude Code holds right now. An account that is already
    /// linked is not silently re-captured: the user is told to log in to another
    /// account first. Claude Desktop is never quit from here (see `recapture`).
    func addCurrentAccount() { captureCurrent(relink: false) }

    /// Explicit re-capture of the active account from Settings. With Desktop
    /// switching enabled this quits and relaunches Claude Desktop to copy its login.
    func recapture(_ account: Account) {
        guard account.id == activeId else { errors[account.id] = "Only the active account can be re-captured"; return }
        captureCurrent(relink: true)
    }

    private func captureCurrent(relink: Bool) {
        guard !adding else { return }
        guard switchingTo == nil else { addStatus = AddStatus(kind: .info, text: "A switch is in progress; try again when it finishes."); return }
        errors["_add"] = nil
        captureNote = nil
        addStatus = AddStatus(kind: .working, text: "Reading the current login…")
        let switcher = self.switcher, vault = self.vault
        Task {
            do {
                // An in-flight poll holds the keychain item; wait for it instead of refusing.
                var waited = 0
                while polling, waited < 150 {
                    addStatus = AddStatus(kind: .working, text: "Waiting for the usage poll to finish…")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    waited += 1
                }
                guard let currentId = await io.run({ switcher.currentAccountUUID() }) else {
                    throw SwitchError(message: "Claude Code is not logged in. Run `claude /login` first, then click Add.")
                }
                if !relink, let existing = accounts.first(where: { $0.id == currentId }) {
                    addStatus = AddStatus(kind: .info, text: "\(existing.label) is already linked. Log in to another account with `claude /login` first, then click Add.")
                    activeId = currentId
                    return
                }
                let desktopRunning = await io.run { switcher.isDesktopRunning() }
                let policy: Switcher.DesktopPolicy
                if relink && settings.switchDesktop && desktopRunning {
                    policy = .quitIfRunning
                    addStatus = AddStatus(kind: .working, text: "Quitting Claude Desktop to copy its login…")
                } else {
                    policy = .skipIfRunning
                    addStatus = AddStatus(kind: .working, text: "Checking the login with Anthropic…")
                }
                var list = accounts
                // Nonisolated async: runs off the main actor (process spawns, keychain, network).
                let a = try await switcher.captureCurrent(into: &list, desktop: policy)
                accounts = list
                let saved = accounts
                await io.run { vault.saveAccounts(saved) }
                activeId = a.id
                errors[a.id] = nil
                captureNote = switcher.lastCaptureNote
                addStatus = AddStatus(kind: .done, text: relink ? "Re-captured \(a.label)." : "Linked \(a.label).")
                await poll(account: a)
                ingestTokens()
            } catch {
                addStatus = nil
                errors["_add"] = error.localizedDescription
            }
        }
    }

    func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        persistAccounts()
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        snapshots.removeAll { $0.accountId == account.id }
        projections[account.id] = nil
        let vault = self.vault, snaps = snapshots, id = account.id
        Task {
            await io.run {
                try? vault.removeAccount(id: id)
                vault.saveSnapshots(snaps)
            }
        }
    }

    func saveSettings() {
        let vault = self.vault, s = settings
        Task { await io.run { vault.saveSettings(s) } }
        restartPolling()
        if AppState.isBundled {
            do {
                if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { errors["_settings"] = error.localizedDescription }
        }
    }

    private func persistAccounts() {
        let vault = self.vault, list = accounts
        Task { await io.run { vault.saveAccounts(list) } }
    }

    private func persistSnapshots() {
        let vault = self.vault, snaps = snapshots
        Task { await io.run { vault.saveSnapshots(snaps) } }
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
        let switcher = self.switcher
        let (id, cli) = await io.run { (switcher.currentAccountUUID(), Switcher.runningCLICount()) }
        activeId = id
        runningCLI = cli
        for a in accounts where switchingTo == nil { await poll(account: a) }
        ingestTokens()
    }

    /// Refreshes the running-CLI count before the switch confirmation is shown.
    func refreshRunningCLI() {
        Task { runningCLI = await io.run { Switcher.runningCLICount() } }
    }

    /// Active account reads straight from the Claude Code keychain item and is
    /// never refreshed by Clarping (its refresh token belongs to the CLI).
    /// Other accounts are refreshed from the vault when near expiry.
    func poll(account: Account) async {
        guard switchingTo == nil else { return }
        let switcher = self.switcher, vault = self.vault
        do {
            var creds: CLICreds
            if account.id == activeId {
                creds = try await io.run { try switcher.readCLICreds() }
                // The keychain item and ~/.claude.json can disagree (failed switch, a
                // running CLI of the old account); never file tokens under the wrong id.
                if let token = creds.accessToken {
                    let profile = try await ClaudeAPI.profile(token: token)
                    guard profile.accountId == account.id else {
                        throw SwitchError(message: "Keychain login belongs to a different account; not saved")
                    }
                }
                guard switchingTo == nil else { return }
                let c = creds
                try await io.run { try vault.saveCLICreds(c, for: account.id) }
            } else {
                guard let stored = try await io.run({ try vault.cliCreds(for: account.id) }) else { throw SwitchError(message: "No stored login") }
                creds = stored
                // Only refresh once the access token is actually expired: a `claude`
                // session of that account may still hold the same refresh token, and
                // every refresh rotates it for whoever refreshes first.
                if let exp = creds.expiresAt, exp < Date(), !refreshing.contains(account.id) {
                    refreshing.insert(account.id)
                    defer { refreshing.remove(account.id) }
                    let fresh = try await ClaudeAPI.refresh(creds)
                    // Persist only if nothing else (a switch, a re-capture) replaced the
                    // vault entry while the request was in flight.
                    let now = try await io.run { try vault.cliCreds(for: account.id) }
                    guard switchingTo == nil, now?.refreshToken == stored.refreshToken else { return }
                    try await io.run { try vault.saveCLICreds(fresh, for: account.id) }
                    creds = fresh
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
        } catch APIError.recaptureNeeded {
            var a = account
            a.needsRelogin = true
            update(a)
            errors[account.id] = "Stored login was rotated elsewhere. Make it active with `claude /login`, then re-capture."
        } catch {
            errors[account.id] = error.localizedDescription
        }
    }

    private func record(_ snap: UsageSnapshot, previous: UsageSnapshot?, account: Account) {
        snapshots.append(snap)
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        snapshots.removeAll { $0.at < cutoff }
        persistSnapshots()
        recomputeProjections()
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
    func projection(for id: String) -> TimeInterval? { projections[id] }

    private func recomputeProjections() {
        var out: [String: TimeInterval] = [:]
        for a in accounts {
            if let p = computeProjection(for: a.id) { out[a.id] = p }
        }
        if out != projections { projections = out }
    }

    private func computeProjection(for id: String) -> TimeInterval? {
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

    func requestSwitch(to account: Account) {
        confirmTarget = account
        refreshRunningCLI()
    }

    func performSwitch(to account: Account) {
        confirmTarget = nil
        guard switchingTo == nil, !adding else { return }
        switchingTo = account.id
        switchError = nil
        let from = activeId
        let switcher = self.switcher, vault = self.vault
        Task {
            // A refresh of the target may be in flight; let it finish or give up.
            for _ in 0..<100 where refreshing.contains(account.id) { try? await Task.sleep(nanoseconds: 200_000_000) }
            var list = accounts
            do {
                try await switcher.switchTo(account, accounts: &list, includeDesktop: settings.switchDesktop) { step in
                    Task { @MainActor in self.switchStep = step }
                }
                merge(list)
                activeId = await io.run { switcher.currentAccountUUID() }
                switchLog.append(SwitchLogEntry(at: Date(), fromId: from, toId: account.id, ok: true, note: nil))
            } catch {
                merge(list)
                switchError = error.localizedDescription
                switchLog.append(SwitchLogEntry(at: Date(), fromId: from, toId: account.id, ok: false, note: error.localizedDescription))
            }
            let log = switchLog
            await io.run { vault.saveSwitchLog(log) }
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
        persistAccounts()
    }

    // MARK: Tokens

    /// Incremental (byte cursors per file) and throttled: at most once a minute,
    /// one run at a time, entirely off the main actor including the save. The
    /// published stats only change when the buckets actually changed, so the
    /// dashboard is not re-rendered for a no-op pass.
    func ingestTokens(force: Bool = false) {
        guard !ingesting else { return }
        if !force, let t = lastIngestStarted, Date().timeIntervalSince(t) < 60 { return }
        ingesting = true
        lastIngestStarted = Date()
        let input = tokenStats
        let projects = paths.claudeProjects
        let attribute = TokenIngest.attributor(log: switchLog, activeId: activeId)
        let vault = self.vault
        Task.detached(priority: .utility) { [weak self] in
            var result = input
            TokenIngest.ingest(stats: &result, projects: projects, attribute: attribute)
            let changed = result.buckets != input.buckets || result.cursors != input.cursors
            if changed { vault.saveTokenStats(result) }
            let final = result
            await MainActor.run { [weak self] in
                guard let self else { return }
                if changed { self.tokenStats = final }
                self.ingesting = false
            }
        }
    }
}
