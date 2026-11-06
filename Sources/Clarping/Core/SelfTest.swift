import Foundation

/// `clarping --dry-run-selftest <tmpHome>`: exercises capture -> switch -> verify
/// against fake files under a temporary HOME and the throwaway keychain
/// services `Clarping-Test` / `Clarping-Test-CLI`. Never touches the real login.
enum SelfTest {
    struct Failure: Error { let msg: String }

    static func run(home: URL) -> Int32 {
        // The temp HOME is deleted at the end, so it must be a fresh path: never
        // the real home, and never an existing non-empty directory.
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let target = home.standardizedFileURL.path
        if target == real || real.hasPrefix(target + "/") || target == "/" {
            print("FAIL  refusing to use \(target) as the self-test HOME")
            return 2
        }
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: target), !existing.isEmpty {
            print("FAIL  \(target) exists and is not empty; pass a new path")
            return 2
        }
        var failures = 0
        func check(_ name: String, _ cond: @autoclosure () throws -> Bool) {
            let ok = (try? cond()) ?? false
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let paths = Paths.test(home: home)
        var ids: [String] = ["11111111-aaaa-4aaa-8aaa-111111111111", "22222222-bbbb-4bbb-8bbb-222222222222"]
        defer {
            Vault(paths: paths).deleteAllSecrets(ids: ids)
            try? Keychain.delete(service: paths.cliService, account: paths.cliAccount)
            try? fm.removeItem(at: home)   // only ever the empty/new directory checked above
            print("cleaned up temp HOME and test keychain items")
        }

        do {
            try? fm.removeItem(at: home)
            try fm.createDirectory(at: paths.desktopDir.appendingPathComponent("IndexedDB"), withIntermediateDirectories: true)
            // Fake ~/.claude.json with keys that must survive untouched.
            let cfgA: [String: Any] = [
                "userID": "u-keep", "machineID": "m-keep", "projects": ["/x": ["k": 1]], "mcpServers": ["s": ["cmd": "x"]],
                "cachedUsageUtilization": ["stale": true],
                "oauthAccount": ["accountUuid": ids[0], "emailAddress": "alpha@example.com", "organizationName": "Alpha Org", "displayName": "Alpha"],
            ]
            try JSONSerialization.data(withJSONObject: cfgA).write(to: paths.claudeJSON)
            // Fake CLI keychain item: mcpOAuth must be preserved, claudeAiOauth swapped.
            let item: [String: Any] = [
                "mcpOAuth": ["server-one": ["accessToken": "mcp-fake-1"], "server-two": ["accessToken": "mcp-fake-2"]],
                "claudeAiOauth": ["accessToken": "fake-at-A", "refreshToken": "fake-rt-A", "expiresAt": 1_900_000_000_000.0, "scopes": ["user:profile"], "subscriptionType": "max"],
            ]
            try Keychain.write(service: paths.cliService, account: paths.cliAccount, data: JSONSerialization.data(withJSONObject: item))
            // Fake Desktop auth.
            try Data("cookies-A".utf8).write(to: paths.desktopDir.appendingPathComponent("Cookies"))
            try fm.createDirectory(at: paths.desktopDir.appendingPathComponent("Local Storage/leveldb"), withIntermediateDirectories: true)
            try Data("ls-A".utf8).write(to: paths.desktopDir.appendingPathComponent("Local Storage/leveldb/000.log"))
            let dcfgA: [String: Any] = ["oauth:tokenCache": "tc-A", "lastKnownAccountUuid": ids[0], "locale": "en-US", "userThemeMode": "dark"]
            try JSONSerialization.data(withJSONObject: dcfgA).write(to: paths.desktopConfig)

            let vault = Vault(paths: paths)
            let sw = Switcher(paths: paths, vault: vault)
            var accounts = vault.loadAccounts()

            // 1. capture A
            var captured: Account?
            var capErr: Error?
            let sem0 = DispatchSemaphore(value: 0)
            Task {
                do { captured = try await sw.captureCurrent(into: &accounts, desktop: .alreadyQuiet) } catch { capErr = error }
                sem0.signal()
            }
            sem0.wait()
            if let capErr { throw capErr }
            let a = captured!
            vault.saveAccounts(accounts)
            check("capture: account id from oauthAccount", a.id == ids[0])
            check("capture: label/email/org read", a.label == "Alpha" && a.email == "alpha@example.com" && a.orgName == "Alpha Org")
            check("capture: CLI creds stored in vault keychain", try vault.cliCreds(for: ids[0])?.accessToken == "fake-at-A")
            check("capture: desktop cookie snapshot", (try? String(contentsOf: vault.desktopSnapshotDir(for: ids[0]).appendingPathComponent("Cookies"))) == "cookies-A")
            check("capture: desktop config keys in keychain", try (vault.desktopConfig(for: ids[0])?["oauth:tokenCache"] as? String) == "tc-A")
            check("capture: desktop config non-login keys not captured", try vault.desktopConfig(for: ids[0])?["locale"] == nil)
            let perms = try fm.attributesOfItem(atPath: vault.desktopSnapshotDir(for: ids[0]).path)[.posixPermissions] as? Int
            check("capture: snapshot dir is 0700", perms == 0o700)

            // 2. seed account B directly into the vault (as if captured earlier)
            let b = Account(id: ids[1], label: "Beta", colorHex: "6F8F7A", email: "beta@example.org", orgName: "Beta Org", createdAt: Date(), lastCaptured: Date(),
                            oauthAccount: ["accountUuid": .string(ids[1]), "emailAddress": .string("beta@example.org"), "organizationName": .string("Beta Org")],
                            hasDesktopSnapshot: true, needsRelogin: false)
            accounts.append(b)
            try vault.saveCLICreds(CLICreds(raw: ["accessToken": "fake-at-B", "refreshToken": "fake-rt-B", "expiresAt": 1_900_000_000_000.0, "scopes": ["user:profile"]]), for: ids[1])
            let bDir = vault.desktopSnapshotDir(for: ids[1])
            try fm.createDirectory(at: bDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("cookies-B".utf8).write(to: bDir.appendingPathComponent("Cookies"))
            try vault.saveDesktopConfig(["oauth:tokenCache": "tc-B", "lastKnownAccountUuid": ids[1]], for: ids[1])
            vault.saveAccounts(accounts)

            // 3. switch A -> B
            var steps: [SwitchStep] = []
            let sem = DispatchSemaphore(value: 0)
            var switchErr: Error?
            Task {
                do { try await sw.switchTo(b, accounts: &accounts, includeDesktop: true) { steps.append($0) } } catch { switchErr = error }
                sem.signal()
            }
            sem.wait()
            check("switch: completed without error", switchErr == nil)
            if let switchErr { print("       error: \(switchErr.localizedDescription)") }
            check("switch: steps reported", steps.first == .capturing && steps.last == .done && steps.contains(.restoringDesktop))
            let itemAfter = try sw.readCLIItem()
            let oauthAfter = itemAfter["claudeAiOauth"] as? [String: Any]
            check("switch: keychain claudeAiOauth is B", oauthAfter?["accessToken"] as? String == "fake-at-B")
            check("switch: keychain mcpOAuth preserved", (itemAfter["mcpOAuth"] as? [String: Any])?.count == 2)
            let cfgAfter = try sw.readClaudeJSON()
            check("switch: oauthAccount is B", (cfgAfter["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == ids[1])
            check("switch: userID/machineID/projects/mcpServers untouched",
                  cfgAfter["userID"] as? String == "u-keep" && cfgAfter["machineID"] as? String == "m-keep"
                  && (cfgAfter["projects"] as? [String: Any])?.count == 1 && (cfgAfter["mcpServers"] as? [String: Any])?.count == 1)
            check("switch: account-keyed cache dropped", cfgAfter["cachedUsageUtilization"] == nil)
            check("switch: desktop cookies restored", (try? String(contentsOf: paths.desktopDir.appendingPathComponent("Cookies"))) == "cookies-B")
            check("switch: desktop item without B snapshot removed", !fm.fileExists(atPath: paths.desktopDir.appendingPathComponent("Local Storage").path))
            let dcfgAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.desktopConfig)) as? [String: Any]
            check("switch: desktop config login keys replaced", dcfgAfter?["oauth:tokenCache"] as? String == "tc-B" && dcfgAfter?["lastKnownAccountUuid"] as? String == ids[1])
            check("switch: desktop config other keys preserved", dcfgAfter?["locale"] as? String == "en-US" && dcfgAfter?["userThemeMode"] as? String == "dark")
            let backups = (try? fm.contentsOfDirectory(atPath: paths.backups.path)) ?? []
            check("switch: ~/.claude.json backup written", backups.contains { $0.hasSuffix("-claude.json") })
            let leaked = backups.contains { (try? String(contentsOf: paths.backups.appendingPathComponent($0)))?.contains("oauth:tokenCache") ?? false }
            check("switch: no Desktop token cache in plain backups", !leaked)
            check("switch: desktop config backup in keychain", try Keychain.read(service: paths.vaultService, account: "backup:desktop-config-latest") != nil)
            check("switch: A's creds re-captured into vault", try vault.cliCreds(for: ids[0])?.accessToken == "fake-at-A")

            // 4. switch back B -> A
            var err2: Error?
            let sem2 = DispatchSemaphore(value: 0)
            let aAcc = accounts[0]
            Task {
                do { try await sw.switchTo(aAcc, accounts: &accounts, includeDesktop: true) { _ in } } catch { err2 = error }
                sem2.signal()
            }
            sem2.wait()
            check("switch back: completed", err2 == nil)
            if let err2 { print("       error: \(err2.localizedDescription)") }
            check("switch back: keychain is A again", (try sw.readCLIItem()["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "fake-at-A")
            check("switch back: B's creds stored", try vault.cliCreds(for: ids[1])?.accessToken == "fake-at-B")
            check("switch back: cookies are A", (try? String(contentsOf: paths.desktopDir.appendingPathComponent("Cookies"))) == "cookies-A")
            check("switch back: Local Storage restored", fm.fileExists(atPath: paths.desktopDir.appendingPathComponent("Local Storage/leveldb/000.log").path))

            // 4b. a failing switch rolls the keychain and ~/.claude.json back
            try Data("not json".utf8).write(to: paths.desktopConfig)
            var err3: Error?
            let sem3 = DispatchSemaphore(value: 0)
            let bAcc = accounts[1]
            Task {
                do { try await sw.switchTo(bAcc, accounts: &accounts, includeDesktop: true) { _ in } } catch { err3 = error }
                sem3.signal()
            }
            sem3.wait()
            check("rollback: corrupt Desktop config.json makes the switch fail", err3 != nil)
            check("rollback: keychain restored to A", (try sw.readCLIItem()["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "fake-at-A")
            check("rollback: oauthAccount restored to A", (try sw.readClaudeJSON()["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == ids[0])
            check("rollback: corrupt config.json left untouched", (try? String(contentsOf: paths.desktopConfig)) == "not json")
            try JSONSerialization.data(withJSONObject: dcfgA).write(to: paths.desktopConfig)

            // 4c. a failure midway through the Desktop file restore puts the
            // previous Desktop files back too. B's snapshot gains an IndexedDB
            // entry whose live parent is a plain file, so the copy fails after
            // Cookies have already been replaced.
            let idb = "IndexedDB/https_claude.ai_0.indexeddb.leveldb"
            try fm.createDirectory(at: bDir.appendingPathComponent(idb), withIntermediateDirectories: true)
            try Data("idb-B".utf8).write(to: bDir.appendingPathComponent(idb + "/CURRENT"))
            try fm.removeItem(at: paths.desktopDir.appendingPathComponent("IndexedDB"))
            try Data("blocker".utf8).write(to: paths.desktopDir.appendingPathComponent("IndexedDB"))
            var err4: Error?
            let sem4 = DispatchSemaphore(value: 0)
            Task {
                do { try await sw.switchTo(bAcc, accounts: &accounts, includeDesktop: true) { _ in } } catch { err4 = error }
                sem4.signal()
            }
            sem4.wait()
            check("rollback: mid-restore Desktop failure makes the switch fail", err4 != nil)
            check("rollback: Desktop cookies restored to A", (try? String(contentsOf: paths.desktopDir.appendingPathComponent("Cookies"))) == "cookies-A")
            check("rollback: Desktop Local Storage restored to A", (try? String(contentsOf: paths.desktopDir.appendingPathComponent("Local Storage/leveldb/000.log"))) == "ls-A")
            check("rollback: keychain still A", (try sw.readCLIItem()["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "fake-at-A")
            let desktopBackups = (try? fm.contentsOfDirectory(atPath: paths.backups.path))?.filter { $0.hasSuffix("-desktop") } ?? []
            check("rollback: Desktop file backup folder written", !desktopBackups.isEmpty)
            try fm.removeItem(at: paths.desktopDir.appendingPathComponent("IndexedDB"))
            try fm.removeItem(at: bDir.appendingPathComponent("IndexedDB"))

            // 5. token ingest on a fake session log
            let proj = paths.claudeProjects.appendingPathComponent("p")
            try fm.createDirectory(at: proj, withIntermediateDirectories: true)
            let now = Format.iso.string(from: Date())
            let line = #"{"type":"assistant","timestamp":"\#(now)","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-1","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}"#
            try (line + "\n" + line + "\n" + #"{"type":"user","message":{}}"# + "\n").data(using: .utf8)!.write(to: proj.appendingPathComponent("s.jsonl"))
            var stats = TokenStats()
            TokenIngest.ingest(stats: &stats, projects: paths.claudeProjects, attribute: { _ in ids[0] })
            let bucket = stats.buckets[TokenStats.key(day: DayKey.of(Date()), account: ids[0], family: "Opus")]
            check("ingest: dedupes by message id + requestId", bucket == TokenBucket(input: 10, output: 5, cacheRead: 100, cacheWrite: 20))
            let before = stats
            TokenIngest.ingest(stats: &stats, projects: paths.claudeProjects, attribute: { _ in ids[0] })
            check("ingest: second pass is a no-op", stats.buckets == before.buckets)
            check("ingest: cost estimate", abs(Pricing.cost(family: "Opus", bucket!) - (10 * 15 + 5 * 75 + 100 * 1.5 + 20 * 18.75) / 1e6) < 1e-9)

            // 6. remove account
            try vault.removeAccount(id: ids[1])
            check("remove: secrets and snapshot gone", try vault.cliCreds(for: ids[1]) == nil && !fm.fileExists(atPath: bDir.path))
            ids = [ids[0]]
        } catch {
            print("FAIL  selftest aborted: \(error.localizedDescription)")
            failures += 1
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
