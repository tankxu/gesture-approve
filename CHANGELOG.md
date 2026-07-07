# Changelog

All notable changes to GestureApprove. Versions follow the GitHub releases.

## v0.8.0

### Big mode

- **New "Big mode" menu-bar toggle.** When on, the approval card fills the entire screen so you can read it from across the room. Toggle it from the 👍 menu-bar menu; it applies to the next approval. Off by default (normal notch-sized card).
- **Full-screen layout puts the command front and center.** A dedicated partitioned layout: the title is pinned near the top (clearing the notch camera), the hint sits at the bottom, and the command — the largest element — is centered with the gesture buttons. Chrome text stays small so the reviewed content dominates. A very long command or path automatically shrinks to fit within half the screen instead of overflowing.
- **No layout jitter on recognition.** Recognizing a gesture no longer shifts the command around: the three regions are laid out independently, and the always-allow button / countdown ring reserve their space instead of appearing and disappearing.

### Security & robustness hardening (full-codebase audit)

- **Closed several "dangerous command auto-allowed" bypasses.** `find … -exec/-execdir <anything>` (arbitrary code execution) was allowed by the `find` prefix; `open <app/dmg/url>` was auto-allowed despite its side effects; credential reads via relative path (`cat .env`, `cat id_rsa`, `Read: .env`) slipped past the sensitive-path deny rule because every branch required a leading `/`; and the new `>/dev/null` redirect exemption had no boundary, so `>/dev/nullhijack` / `>/dev/null/../real.txt` wrote real files while passing as read-only. All now pop a card.
- **Full command is now evaluated, not the first 600 chars.** Both hook paths truncated the operation to 600 characters before the app saw it — a `<600-char safe prefix> && rm -rf ~` hid its tail from the deny-list while the prefix matched the allowlist. Raised to a pathological-input-only cap; the card still truncates for display.
- **Empty allowlist patterns no longer match everything.** An empty regex matches any string; a stray blank line in the Settings allowlist made the compound-command layer auto-allow arbitrary command segments. Blank patterns are now skipped.
- **The MediaPipe engine survives a daemon crash.** If the Python gesture daemon died (OOM, a Homebrew Python upgrade breaking the venv, an oversized frame), writing the next frame to the dead pipe raised SIGPIPE and **killed the whole app**; if it died mid-inference, recognition silently froze forever. The app now ignores SIGPIPE, drains the daemon's stderr (a full stderr pipe used to deadlock it), and auto-restarts the daemon on unexpected exit.
- **A failed self-update can no longer delete the app.** The updater did `rm -rf <app>` before copying the new build in, with no `set -e` and no rollback — a mid-way failure (disk full, no write permission, read-only App Translocation volume) left an empty app directory. It now stages the new build under a sibling name and swaps it in atomically, rolling back the old version on any failure.
- **Hook install won't wipe your CLI config.** Installing the Claude/Gemini hook now aborts instead of overwriting when the existing `settings.json` fails to parse (previously it silently replaced the whole file with just the hooks, dropping permissions/env/model). The Codex/Kimi marked-block remover no longer crashes on a reversed/partial marker pair and clears duplicate blocks; hook-ownership detection is tighter so it won't delete a user hook that merely contains `--hook`.
- Approval is now idempotent within the result-display window: a hotkey/click/"always allow" fired during the 0.7s dwell can no longer flip the outcome (UI showing one verdict while the hook received the opposite) or write a just-denied command to the allowlist.
- The frame watchdog no longer accumulates parallel timer chains across back-to-back approvals (which could double-trigger session rebuilds and cause black-screen flicker).

### Read-only command chains

- **Read-only command chains no longer pop a card.** Real-world safe commands almost always carry pipes or `&&` (`ls | head`, `cd x && grep y`) — any compound token used to disqualify the prefix allowlist and either bother the local LLM (~1s, occasionally wrong) or pop a card (14% of all cards, measured). The allowlist now splits compound Bash commands quote-aware and auto-allows when **every segment** matches the read-only allowlist with no file-writing redirects (`>/dev/null` and `2>&1` are fine). Command substitution (`` ` ``/`$(`) never qualifies; the danger deny-list still checks the whole line first, so `ls && rm -rf` still pops a card.
- **Reading credentials via Bash is now caught too.** The sensitive-path deny rule (`.ssh` keys, `.aws/credentials`, `.pem`, `.env`, …) only matched the `Read` tool, so `Bash: cat ~/.ssh/id_rsa` sailed through the `cat` allowlist. The rule now covers both, and suffix anchors work mid-command.
- `cd` and other no-side-effect commands (`sort`, `diff`, `jq`, `realpath`, …) joined the read-only allowlist; Claude Code's local preview tools (`mcp__Claude_Preview__preview_*`) are auto-allowed.
- **Unplugging your selected camera no longer blackholes approvals.** If the saved camera (e.g. a USB capture card) is permanently removed, the approval card used to stay black forever — the strict "never fall back" rule couldn't tell "still re-enumerating after wake" from "gone for good". Now: within a 4s grace period the app still waits strictly for your device (wake behavior unchanged); past it, the card temporarily falls back to the default camera so approvals keep working. Your saved choice is never overwritten — plug the device back in and it switches back automatically.
- **Settings no longer lies about the selected camera.** When the saved camera is disconnected, Settings used to silently display the built-in camera (with a live preview!) while approvals still targeted the dead device. It now shows a "⚠️ Selected camera disconnected" placeholder plus an explanation of the temporary fallback.
- **The card now pops with a live picture.** Cameras need ~1.4s from start to first frame (kept off between approvals so the camera light never idles on). The card used to appear instantly and sit black for that warm-up; it now waits for the first frame (2s cap) and appears with the picture already live. The ⌃⇧Y / ⌃⇧N hotkeys activate once the card is visible.
- **Much taller field of view on the built-in camera.** The FaceTime HD default 16:9 is a crop of a near-square sensor. The app now picks the squarest capture format (1552×1552 on FaceTime HD — +44% vertical FOV), so a hand resting near the keyboard makes it into frame. Settings preview uses the same framing; 16:9-only devices (OBS/Camo/capture cards) are unaffected. Note for macOS: `activeFormat` must be set *after* `startRunning()`, or the session preset snaps it back to 16:9.
- Camera "waiting for device" log lines are now recorded once per absence instead of every 0.8s.

## v0.7.10

- **Fixed the intermittent "blank notch" bug.** Once in a while the approval card showed a black card with no camera image (and gestures stopped working) until the app was restarted. USB capture cards (e.g. AVerMedia PW310) can silently stop delivering frames while the capture session still reports itself as running — no error is raised, so nothing recovered it. The camera source now runs a frame watchdog during approval: if no new frame arrives it rebuilds the capture session automatically, and runtime errors / interruption-ended events trigger recovery too.
- **After sleep/wake it uses the camera you actually selected.** The same silent failure also happens after the Mac sleeps or the screen locks. On top of that, a USB capture card that hadn't finished re-enumerating yet was treated as "gone", so the app silently fell back to the built-in camera and showed the wrong camera (or a black frame). The app now sticks to your selected device and waits for it to re-enumerate instead of falling back; the watchdog retries while the device is still coming up and gives the first frame enough grace time so it no longer rebuilds in a loop. (A USB capture card still takes ~2s from start to first frame after waking — that's the device's own warm-up.)

## v0.7.9

- **Sensitive file reads now require a gesture.** Reading credential/secret paths (`.ssh/`, `.env`, private keys, `*.pem`, cloud-provider credentials, etc.) used to bypass gesture approval and land in the terminal prompt directly, because the hook only matched `Bash|Edit|Write|MultiEdit|NotebookEdit`. `Read` is now covered — sensitive paths pop a card, ordinary file reads still pass silently.
- **MCP tools are covered too.** All `mcp__*` tools now route through the hook. Read-only tools (`get`/`list`/`search`/`read`/`query`/`whoami`…) auto-pass; write/action tools (`create`/`update`/`delete`/`upload`/`authenticate`…) require a gesture. `WebFetch`/`WebSearch` are intentionally left out (no approval needed).

## v0.7.8

- **Update dialog renders the changelog as clean text.** The release notes shown in the update confirmation no longer display raw markdown (`**`, `-`); bold markers are stripped and list items become readable bullets.

## v0.7.7

- **Automatic update checks.** The app now checks for a new release on launch and every 24h in the background. When one is found, a quiet **"🆕 Update to vX.Y.Z"** item appears in the menu-bar menu (no pop-ups, no notifications) — click it to see the changelog and update in one click. Ignore it and it just stays there; not clicking is how you skip a version.
- **"Check for updates" moved next to the version number** in Settings (instead of being pushed to the far right).

## v0.7.6

- **Renamed to "Gesture Approve"** (with a space) — the display name in Finder/Dock/menu bar/windows. The bundle identifier, executable, and data folder are unchanged.
- **In-app self-update.** "Check for updates" can now download, install, and relaunch the new version itself, with a changelog confirmation dialog. Because the app downloads and de-quarantines the build directly, the unsigned new version opens without Gatekeeper's repeated "Open Anyway" prompt — you only approve the first manual install.

## v0.7.5

- **Installer/download windows are now fully localized.** The progress text streamed into the firmware-flash, MediaPipe, and smart-gate setup windows — and the gatekeeper helper's own model-download progress — used to be hardcoded; it now follows the app language across all six locales (en/zh/ja/ko/es/fr).
- **Fixed MediaPipe not recognizing 👍 at the higher strictness levels.** The "recognition strictness" slider was reused verbatim as MediaPipe's gesture-score threshold, but MediaPipe's scores run lower than Vision's geometric scale (a clean Thumb_Up tops out around 0.73), so Standard sat right on the edge and Strict (0.9) rejected everything. The three levels now map to MediaPipe-appropriate thresholds (0.40 / 0.55 / 0.70).

## v0.7.4

- **Bundle identifier is now `com.tankxu.gestureapprove`.** Switched to the GitHub account as the reverse-DNS prefix (also the LaunchAgent label and internal queue names). Note: the app now uses a fresh preferences domain, so settings written by older versions (trusted commands, allowlist, engine choice, smart-gate toggle, …) don't carry over — reconfigure in Settings after installing.

## v0.7.3

- **Approval-log polish.** The "Allowlist" button now only appears on the row you're hovering (the row also highlights), instead of every row carrying a button. Tightened the icon-to-label spacing on the button and the "In allowlist" state.

## v0.7.2

- **Add to allowlist straight from the approval log.** Each log row now has an **Allowlist** button that adds that exact command to trusted commands, so the same command skips the gesture from now on; rows already trusted show "In allowlist" instead. Dangerous (deny-list) commands get no button — they'd be hard-denied to a gesture anyway, so offering it would mislead.

## v0.7.1

- **Smart gate now also judges compound commands.** When the smart gate (local LLM) is on, compound commands (`&&`, `|`, `;`, redirects, …) used to skip the LLM and always fall to a gesture. Now they're sent to the LLM too — it reads the whole command, so it can recognize intent hidden after a pipe/`&&` better than the prefix-allowlist (which only matches the head). The safety floor is unchanged: the danger deny-list matches against the *entire* command, so any compound containing a dangerous fragment (e.g. `ls && rm -rf …`) is flagged dangerous and never reaches the LLM — it always requires a gesture. The prefix-allowlist still refuses compounds outright (no LLM backstop there). Net effect: with the LLM on, harmless compounds like `cd build && cmake ..` can be auto-allowed instead of always prompting.

## v0.7.0 — Approval log

- **Approval log.** Every approval the app takes over is now recorded — command, time, session (Claude `session_id` + project dir + tool), the decision (allow / deny / back-to-terminal), and which gate decided it: allowlist, smart gate, gesture, or "always allow" (writing a trusted command), plus a blacklist flag when a dangerous-rule match forced the gesture. New menu item **Approval log…** (⌃-menu) opens a window listing entries newest-first, with colored tags, live refresh, **Show in Finder**, and **Clear**. Entries persist as JSONL in `~/Library/Application Support/GestureApprove/approve-log.jsonl` (capped at the most recent 3000 lines). The hook now forwards `session_id` so each entry is attributable to a session.

## v0.6.0 — Smart gate (optional local LLM)

- **Smart gate: auto-allow obviously-safe commands with a local LLM.** New opt-in setting (Settings → Smart gate). When on, a small on-device model (Qwen3-1.7B, via MLX) judges each command; only obviously-safe ones skip the gesture, everything else still gets the card. Runs fully on your Mac (nothing leaves the machine), adds ~1s. **Dangerous commands never reach the LLM** — they always require a gesture (deny-list fallback); anything uncertain or offline falls back to the gesture too.
- **The model is an optional, on-demand download — the .app stays small.** The LLM runs in a separate helper (`GestureGatekeeper`, links MLX) that is *not* bundled. Enabling Smart gate downloads a prebuilt, ad-hoc-signed helper (~50MB) from GitHub Releases plus the model weights (~1GB) into `~/Library/Application Support/GestureApprove/gatekeeper/` (self-contained; delete that folder to fully uninstall). No Apple Developer account needed — the helper is launched via `Process` (not `open`), so ad-hoc signing + quarantine-clear is enough.
- **Approval rules are now a single editable file.** Deny-list / auto-allow / compound tokens live in `config/gatekeeper-rules.json` (loaded at runtime, with a built-in fallback so the deny-list is never empty). The deny-list was expanded to ~70 destructive/irreversible/privileged patterns (rm, git reset --hard, kill, ssh-keygen, docker prune, package installs, sudo, …) to backstop the LLM's blind spots.
- **Settings & card polish.** Connect-AI toggles are a single horizontal row (no more "Connect " prefix); the Codex-only note moved to a hover "?" popover. The notch card is a touch wider (360pt) and the command preview is capped at 3 lines.

## v0.5.1

- **Core approval hook is now Python-free.** The hook used to be `gesture_hook.py` (run via `/usr/bin/python3`), which meant a machine without Python couldn't gate tools at all. The hook is now the app binary itself — `GestureApprove --hook <claude|codex|gemini|kimi>` (new `HookCLI`). Re-toggle a CLI in Settings to switch to it (old python commands are still recognized for clean uninstall). MediaPipe still needs Python, but that's an opt-in extra.
- **Fix: MediaPipe still showed "Not installed" after a successful install.** The install runs in a separate window; the Settings pane now refreshes its state when the install finishes (via a notification) instead of staying on the stale value.

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
