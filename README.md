<img src="assets/brand/icon-1024.png" width="96" alt="Clarping app icon">

# Clarping

Clarping is a macOS menu bar app that switches the Claude account used by Claude Code (the `claude` CLI) and Claude Desktop, both at once. I'm on a Max plan, I hit the 5-hour limit often, and I keep a second account for when that happens. Signing out and back in to both apps every time got old, so Clarping does it in one click. Only the login is swapped. Projects, sessions, MCP servers and settings stay as they are.

The menu bar popover also shows each linked account's 5-hour, weekly and Fable limits with their reset times and a plan badge (Max 5x, Max 20x, Pro). A dashboard counts tokens per account, model and day from Claude Code's local logs.

The name is "larp" plus "clauding".

Clarping is not made by or affiliated with Anthropic. It depends on undocumented files and endpoints; see [Limitations](#limitations).

<img src="docs/screenshots/popover.png" width="344" alt="Clarping popover with two linked accounts and their limits">

## Requirements

- macOS 14 (Sonoma) or later. On macOS 26 and later the UI uses Liquid Glass; earlier versions get a solid fallback.
- Swift 5.9 or later. The Xcode Command Line Tools are enough (`xcode-select --install`); you don't need Xcode.
- Claude Code, signed in at least once with `claude /login`. Claude Desktop is optional.

## Build and install

From the repository root:

```sh
scripts/build-app.sh
open build/Clarping.app
```

`build-app.sh` runs `swift build -c release`, assembles `build/Clarping.app`, draws the icon with `scripts/make-icon.sh` if it isn't built yet, and ad-hoc signs the bundle.

To keep it, copy it to `/Applications`. Launch at login works more reliably from there.

```sh
cp -R build/Clarping.app /Applications/
```

Clarping has no Dock icon. Look for the spark in the menu bar. On first launch it opens a seven-step setup guide that checks what `claude` and Claude Desktop are signed in as. You can reopen the guide from Settings.

## Setup

Link each account once. Clarping reads the login that is active right now, checks the token against Anthropic's profile endpoint, and stores a copy. Linking changes nothing of Claude's.

### Claude Code CLI

1. In Terminal, run `claude /login` and sign in with account A.
2. In the Clarping popover, click Add account.
3. Run `claude /login` again with account B, then click Add account again.
4. Repeat for any further accounts.

If Add says the account is already linked, `claude` is still signed in to that account. Sign in to a different one first.

What a switch changes for the CLI:

- The keychain item `Claude Code-credentials` (account: your macOS user name). Clarping replaces only its `claudeAiOauth` block and updates the item in place, so Claude Code keeps reading it without prompts. Other keys in the item, such as `mcpOAuth` with your MCP server logins, are kept.
- In `~/.claude.json`, the `oauthAccount` block is replaced and four account-specific caches are dropped so they refresh (`cachedUsageUtilization`, `cachedArtifactRoster`, `passesEligibilityCache`, `overageCreditGrantCache`). Everything else in the file (`projects`, `mcpServers`, `userID` and so on) stays. Key order may change.

Nothing under `~/.claude/` is touched. Your projects, session history and settings are shared by all accounts.

### Claude Desktop

1. Sign in to Claude Desktop with the same account `claude` is signed in to.
2. Quit Claude Desktop, then click Add account. Add never quits Desktop: if Desktop is running, Add links the CLI login only and tells you Desktop was skipped. You can also add first and then click Re-capture for that account in Settings, which quits Desktop, copies its login and reopens it.
3. Repeat for each account.

Clarping only saves a Desktop login while Desktop holds a live claude.ai session and reports the same account as the CLI. Otherwise it saves the CLI login alone and explains why.

During a switch, Clarping quits Claude Desktop (if it is running), swaps its login files and reopens it. The first time, macOS asks whether Clarping may control Claude. Allow it, or find it later in System Settings > Privacy & Security > Automation.

Files swapped, inside `~/Library/Application Support/Claude/`:

- `Cookies` and `Cookies-journal`
- `Local Storage` and `Session Storage`
- `IndexedDB/https_claude.ai_0.indexeddb.leveldb` and `IndexedDB/https_claude.ai_0.indexeddb.blob`
- In `config.json`, only the keys `oauth:tokenCache`, `oauth:tokenCacheV2`, `lastKnownAccountUuid` and `bootSideSessions`, merged at key level

Everything else in that folder is left alone, including Code tab and Cowork sessions (`claude-code-sessions/`, `local-agent-mode-sessions/`), `scratch-workspaces/`, `vm_bundles/` and `claude_desktop_config.json`.

Don't use Log out in Claude Desktop for an account Clarping has saved. Logging out revokes that session on the server, and the saved copy then restores to the sign-in screen. To fix it, sign in again and Re-capture.

To switch only the CLI, turn off "Also switch Claude Desktop" in Settings. It is on by default.

### The keychain prompt

On the first real switch, macOS asks whether Clarping may use the `Claude Code-credentials` keychain item. Choose Always Allow. The build is ad-hoc signed, so each rebuild gives the app a new identity and the prompt comes back once.

## Switching

Click an account card in the popover, then click Switch. If any `claude` processes are running, the confirmation says how many. Restart them after the switch: a running session keeps the old login until it restarts, and it may write `~/.claude.json` while the switch runs.

What happens, in order:

1. If Desktop switching applies, Clarping asks Claude Desktop to quit (AppleScript) and waits until its helper processes are gone.
2. It saves the current login back into its vault, because refresh tokens rotate and the vault needs the latest one. It also files Desktop's live login under the account Desktop reports.
3. It makes backups (below).
4. It writes the target account's `claudeAiOauth` into the `Claude Code-credentials` item.
5. It patches `~/.claude.json` as described above, writing atomically and keeping the file's permissions.
6. It restores the target's Desktop files and config keys, then reopens Desktop if it was running.
7. It records the switch in its log, which the dashboard uses to attribute tokens.

If a step after the backup fails, Clarping restores the previous keychain item, `oauthAccount` and Desktop files, reopens Desktop, and shows the error on the card. Polling pauses while a switch runs.

Clarping never refreshes the active account's token. That refresh token belongs to the running CLI, and rotating it from outside would log the CLI out. Inactive accounts are refreshed from the vault only after their access token has expired.

### Backups and manual restore

Each switch writes, under `~/Library/Application Support/Clarping/backups/`:

- `<timestamp>-claude.json`, a copy of `~/.claude.json` (mode 0600)
- `<timestamp>-desktop/`, a copy of the Desktop login files, when Desktop is switched (mode 0700)

The 20 newest entries in that folder are kept. A switch that includes Desktop writes two entries, so that is about 10 switches. The previous `Claude Code-credentials` item and Desktop config keys are saved in the keychain under service `Clarping`, accounts `backup:cli-latest` and `backup:desktop-config-latest`. Only the latest copy is kept.

To restore by hand:

- The simplest fix is to sign in again: `claude /login` for the CLI, and sign in inside Claude Desktop.
- For `~/.claude.json`, copy the `oauthAccount` block from a backup into the current file with no `claude` running. Copying the whole file back also reverts any project state that changed since.
- For Desktop, quit it, then copy the items from a `<timestamp>-desktop/` folder back into `~/Library/Application Support/Claude/`.

## Dashboard and settings

<img src="docs/screenshots/dashboard.png" width="560" alt="Clarping dashboard with token counts by account and model">

Open Clarping from the popover to get the dashboard:

- Input, output, cache read and cache write tokens by account and by model family (Opus, Sonnet, Fable, Haiku, Other) for today, this week, this month and last month
- Daily tokens for the last 30 days
- The active account's limits over the last 24 hours
- Switch history

Token data comes from Claude Code's session logs in `~/.claude/projects/` (the last 62 days, read incrementally, at most once a minute). The dashboard shows token counts only, not cost. Tokens are attributed using Clarping's switch log, so usage from before the first switch goes to the account that switch started from, or to the active account if you have never switched.

Settings (Cmd-, or the gear in the popover) has the poll interval (default 3 minutes), usage text in the menu bar, notifications when a 5-hour or weekly limit crosses 80% or 95%, a hint pointing to the least-used account once the active one reaches 95%, Desktop switching, launch at login, and the setup guide. The account list lets you rename an account, pick its color, Re-capture the active one, or remove one. Removing an account deletes its keychain entries and Desktop copy.

## Privacy and security

- Login tokens are kept only in the macOS keychain, under service `Clarping`: `<accountId>:cli` holds the `claudeAiOauth` block and `<accountId>:desktop-config` holds the four Desktop config keys.
- Secrets never go on a command line or into the environment. The `Claude Code-credentials` item is read with `security find-generic-password -w` over a pipe and written with `SecItemUpdate`.
- `~/Library/Application Support/Clarping/` (mode 0700) holds `accounts.json` (label, color, email, organization, the `oauthAccount` block), `settings.json`, `usage-snapshots.json`, `switch-log.json` and `token-stats.json`, all mode 0600 with no tokens in them.
- `desktop/<accountId>/` holds each account's copy of the Desktop login files, and `backups/` holds the backups. Both are 0700 with 0600 files and excluded from Time Machine. Desktop encrypts its cookie values with a key in this Mac's keychain; Clarping copies the files as they are. A `~/.claude.json` backup has no login tokens but can contain MCP server settings.
- The only network requests go to Anthropic:
  - `https://api.anthropic.com/api/oauth/usage` for limits
  - `https://api.anthropic.com/api/oauth/profile` to confirm which account a token belongs to
  - `https://platform.claude.com/v1/oauth/token` to refresh an inactive account's token
- No telemetry, analytics or update checks. Notifications are local.

## Limitations

- Clarping is unofficial. It relies on the format of Claude Code's keychain item, `~/.claude.json`, Claude Desktop's storage, and OAuth endpoints that Anthropic does not document. Any Claude Code or Desktop update can break it.
- It calls those endpoints with Claude Code's public OAuth client ID and a `claude-cli` user agent string.
- You are responsible for complying with Anthropic's terms for your accounts and plans. Check them before using more than one account this way.
- Running `claude` sessions keep the old login until restarted. A `claude` process writing `~/.claude.json` at the exact moment of a switch can lose that write.
- Desktop login copies only work on the Mac that made them, because Desktop's cookie encryption key lives in this Mac's keychain. If Desktop looks confused after a switch, sign out and in once (see the Log out warning above) and Re-capture.
- Refresh tokens rotate. If a `claude` session of an inactive account refreshed its token first, the stored copy is rejected and the card says the login was rotated elsewhere. Make that account active with `claude /login` and Re-capture it.
- The app is ad-hoc signed, so the keychain prompt returns after every rebuild.
- Token attribution follows Clarping's switch log, so usage from a session that kept running on the old login after a switch is counted against the new account.

## Troubleshooting

Clarping freezes or uses a lot of CPU. Quit it with the power button in the popover, or with `killall Clarping` if the popover doesn't open. Please report it with your macOS version and what you were doing. A `sample Clarping 5 > clarping-sample.txt` taken while it is stuck helps.

Keychain prompts keep appearing. Choose Always Allow, not Allow. After a rebuild one prompt is expected. If you clicked Deny, the switch fails and leaves everything as it was; switch again and allow it.

Claude Desktop didn't switch. Check System Settings > Privacy & Security > Automation and allow Clarping to control Claude. Check that "Also switch Claude Desktop" is on and that the account shows "Desktop" in its Settings row. If it doesn't, sign Desktop in to that account, make it the active account and click Re-capture. "Claude Desktop did not quit in time" means Desktop or one of its helpers stayed open; quit it yourself and switch again.

"Already linked" when adding. `claude` is still signed in to an account you already added. Run `claude /login` with another account first. To refresh the saved copy of the current account, use Re-capture in Settings.

"No Claude Code keychain item exists". Run `claude /login` once. Clarping won't create that item itself, because one it creates would make Claude Code prompt on every read.

"Re-login needed" or "Stored login was rotated elsewhere". Make that account active with `claude /login`, then Re-capture it.

## Development

```sh
swift build                                  # debug build
scripts/build-app.sh                         # release build and app bundle
build/Clarping.app/Contents/MacOS/Clarping --dry-run-selftest /tmp/clarping-selftest
build/Clarping.app/Contents/MacOS/Clarping --add-current [--relink]
```

`--dry-run-selftest <dir>` runs the real capture, switch and rollback code against fake files in a temporary HOME and the throwaway keychain services `Clarping-Test` and `Clarping-Test-CLI`, prints PASS or FAIL per check, and deletes everything afterward. The directory must be new or empty and can't be your home folder.

`--add-current` links the active login without the UI. It exits 3 if the account is already linked; `--relink` re-captures it instead. It never quits Claude Desktop.

Debug environment variables, all off by default:

| Variable | Effect |
| --- | --- |
| `CLARPING_DEBUG_OPEN_POPOVER=1` | Opens the popover 2 s after launch |
| `CLARPING_DEBUG_CONFIRM=1` | Opens the switch confirmation on the first inactive account at 4 s (UI only) |
| `CLARPING_DEBUG_DRY_SWITCH=1` | Shows the switch-in-progress state for 30 s from 6 s, without touching the keychain or files |
| `CLARPING_DEBUG_POLL_AT=<s>` | Runs one real poll `<s>` seconds after launch |
| `CLARPING_DEBUG_NO_POLL=1` | Skips automatic polling |
| `CLARPING_DEBUG_SHOW=1` | Opens the dashboard window at launch |
| `CLARPING_DEBUG_ONBOARDING=1` | Opens the setup guide at launch |
| `CLARPING_DEBUG_SHOT=<dir>` | With `CLARPING_DEBUG_SHOW=1`, writes the PNGs in `docs/screenshots/` to `<dir>` |
| `CLARPING_DEBUG_FLAT=1` | Draws the solid fallback instead of Liquid Glass (screenshots can't capture system glass) |
| `CLARPING_DEBUG_CHANGES=1` | Logs view re-renders and publish rates to stderr |
| `CLARPING_TRACE=1` | Logs switch and capture step names (never values) to stderr |

All file paths and keychain names live in `Sources/Clarping/Core/Paths.swift`, which is how the self-test swaps in a temporary HOME. The switch flow is in `Core/Switcher.swift`, polling and app state in `AppState.swift`, and the views in `UI/`. The Command Line Tools toolchain has no SwiftUI macro plugin, so views keep local state in `@StateObject` boxes instead of `@State`.

## License

License: TBD
