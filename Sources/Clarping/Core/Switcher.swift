import Foundation
import AppKit

enum SwitchStep: String, CaseIterable {
    case quittingDesktop = "Quitting Claude Desktop"
    case capturing = "Saving current login"
    case backingUp = "Backing up"
    case writingKeychain = "Writing keychain"
    case patchingConfig = "Updating ~/.claude.json"
    case restoringDesktop = "Restoring Desktop login"
    case relaunchingDesktop = "Relaunching Claude Desktop"
    case done = "Done"
}

struct SwitchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Captures the currently logged-in account into the vault and swaps logins.
/// Takes a `Paths` so the whole flow can run against a temporary HOME.
final class Switcher {
    let paths: Paths
    let vault: Vault
    private let fm = FileManager.default

    /// Returns the account id a CLI access token belongs to (profile endpoint).
    /// nil skips the check (self-test only).
    var identityCheck: ((String) async throws -> String)?
    /// Human-readable note from the last capture (e.g. Desktop signed in elsewhere).
    private(set) var lastCaptureNote: String?

    init(paths: Paths, vault: Vault) {
        self.paths = paths
        self.vault = vault
    }

    /// CLARPING_TRACE=1 prints step names (never values) to stderr.
    private static let tracing = ProcessInfo.processInfo.environment["CLARPING_TRACE"] == "1"
    private func trace(_ s: String) { if Switcher.tracing { FileHandle.standardError.write(Data((s + "\n").utf8)) } }

    // MARK: Reading the live state

    func readClaudeJSON() throws -> [String: Any] {
        let d = try Data(contentsOf: paths.claudeJSON)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw SwitchError(message: "~/.claude.json is not a JSON object") }
        return o
    }

    func currentAccountUUID() -> String? {
        ((try? readClaudeJSON())?["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
    }

    /// Whole Claude Code keychain item (`mcpOAuth` + `claudeAiOauth`); nil when absent.
    func readCLIItemIfPresent() throws -> [String: Any]? {
        guard let d = try readCLIItemData() else { return nil }
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw SwitchError(message: "Keychain item is not JSON") }
        return o
    }

    private func readCLIItemData() throws -> Data? {
        try Keychain.read(service: paths.cliService, account: paths.cliAccount, viaTool: paths.cliReadViaTool)
    }

    func readCLIItem() throws -> [String: Any] {
        guard let o = try readCLIItemIfPresent() else { throw SwitchError(message: "No Claude Code login found in the keychain") }
        return o
    }

    func readCLICreds() throws -> CLICreds {
        guard let c = try readCLIItem()["claudeAiOauth"] as? [String: Any] else { throw SwitchError(message: "Keychain item has no claudeAiOauth") }
        return CLICreds(raw: c)
    }

    // MARK: Capture

    enum DesktopPolicy { case quitIfRunning, skipIfRunning, alreadyQuiet }

    /// Stores the active login (CLI creds, oauthAccount, Desktop auth) in the vault.
    /// The keychain token is checked against the profile endpoint before it is
    /// filed, so a stale CLI writing an old login back can never overwrite
    /// another account's only copy.
    @discardableResult
    func captureCurrent(into accounts: inout [Account], desktop: DesktopPolicy = .skipIfRunning) async throws -> Account {
        lastCaptureNote = nil
        trace("capture: reading ~/.claude.json")
        let cfg = try readClaudeJSON()
        guard let oa = cfg["oauthAccount"] as? [String: Any], let id = oa["accountUuid"] as? String else {
            throw SwitchError(message: "~/.claude.json has no oauthAccount; log in with `claude` first")
        }
        trace("capture: reading keychain item")
        let creds = try readCLICreds()
        if let identityCheck, let token = creds.accessToken {
            trace("capture: checking token owner via profile endpoint")
            let owner = try await identityCheck(token)
            guard owner == id else {
                throw SwitchError(message: "The keychain login belongs to a different account than ~/.claude.json; run `claude` once and try again")
            }
        }
        trace("capture: saving CLI creds to vault")
        try vault.saveCLICreds(creds, for: id)

        trace("capture: desktop")
        var hasDesktop = false
        var relaunch = false
        if fm.fileExists(atPath: paths.desktopDir.path) {
            switch desktop {
            case .alreadyQuiet:
                hasDesktop = try snapshotDesktop(for: id)
            case .skipIfRunning where isDesktopRunning():
                lastCaptureNote = "Claude Desktop is running; its login was not captured. Re-capture with Desktop quit, or enable Desktop switching."
            case .quitIfRunning where isDesktopRunning():
                try await quitDesktop()
                relaunch = true
                hasDesktop = try snapshotDesktop(for: id)
            default:
                hasDesktop = try snapshotDesktop(for: id)
            }
        }
        if relaunch { launchDesktop() }

        let email = oa["emailAddress"] as? String ?? ""
        let org = oa["organizationName"] as? String ?? ""
        let now = Date()
        if let i = accounts.firstIndex(where: { $0.id == id }) {
            accounts[i].oauthAccount = [String: JSONValue](anyDictionary: oa)
            accounts[i].email = email
            accounts[i].orgName = org
            accounts[i].lastCaptured = now
            accounts[i].hasDesktopSnapshot = hasDesktop || accounts[i].hasDesktopSnapshot
            accounts[i].needsRelogin = false
            return accounts[i]
        }
        let label = (oa["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (email.split(separator: "@").first.map(String.init) ?? "Account")
        let a = Account(id: id, label: label, colorHex: AccountColors.next(after: accounts.map(\.colorHex)), email: email, orgName: org,
                        createdAt: now, lastCaptured: now, oauthAccount: [String: JSONValue](anyDictionary: oa),
                        hasDesktopSnapshot: hasDesktop, needsRelogin: false)
        accounts.append(a)
        return a
    }

    // MARK: Switch

    /// Order: quit Desktop (so its files are quiescent), re-capture the active
    /// login, back up, write keychain, patch ~/.claude.json, restore Desktop,
    /// relaunch. Any failure after the keychain write rolls the keychain item,
    /// `oauthAccount` and the Desktop auth files back to their pre-switch state.
    func switchTo(_ target: Account, accounts: inout [Account], includeDesktop: Bool, progress: (SwitchStep) -> Void) async throws {
        let currentId = currentAccountUUID()
        let doDesktop = includeDesktop && fm.fileExists(atPath: paths.desktopDir.path) && target.hasDesktopSnapshot
        let wasRunning = doDesktop && isDesktopRunning()
        if wasRunning {
            progress(.quittingDesktop)
            try await quitDesktop()
        }

        progress(.capturing)
        let alreadyActive = currentId == target.id
        if currentId != nil, !alreadyActive {
            // Refresh tokens rotate; make sure the vault has whatever the CLI holds now.
            try await captureCurrent(into: &accounts, desktop: doDesktop ? .alreadyQuiet : .skipIfRunning)
        }
        guard let creds = try vault.cliCreds(for: target.id) else {
            throw SwitchError(message: "No stored login for \(target.label). Re-capture it while it is active.")
        }
        if alreadyActive && !doDesktop {
            // The live keychain item is newer than anything in the vault; nothing to write.
            progress(.done)
            return
        }

        progress(.backingUp)
        let desktopBackup = try backup(includeDesktopFiles: doDesktop)
        let previousItem = try Keychain.read(service: paths.cliService, account: paths.cliAccount)
        let previousOAuth = try readClaudeJSON()["oauthAccount"]

        do {
            if !alreadyActive {
                progress(.writingKeychain)
                try writeCLICreds(creds)

                progress(.patchingConfig)
                try patchClaudeJSON(oauthAccount: target.oauthAccount.anyDictionary)
            }
            if doDesktop {
                progress(.restoringDesktop)
                try restoreDesktop(for: target.id)
            }
        } catch {
            if !alreadyActive {
                if let previousItem { try? Keychain.write(service: paths.cliService, account: paths.cliAccount, data: previousItem) }
                // Re-read and put back only oauthAccount, so CLI writes made meanwhile survive.
                if let previousOAuth = previousOAuth as? [String: Any] { try? patchClaudeJSON(oauthAccount: previousOAuth) }
            }
            if let desktopBackup { try? restoreDesktopFiles(from: desktopBackup) }
            if wasRunning { launchDesktop() }
            throw SwitchError(message: "\(error.localizedDescription). Previous login restored.")
        }
        if wasRunning {
            progress(.relaunchingDesktop)
            launchDesktop()
        }
        progress(.done)
    }

    // MARK: Pieces

    /// ~/.claude.json goes to a timestamped 0600 file (it holds no login tokens,
    /// but may hold MCP server settings); the keychain item and Desktop's login
    /// keys are backed up inside the keychain. With `includeDesktopFiles`, the
    /// live Desktop auth files (values already encrypted by Desktop) are copied
    /// to a 0700 `<ts>-desktop/` folder, returned for rollback. The backups
    /// folder is excluded from Time Machine.
    @discardableResult
    func backup(includeDesktopFiles: Bool = false) throws -> URL? {
        let ts = Format.iso.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        Vault.excludeFromBackup(paths.backups)
        if let d = try? Data(contentsOf: paths.claudeJSON) {
            try Vault.atomicWrite(d, to: paths.backups.appendingPathComponent("\(ts)-claude.json"), mode: 0o600)
        }
        if let item = try Keychain.read(service: paths.cliService, account: paths.cliAccount) {
            try vault.saveCLIBackup(item)
        }
        if let cfg = try readDesktopConfig() {
            var keys: [String: Any] = [:]
            for k in Paths.desktopConfigKeys { if let v = cfg[k] { keys[k] = v } }
            try vault.saveDesktopConfigBackup(keys)
        }
        var desktopBackup: URL?
        if includeDesktopFiles {
            let dir = paths.backups.appendingPathComponent("\(ts)-desktop")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try copyDesktopAuthItems(from: paths.desktopDir, to: dir)
            desktopBackup = dir
        }
        pruneBackups(keep: 20)
        return desktopBackup
    }

    private func pruneBackups(keep: Int) {
        guard let files = try? fm.contentsOfDirectory(atPath: paths.backups.path) else { return }
        for name in files.sorted().dropLast(keep) { try? fm.removeItem(at: paths.backups.appendingPathComponent(name)) }
    }

    /// Copies the auth items and tightens modes to 0700 dirs / 0600 files.
    private func copyDesktopAuthItems(from srcDir: URL, to dstDir: URL) throws {
        for rel in Paths.desktopAuthItems {
            let src = srcDir.appendingPathComponent(rel)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dstDir.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: src, to: dst)
            Vault.tightenModes(dst)
        }
    }

    /// Puts the live Desktop auth files back from a `<ts>-desktop/` backup.
    func restoreDesktopFiles(from backupDir: URL) throws {
        for rel in Paths.desktopAuthItems {
            let from = backupDir.appendingPathComponent(rel)
            let to = paths.desktopDir.appendingPathComponent(rel)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        }
    }

    /// Replaces only `claudeAiOauth`; `mcpOAuth` and any other keys stay as they
    /// are. The item is updated in place so its access list survives. A missing
    /// item is refused (one Clarping created would prompt the CLI on every read);
    /// an unreadable one is an error (never silently dropped).
    func writeCLICreds(_ creds: CLICreds) throws {
        guard var item = try readCLIItemIfPresent() else {
            throw SwitchError(message: "No Claude Code keychain item exists; run `claude /login` once, then switch")
        }
        item["claudeAiOauth"] = creds.raw
        let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
        try Keychain.write(service: paths.cliService, account: paths.cliAccount, data: data)
    }

    /// Re-reads the file, replaces `oauthAccount`, drops account-keyed caches,
    /// keeps everything else. The read-modify-write window is small, but a
    /// `claude` process writing at the same moment can still lose its write;
    /// the UI warns when CLI processes are running.
    func patchClaudeJSON(oauthAccount: [String: Any]) throws {
        var cfg = try readClaudeJSON()
        cfg["oauthAccount"] = oauthAccount
        for k in Paths.claudeJSONCacheKeys { cfg.removeValue(forKey: k) }
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Vault.atomicWrite(data, to: paths.claudeJSON, mode: fileMode(paths.claudeJSON))
    }

    private func fileMode(_ url: URL) -> Int {
        (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
    }

    // MARK: Desktop

    /// nil when config.json does not exist; throws when it exists but is not JSON.
    private func readDesktopConfig() throws -> [String: Any]? {
        guard fm.fileExists(atPath: paths.desktopConfig.path) else { return nil }
        let d = try Data(contentsOf: paths.desktopConfig)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw SwitchError(message: "Claude Desktop config.json is not a JSON object; left untouched")
        }
        return o
    }

    /// Copies Desktop auth files into the vault (built in a temp folder, then
    /// swapped in so a failed copy keeps the previous good snapshot) and the
    /// login keys of config.json into the keychain. Desktop must not be running.
    /// When Desktop is signed in as a different account than the CLI, nothing is
    /// stored under `id` and a note explains why. Returns false when nothing
    /// was captured.
    @discardableResult
    func snapshotDesktop(for id: String) throws -> Bool {
        guard fm.fileExists(atPath: paths.desktopDir.path) else { return false }
        if isDesktopRunning() { throw SwitchError(message: "Claude Desktop is still running; its files cannot be copied safely") }
        let cfg = try readDesktopConfig()
        if let desktopId = cfg?["lastKnownAccountUuid"] as? String, !desktopId.isEmpty, desktopId != id {
            lastCaptureNote = "Claude Desktop is signed in as a different account (\(String(desktopId.prefix(8)))…); sign Desktop into this account and re-capture to link it."
            return false
        }
        Vault.excludeFromBackup(paths.desktopSnapshots)
        let dest = vault.desktopSnapshotDir(for: id)
        let tmp = paths.desktopSnapshots.appendingPathComponent(".\(id).\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copied = false
        do {
            try copyDesktopAuthItems(from: paths.desktopDir, to: tmp)
            copied = Paths.desktopAuthItems.contains { fm.fileExists(atPath: tmp.appendingPathComponent($0).path) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        if let cfg {
            var keys: [String: Any] = [:]
            for k in Paths.desktopConfigKeys { if let v = cfg[k] { keys[k] = v } }
            try vault.saveDesktopConfig(keys, for: id)
            copied = copied || !keys.isEmpty
        }
        return copied
    }

    func restoreDesktop(for id: String) throws {
        try restoreDesktopFiles(from: vault.desktopSnapshotDir(for: id))
        if let keys = try vault.desktopConfig(for: id) {
            var cfg = try readDesktopConfig() ?? [:]
            for k in Paths.desktopConfigKeys {
                if let v = keys[k] { cfg[k] = v } else { cfg.removeValue(forKey: k) }
            }
            let data = try JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys, .withoutEscapingSlashes])
            try Vault.atomicWrite(data, to: paths.desktopConfig, mode: fileMode(paths.desktopConfig))
        }
    }

    /// True while the main app or any of its helper processes is alive.
    func isDesktopRunning() -> Bool {
        guard let bid = paths.desktopBundleID else { return false }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
        return desktopHelperCount() > 0
    }

    /// Helper processes live inside the .app bundle; `pgrep -f` on that path
    /// catches renderer, GPU and network helpers after the main process exits.
    private func desktopHelperCount() -> Int {
        guard let bid = paths.desktopBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
              let r = try? Shell.run("/usr/bin/pgrep", ["-f", url.path + "/"]) else { return 0 }
        return r.status == 0 ? String(decoding: r.out, as: UTF8.self).split(separator: "\n").count : 0
    }

    /// Number of running `claude` CLI processes (their ~/.claude.json writes can
    /// race a switch, and they keep using the old login until restarted).
    static func runningCLICount() -> Int {
        guard let r = try? Shell.run("/usr/bin/pgrep", ["-x", "claude"]), r.status == 0 else { return 0 }
        return String(decoding: r.out, as: UTF8.self).split(separator: "\n").count
    }

    func quitDesktop() async throws {
        guard let bid = paths.desktopBundleID else { return }
        let r = try Shell.run("/usr/bin/osascript", ["-e", "tell application id \"\(bid)\" to quit"])
        guard r.status == 0 else { throw SwitchError(message: "Could not ask Claude Desktop to quit (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))") }
        for _ in 0..<80 {
            if !isDesktopRunning() {
                // Grace period: let the last helper flush and exit.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if !isDesktopRunning() { return }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SwitchError(message: "Claude Desktop did not quit in time")
    }

    func launchDesktop() {
        guard let bid = paths.desktopBundleID else { return }
        _ = try? Shell.run("/usr/bin/open", ["-b", bid])
    }
}
