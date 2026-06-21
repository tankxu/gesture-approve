# Changelog

All notable changes to GestureApprove. Versions follow the GitHub releases.

## v0.5.0 — download-and-run (no repo required)

- **The .app is now self-contained.** Previously the app resolved the hook script, MediaPipe, and firmware from the *repo directory* — so a release download (no checkout) had a broken hook path and the whole approval flow silently fell back to the terminal. Now everything ships inside the bundle: `hooks/gesture_hook.py`, `bridge/*` (daemon, setup, requirements), `firmware/flash.sh` + prebuilt binaries, plus the Vision model. Writable data — the MediaPipe venv, the downloaded model, the esptool environment — goes to `~/Library/Application Support/GestureApprove/` (bundles are read-only/signed). New `AppPaths` resolves bundle-first, falling back to the repo for source builds. Hook scripts and Python read their paths from env vars (`GESTURE_MODEL`, `FLASH_VENV`, `GA_*`) so they work in either layout.

## v0.4.2

- **Gemini CLI and Kimi CLI support** (experimental, untested). The shared hook now emits for four targets — Gemini uses a top-level `{"decision":"allow|deny"}` via `BeforeTool`; Kimi reuses the Claude `hookSpecificOutput.permissionDecision` format via `PreToolUse`. Enable them in Settings → Connect AI tools (writes `~/.gemini/settings.json` / `~/.kimi/config.toml`, originals backed up). Derived from each tool's docs/source but **not yet verified end-to-end** — feedback welcome. Both are terminal-CLI only; Kimi may need `/hooks` trust like Codex. Claude Code / Codex paths are unchanged.
- **Long-command card layout.** The command is shown smaller, left-aligned, up to 4 lines; **click the command text to expand/collapse** the full command (hover tooltips don't fire on the borderless panel). The hook no longer truncates at 140 chars (raised to 600) so dangerous fragments hidden at the tail of a long command aren't dropped before the risk highlighting can flag them.

## v0.4.1

- **Fix: approvals could stay stuck on the terminal after overnight sleep.** Lock state was cached from the `screenIsUnlocked` notification, which `DistributedNotificationCenter` can drop or delay when resuming from long sleep / Power Nap. A missed unlock left `screenLocked` stuck `true`, so the gesture card never took over and every approval silently fell back to the CLI prompt (showing up as "sometimes CLI, sometimes gesture"). Lock state is now **queried live via `CGSession` on every approval** instead of cached — a dropped notification can no longer wedge it.

## v0.4.0 — approval context & risk highlighting

- **Approval context on the card.** The card now shows which **project** (the originating `cwd`) and which **tool** is requesting — so when multiple agent sessions run at once, you know what you're approving.
- **Risk highlighting.** Dangerous fragments in the command (`rm -rf`, `… | sh`, `sudo`, force-push, `mkfs`/`dd`, …) are highlighted in red so they catch your eye before you wave a 👍.
- **Works for both Claude Code and Codex CLI** — the shared hook forwards `cwd`/`tool_name`, whose field names match across both, so context shows up everywhere the hook runs.

## v0.3.4

- **Version display + update check.** Settings → General now shows the current version and a **Check for updates** button that queries the GitHub Releases API. When a newer release exists it shows the version and a **Download** link; otherwise "you're on the latest version."

## v0.3.3

- **Settings window refreshes on every open.** The window is reused (closing only hides it), so its state was a stale snapshot — a command you'd just approved with "Always allow" wouldn't show up. It now rebuilds on each open and re-reads the latest data (trusted commands, launch-at-login, engine, etc.).
- **Trusted-commands list is height-capped with internal scroll** (~6 rows), so the list can grow without ever pushing the window past the screen edge.

## v0.3.2 — surviving sleep & lock

Fixes the "after a while the app stops gating" problem at the root.

- **Self-healing approval server.** The local `NWListener` rebuilds itself on `.failed` (with backoff), restarts on wake, and sets `allowLocalEndpointReuse` to avoid the `Address already in use` failure on rebind. This was the actual cause of "stopped working after sleep."
- **Auto-suspend while locked / asleep.** When the screen is locked or the Mac sleeps, approval requests fall straight back to the terminal instead of popping a card no one can act on. State is `screenLocked || asleep`, so waking to a still-locked screen does **not** prematurely resume — it resumes only after a real unlock. Independent of the manual gating switch (never force-enables what you turned off).
- **Crash auto-restart.** Launch-at-login is now a self-managed `LaunchAgent` with `KeepAlive`, so a crashed/killed app is relaunched by launchd. Toggling it no longer restarts the running app.
- **Hook no longer fails silently** — prints an offline notice to the terminal when the app isn't reachable.
- Logging moved from invisible `NSLog` to a file (`/tmp/gestureapprove.log`).

## v0.3.1

- **Codex is CLI-only — made explicit.** The setting is renamed **"Connect Codex CLI"** with an in-app note: Codex hooks run only in the terminal `codex` CLI (the desktop/IDE app uses its own approval UI and doesn't read `config.toml` hooks). After enabling, run `/hooks` inside Codex and **trust** the gesture-approve hook. README updated (EN/ZH). Claude Code works on every surface because its hooks are part of the core runtime.

## v0.3.0

- **Hardened auto-allow.** Trusted *exact* commands are stored separately from regex patterns; a chain-guard blocks `&&` / `;` / `|` / backtick / `$()` bypass on prefix matches; a danger deny-list (`rm -rf`, `curl … | sh`, …) is a hard veto that never auto-allows.
- **Per-command "Always allow"** from the approval card, plus **Restore defaults** (with confirmation) for the regex list.
- **Redesigned Settings**: two-column layout, language picker (EN/中/日/한/ES/FR), launch at login, camera preview rotation + mirror.
- The test card no longer writes to the allowlist.
- **Relicensed to AGPLv3** + trademark / rename policy (`TRADEMARK.md`).
