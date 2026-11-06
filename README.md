# Clarping

A native macOS menu bar app that keeps several Claude accounts linked on one Mac, shows their rate-limit usage, and switches the login that Claude Code (and optionally Claude Desktop) uses.

![Popover](docs/screenshots/popover.png)

## What it does

- **Menu bar**: a four-point spark glyph with a thin arc showing the active account's 5-hour utilization, plus compact text such as `42% · 1h 12m` (toggle in Settings). The spark rotates and breathes while a switch is in progress; Reduce Motion disables that.
- **Popover**: one card per linked account with soft gauges for the 5-hour window, the weekly window and any per-model weekly limit the API reports (for example Fable), reset times, and a burn-rate projection for the active account. Click another card, confirm, and Clarping switches to it. Progress and errors ("Re-login needed") show inline.
- **Dashboard** (Open Clarping, or Cmd-, for Settings): tokens by account and by model family for today / this week / this month / last month, an approximate API-equivalent cost, a 30-day daily chart, a 24-hour chart of the active account's limits, and the switch history. Data comes from Claude Code's own session logs.
- **Poller**: every N minutes (default 3) it fetches usage for every linked account, refreshes stored tokens of inactive accounts when they are about to expire, posts notifications when a limit crosses 80% or 95%, and highlights the least-used account when the active one reaches 95%.

![Dashboard](docs/screenshots/dashboard.png)

## Build and install

Requirements: macOS 14 or later, Swift 5.9+ (Command Line Tools are enough; no Xcode needed).

```sh
scripts/build-app.sh          # swift build -c release, then assembles build/Clarping.app
open build/Clarping.app
```

`scripts/make-icon.sh` draws the app icon in code and packages it as `.icns`; `build-app.sh` runs it when the icon is missing. The bundle is ad-hoc signed (`codesign -s -`). Copy `build/Clarping.app` to `/Applications` if you want "Launch at login" to work reliably.

Useful flags:

```sh
build/Clarping.app/Contents/MacOS/Clarping --add-current             # capture the active login headlessly
build/Clarping.app/Contents/MacOS/Clarping --dry-run-selftest /tmp/h  # exercise capture -> switch -> verify against fake files
```

## How linking works

"Add account" (or `--add-current`) reads the login that is active right now and stores it in Clarping's vault. Nothing of Claude's is modified by this step. To link a second account: sign out and in with `claude` (and in Claude Desktop, if you use it), then press "Add account" again.

What is read:

| Source | What is taken |
| --- | --- |
| Keychain item `Claude Code-credentials` (account = your user name) | only the `claudeAiOauth` block |
| `~/.claude.json` | only the `oauthAccount` block |
| `~/Library/Application Support/Claude/` | `Cookies`, `Cookies-journal`, `Local Storage`, `Session Storage`, `IndexedDB/https_claude.ai_0.indexeddb.leveldb`, `IndexedDB/https_claude.ai_0.indexeddb.blob` |
| `~/Library/Application Support/Claude/config.json` | only the keys `oauth:tokenCache`, `oauth:tokenCacheV2`, `lastKnownAccountUuid`, `bootSideSessions` |

Where it goes:

| Vault location | Contents |
| --- | --- |
| Keychain service `Clarping`, account `<accountId>:cli` | the `claudeAiOauth` JSON |
| Keychain service `Clarping`, account `<accountId>:desktop-config` | the four Desktop config keys |
| `~/Library/Application Support/Clarping/desktop/<accountId>/` (mode 0700) | copies of the Desktop auth files |
| `~/Library/Application Support/Clarping/accounts.json` | label, color, email, org, the `oauthAccount` block (no secrets) |
| `~/Library/Application Support/Clarping/*.json` | settings, usage snapshots, switch log, token statistics (no secrets) |

## How switching works

1. If Claude Desktop is running and Desktop switching is on, quit it (AppleScript `quit`, then wait until the process is gone) so its files are quiescent.
2. Re-capture the active account into the vault (refresh tokens rotate, so the vault must hold whatever the CLI holds now).
3. Back up: `~/.claude.json` to `~/Library/Application Support/Clarping/backups/<timestamp>-claude.json` (0600, last 20 kept); the whole Claude Code keychain item and Desktop's login keys are backed up inside the keychain (`Clarping` / `backup:cli-latest` and `backup:desktop-config-latest`), never on disk.
4. Write the target's `claudeAiOauth` into the `Claude Code-credentials` item. Every other key in that item, notably `mcpOAuth` with the MCP server logins, is preserved byte for byte.
5. Patch `~/.claude.json`: replace `oauthAccount`, drop the account-keyed caches `cachedUsageUtilization`, `cachedArtifactRoster`, `passesEligibilityCache`, `overageCreditGrantCache` so they refresh. Nothing else is touched (`userID`, `anonymousId`, `machineID`, `projects`, `mcpServers`, `providerProfiles` and the rest stay as they are; key order may change). Written atomically via a temp file and rename, keeping the original file mode.
6. Restore the target's Desktop auth files and merge its four config keys into `config.json` at key level, then relaunch Desktop if it was running.
7. Log the switch (used to attribute tokens in the dashboard).

If anything fails after step 4, the keychain item and `~/.claude.json` are rolled back to their pre-switch contents and Desktop is relaunched. Polling pauses while a switch runs.

The active account is never token-refreshed by Clarping: its refresh token belongs to the CLI, and rotating it from outside would log the CLI out. Clarping reads the active login from the keychain on every poll and, before filing it under an account, confirms with the profile endpoint that the token really belongs to that account id.

All file and keychain locations live in one `Paths` struct, so the self-test runs the real `Switcher` against a temporary HOME and the throwaway keychain services `Clarping-Test` / `Clarping-Test-CLI`, then cleans up.

## Limitations

- **Desktop cookies are machine-bound.** Claude Desktop encrypts cookie values with the `Claude Safe Storage` keychain key; Clarping copies the encrypted files as they are, so a vault only works on the Mac that captured it. Desktop also keeps caches of web state outside the copied files; if it looks confused after a switch, sign out and in once and re-capture.
- **Claude Code caches the keychain read for about 30 seconds**, and a running `claude` session keeps using the token it already has until you restart it. Start new sessions after switching.
- **Desktop's Code tab / Cowork** already keep their own per-account data; Clarping does not touch `claude-code-sessions/`, `local-agent-mode-sessions/`, `scratch-workspaces/`, `vm_bundles/` or `claude_desktop_config.json`.
- **Cost is approximate.** It applies public API list prices (Opus and Fable $15/$75, Sonnet $3/$15, Haiku $1/$5 per million tokens; cache read 10% and cache write 125% of the input price) to the token counts in Claude Code's logs. Subscriptions are not billed per token; the number is only a sense of scale.
- **Token attribution** uses Clarping's own switch log. Tokens logged before the first switch belong to the single linked account if there is exactly one, otherwise they show as "Unattributed".
- **Refresh tokens expire.** When an inactive account's refresh fails, its card shows "Re-login needed": sign in with `claude`, then re-capture it.
- **Keychain writes go through `/usr/bin/security`** (the same tool Claude Code uses, so no ACL prompts). The payload is passed as a hex argument, which is briefly visible to other processes of the same user; those processes could read the keychain item directly anyway.
- Built with the Command Line Tools toolchain only; `@State` is unavailable there (no SwiftUI macro plugin), so views keep local state in `@StateObject` boxes.

## Repository layout

```
Package.swift
Sources/Clarping/
  Main.swift            entry point, CLI flags, window management
  AppState.swift        observable state, poller, notifications, projections
  Core/Paths.swift      every path and keychain service name (real vs. test)
  Core/Keychain.swift   /usr/bin/security wrapper
  Core/Models.swift     Account, CLICreds, UsageSnapshot, Settings, formatting
  Core/Vault.swift      Clarping's own storage
  Core/ClaudeAPI.swift  token refresh, usage, profile
  Core/Switcher.swift   capture and switch flow
  Core/TokenIngest.swift incremental JSONL ingestion, pricing
  Core/SelfTest.swift   --dry-run-selftest
  UI/                   popover, dashboard, settings, gauges, menu bar glyph, theme
scripts/build-app.sh    swift build + .app assembly + codesign
scripts/make-icon.sh    code-drawn icon -> .icns
docs/screenshots/
```
