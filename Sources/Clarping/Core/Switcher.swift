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

    init(paths: Paths, vault: Vault) {
        self.paths = paths
        self.vault = vault
    }

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
        guard let d = try Keychain.read(service: paths.cliService, account: paths.cliAccount) else { return nil }
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw SwitchError(message: "Keychain item is not JSON") }
        return o
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

    /// Stores the active login (CLI creds, oauthAccount, Desktop auth) in the vault.
    @discardableResult
    func captureCurrent(into accounts: inout [Account]) throws -> Account {
        let cfg = try readClaudeJSON()
        guard let oa = cfg["oauthAccount"] as? [String: Any], let id = oa["accountUuid"] as? String else {
            throw SwitchError(message: "~/.claude.json has no oauthAccount; log in with `claude` first")
        }
        let creds = try readCLICreds()
        try vault.saveCLICreds(creds, for: id)
        let hasDesktop = try snapshotDesktop(for: id)

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
    /// relaunch. Any failure after the keychain write rolls the keychain item
    /// and ~/.claude.json back to their pre-switch contents.
    func switchTo(_ target: Account, accounts: inout [Account], includeDesktop: Bool, progress: (SwitchStep) -> Void) async throws {
        let currentId = currentAccountUUID()
        let doDesktop = includeDesktop && fm.fileExists(atPath: paths.desktopDir.path) && target.hasDesktopSnapshot
        let wasRunning = doDesktop && isDesktopRunning()
        if wasRunning {
            progress(.quittingDesktop)
            try await quitDesktop()
        }

        progress(.capturing)
        if currentId != nil, currentId != target.id {
            // Refresh tokens rotate; make sure the vault has whatever the CLI holds now.
            try captureCurrent(into: &accounts)
        }
        guard let creds = try vault.cliCreds(for: target.id) else {
            throw SwitchError(message: "No stored login for \(target.label). Re-capture it while it is active.")
        }

        progress(.backingUp)
        try backup()
        let previousItem = try Keychain.read(service: paths.cliService, account: paths.cliAccount)
        let previousConfig = try Data(contentsOf: paths.claudeJSON)

        do {
            progress(.writingKeychain)
            try writeCLICreds(creds)

            progress(.patchingConfig)
            try patchClaudeJSON(oauthAccount: target.oauthAccount.anyDictionary)

            if doDesktop {
                progress(.restoringDesktop)
                try restoreDesktop(for: target.id)
            }
        } catch {
            if let previousItem { try? Keychain.write(service: paths.cliService, account: paths.cliAccount, data: previousItem) }
            try? Vault.atomicWrite(previousConfig, to: paths.claudeJSON, mode: fileMode(paths.claudeJSON))
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

    /// ~/.claude.json goes to a timestamped 0600 file (it holds no login tokens);
    /// the keychain item and Desktop's login keys are backed up inside the keychain.
    func backup() throws {
        let ts = Format.iso.string(from: Date()).replacingOccurrences(of: ":", with: "-")
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
        pruneBackups(keep: 20)
    }

    private func pruneBackups(keep: Int) {
        guard let files = try? fm.contentsOfDirectory(atPath: paths.backups.path) else { return }
        for name in files.sorted().dropLast(keep) { try? fm.removeItem(at: paths.backups.appendingPathComponent(name)) }
    }

    /// Replaces only `claudeAiOauth`; `mcpOAuth` and any other keys stay as they are.
    /// A missing item is created; an unreadable one is an error (never silently dropped).
    func writeCLICreds(_ creds: CLICreds) throws {
        var item = try readCLIItemIfPresent() ?? [:]
        item["claudeAiOauth"] = creds.raw
        let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
        try Keychain.write(service: paths.cliService, account: paths.cliAccount, data: data)
    }

    /// Replaces `oauthAccount`, drops account-keyed caches, keeps everything else.
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
    /// login keys of config.json into the keychain. Returns false when no
    /// Desktop data directory exists.
    @discardableResult
    func snapshotDesktop(for id: String) throws -> Bool {
        guard fm.fileExists(atPath: paths.desktopDir.path) else { return false }
        let dest = vault.desktopSnapshotDir(for: id)
        let tmp = paths.desktopSnapshots.appendingPathComponent(".\(id).\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copied = false
        do {
            for rel in Paths.desktopAuthItems {
                let src = paths.desktopDir.appendingPathComponent(rel)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = tmp.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: src, to: dst)
                copied = true
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        if let cfg = try readDesktopConfig() {
            var keys: [String: Any] = [:]
            for k in Paths.desktopConfigKeys { if let v = cfg[k] { keys[k] = v } }
            try vault.saveDesktopConfig(keys, for: id)
            copied = copied || !keys.isEmpty
        }
        return copied
    }

    func restoreDesktop(for id: String) throws {
        let src = vault.desktopSnapshotDir(for: id)
        for rel in Paths.desktopAuthItems {
            let from = src.appendingPathComponent(rel)
            let to = paths.desktopDir.appendingPathComponent(rel)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        }
        if let keys = try vault.desktopConfig(for: id) {
            var cfg = try readDesktopConfig() ?? [:]
            for k in Paths.desktopConfigKeys {
                if let v = keys[k] { cfg[k] = v } else { cfg.removeValue(forKey: k) }
            }
            let data = try JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys, .withoutEscapingSlashes])
            try Vault.atomicWrite(data, to: paths.desktopConfig, mode: fileMode(paths.desktopConfig))
        }
    }

    func isDesktopRunning() -> Bool {
        guard let bid = paths.desktopBundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }

    func quitDesktop() async throws {
        guard let bid = paths.desktopBundleID else { return }
        try Shell.run("/usr/bin/osascript", ["-e", "tell application id \"\(bid)\" to quit"])
        for _ in 0..<60 {
            if !isDesktopRunning() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SwitchError(message: "Claude Desktop did not quit in time")
    }

    func launchDesktop() {
        guard let bid = paths.desktopBundleID else { return }
        try? Shell.run("/usr/bin/open", ["-b", bid])
    }
}
