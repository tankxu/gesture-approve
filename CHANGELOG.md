# Changelog

All notable changes to GestureApprove. Versions follow the GitHub releases.

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
