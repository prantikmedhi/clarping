import Foundation

/// Clarping's own storage. Secrets go to the keychain under `paths.vaultService`;
/// everything else is JSON under `paths.appSupport`.
final class Vault {
    let paths: Paths
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(paths: Paths) {
        self.paths = paths
        for dir in [paths.appSupport, paths.backups, paths.desktopSnapshots] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        Vault.excludeFromBackup(paths.backups)
        Vault.excludeFromBackup(paths.desktopSnapshots)
    }

    // MARK: JSON files

    func loadAccounts() -> [Account] { read([Account].self, paths.accountsFile) ?? [] }
    func saveAccounts(_ a: [Account]) { write(a, paths.accountsFile) }
    func loadSettings() -> Settings { read(Settings.self, paths.settingsFile) ?? Settings() }
    func saveSettings(_ s: Settings) { write(s, paths.settingsFile) }
    func loadSnapshots() -> [UsageSnapshot] { read([UsageSnapshot].self, paths.snapshotsFile) ?? [] }
    func saveSnapshots(_ s: [UsageSnapshot]) { write(s, paths.snapshotsFile) }
    func loadSwitchLog() -> [SwitchLogEntry] { read([SwitchLogEntry].self, paths.switchLogFile) ?? [] }
    func saveSwitchLog(_ l: [SwitchLogEntry]) { write(l, paths.switchLogFile) }
    func loadTokenStats() -> TokenStats { read(TokenStats.self, paths.tokenStatsFile) ?? TokenStats() }
    /// Machine-only and megabytes large (one id per counted message): written
    /// compact, not pretty-printed.
    func saveTokenStats(_ t: TokenStats) {
        guard let d = try? compactEncoder.encode(t) else { return }
        try? Vault.atomicWrite(d, to: paths.tokenStatsFile, mode: 0o600)
    }
    private let compactEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: d)
    }

    private func write<T: Encodable>(_ v: T, _ url: URL) {
        guard let d = try? encoder.encode(v) else { return }
        try? Vault.atomicWrite(d, to: url, mode: 0o600)
    }

    /// Temp file next to the (symlink-resolved) target, fsync, then rename over it.
    static func atomicWrite(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        let target = url.resolvingSymlinksInPath()
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: mode]),
              let fh = try? FileHandle(forWritingTo: tmp) else {
            throw KeychainError(message: "could not create \(tmp.lastPathComponent)")
        }
        do {
            try fh.write(contentsOf: data)
            try fh.synchronize()
            try fh.close()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        if rename(tmp.path, target.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw KeychainError(message: "rename failed for \(target.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// Keeps a folder out of Time Machine (snapshots hold encrypted login state).
    static func excludeFromBackup(_ dir: URL) {
        var u = dir
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// 0700 for directories, 0600 for files, recursively.
    static func tightenModes(_ root: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return }
        try? fm.setAttributes([.posixPermissions: isDir.boolValue ? 0o700 : 0o600], ofItemAtPath: root.path)
        guard isDir.boolValue, let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let u as URL in e {
            let d = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? fm.setAttributes([.posixPermissions: d ? 0o700 : 0o600], ofItemAtPath: u.path)
        }
    }

    // MARK: Keychain-backed secrets

    func cliCreds(for id: String) throws -> CLICreds? {
        guard let d = try Keychain.read(service: paths.vaultService, account: "\(id):cli") else { return nil }
        return CLICreds(data: d)
    }
    func saveCLICreds(_ creds: CLICreds, for id: String) throws {
        try Keychain.write(service: paths.vaultService, account: "\(id):cli", data: creds.data)
    }
    func desktopConfig(for id: String) throws -> [String: Any]? {
        guard let d = try Keychain.read(service: paths.vaultService, account: "\(id):desktop-config") else { return nil }
        return try JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    func saveDesktopConfig(_ keys: [String: Any], for id: String) throws {
        let d = try JSONSerialization.data(withJSONObject: keys, options: [.sortedKeys])
        try Keychain.write(service: paths.vaultService, account: "\(id):desktop-config", data: d)
    }
    /// Backup of the whole CLI keychain item, kept in the keychain.
    func saveCLIBackup(_ data: Data) throws {
        try Keychain.write(service: paths.vaultService, account: "backup:cli-latest", data: data)
    }

    func saveDesktopConfigBackup(_ keys: [String: Any]) throws {
        let d = try JSONSerialization.data(withJSONObject: keys, options: [.sortedKeys])
        try Keychain.write(service: paths.vaultService, account: "backup:desktop-config-latest", data: d)
    }

    func desktopSnapshotDir(for id: String) -> URL { paths.desktopSnapshots.appendingPathComponent(id) }

    func removeAccount(id: String) throws {
        try Keychain.delete(service: paths.vaultService, account: "\(id):cli")
        try Keychain.delete(service: paths.vaultService, account: "\(id):desktop-config")
        try? FileManager.default.removeItem(at: desktopSnapshotDir(for: id))
        saveAccounts(loadAccounts().filter { $0.id != id })
    }

    func deleteAllSecrets(ids: [String]) {
        for id in ids {
            try? Keychain.delete(service: paths.vaultService, account: "\(id):cli")
            try? Keychain.delete(service: paths.vaultService, account: "\(id):desktop-config")
        }
        try? Keychain.delete(service: paths.vaultService, account: "backup:cli-latest")
        try? Keychain.delete(service: paths.vaultService, account: "backup:desktop-config-latest")
    }
}
