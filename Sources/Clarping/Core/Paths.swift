import Foundation

/// Every location Clarping reads or writes. The real instance points at the
/// user's home directory; the self-test builds one over a temporary HOME and
/// throwaway keychain service names so nothing real is touched.
struct Paths {
    var home: URL
    var appSupport: URL
    /// Keychain item that Claude Code reads its login from.
    var cliService: String
    var cliAccount: String
    /// Read the CLI item through `/usr/bin/security` (the tool that created it,
    /// so no ACL prompt). false in the self-test, where Clarping creates the item.
    var cliReadViaTool: Bool
    /// Keychain service Clarping stores its own vault under.
    var vaultService: String
    /// Bundle id of Claude Desktop. nil means never quit or relaunch anything.
    var desktopBundleID: String?

    var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    var claudeProjects: URL { home.appendingPathComponent(".claude/projects") }
    var desktopDir: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    var desktopConfig: URL { desktopDir.appendingPathComponent("config.json") }

    var backups: URL { appSupport.appendingPathComponent("backups") }
    var desktopSnapshots: URL { appSupport.appendingPathComponent("desktop") }
    var accountsFile: URL { appSupport.appendingPathComponent("accounts.json") }
    var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    var snapshotsFile: URL { appSupport.appendingPathComponent("usage-snapshots.json") }
    var switchLogFile: URL { appSupport.appendingPathComponent("switch-log.json") }
    var tokenStatsFile: URL { appSupport.appendingPathComponent("token-stats.json") }

    /// Desktop auth files, relative to `desktopDir`. Everything else is left alone.
    static let desktopAuthItems = [
        "Cookies",
        "Cookies-journal",
        "Local Storage",
        "Session Storage",
        "IndexedDB/https_claude.ai_0.indexeddb.leveldb",
        "IndexedDB/https_claude.ai_0.indexeddb.blob",
    ]
    /// Keys in Desktop's config.json that carry the login. Merged at key level.
    static let desktopConfigKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid", "bootSideSessions"]
    /// Account-keyed caches in ~/.claude.json dropped on switch so they refresh.
    static let claudeJSONCacheKeys = ["cachedUsageUtilization", "cachedArtifactRoster", "passesEligibilityCache", "overageCreditGrantCache"]

    static var real: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            home: home,
            appSupport: home.appendingPathComponent("Library/Application Support/Clarping"),
            cliService: "Claude Code-credentials",
            cliAccount: NSUserName(),
            cliReadViaTool: true,
            vaultService: "Clarping",
            desktopBundleID: "com.anthropic.claudefordesktop"
        )
    }

    static func test(home: URL) -> Paths {
        Paths(
            home: home,
            appSupport: home.appendingPathComponent("Library/Application Support/Clarping"),
            cliService: "Clarping-Test-CLI",
            cliAccount: "clarping-selftest",
            cliReadViaTool: false,
            vaultService: "Clarping-Test",
            desktopBundleID: nil
        )
    }
}
