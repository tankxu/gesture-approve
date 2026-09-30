# Changelog

All notable changes to GestureApprove. Versions follow the GitHub releases.

## v0.10.0 — Quota collection that installs itself

### Claude's quota was never actually being collected

The menu had shown "no quota yet — set up collection in Remote Hub" for weeks. That line was accurate and useless: it named a web page, not a cause. The cause was that Claude's quota has exactly one source — the `rate_limits` payload that arrives with the `statusLine` hook — and the collector that registers that hook had never been installed on this machine. The local database held 21 Claude sessions and zero Claude quota rows, and every one of those sessions had been discovered by scanning transcripts, not by a hook firing. Codex, meanwhile, looked fine because it needs no hook at all: its quota is read straight out of the rollout files on disk.

- **The switch installs the thing it promises.** "Collect quota from installed AI tools" now writes the collector into the config of every AI tool found on this Mac, and removes it again when you switch it off — the same shape the agent-completion toggle has always had. Previously the only ways in were a CLI flag and a button on a Hub page, while the Settings switch controlled nothing but whether the section was drawn. It is off by default: writing into someone's `~/.claude/settings.json` has to be something they chose, and the first time you turn it on a sheet says exactly which files are touched.
- **A switch that is on now means it is working.** On launch and whenever Settings opens, a collector that is on but not actually in place is reinstalled — the app moved, another tool overwrote the status line, someone hand-edited the config. Nothing is ever written while the switch is off.
- **One tool per transaction.** Claude and Codex used to be installed in a single operation that rolled back both on any failure, so a Codex version that rejected the new hook definitions would silently take Claude's collection down with it. Each tool now backs up, verifies and rolls back on its own, and reports its own result. Codex's post-write check also stopped blaming us for pre-existing breakage: it only rolls back when `codex` worked *before* the edit and stopped working after.
- **A tool you do not have is left entirely alone.** Installing used to create `~/.codex/config.toml` whether or not Codex existed, which is a confusing thing to find on a machine that has never run it. Absent tools are now skipped with a reason in the result instead.
- **A collector pointing at an old app path no longer counts as installed.** Identification was "the command mentions GestureApprove", so after the app moved from a build directory to `/Applications` the stale entry still read as present while failing on every invocation. Install state is now three-valued — absent, installed, stale — where stale also covers the half-installed case of hooks present but the status line taken over by something else, which collects sessions and never a single quota number. Stale reinstalls in place rather than stacking a second entry.
- **Backups stopped multiplying.** Each config keeps one `.ga-monitor-backup` beside it holding the state before the last write, and a reinstall that would change nothing does not touch the file at all — necessary once self-healing can run on every launch.
- **The empty state says which kind of empty.** Not collecting, collecting but stale, or collecting and simply waiting for the client to refresh its status line — three different situations that used to print one sentence. The first two are clickable and fix themselves.
- **Adding the next tool is one file.** Collectors sit behind a small protocol: detection, state, install, uninstall. Supporting another CLI means implementing it and adding one line to a list; install, uninstall, state, self-healing, skipping and backups all come along.

### Everything the collector says, in your language

- **The status line follows the app's language.** The footer the collector prints when it wraps a status line — `5h 72% left · 7d 92% left`, or "quota: awaiting first report" before the first response — was hard-coded Chinese, in a place an English user stares at all day.
- **Install and error messages are localized** across all six app languages: unparseable settings, a non-UTF-8 Codex config, an incomplete collector block, a rejected config, absent tools, and the "only new sessions pick this up" note.
- **The Hub's quota and sessions page is bilingual.** It was 100% hard-coded Chinese; every string now goes through the same zh/en table the rest of the Hub uses, picked by the language injected from the app's own setting.
- **API prose is zh/en, matching the pages.** The `reason` and `note` strings the Hub API returns follow the app's language but collapse to zh/en, because that is all the pages have — a Japanese sentence inside an English page reads worse than an English one. `reasonCode` stays a stable English constant. Errors from the installer now travel as keys and are rendered at the boundary, so the same failure can be Japanese in Settings and English over HTTP.

### Removed

- **`/demo` and `hub/demo.html`.** The first Hub page, superseded twice over — once by the dashboard, then by the app. It was still being served, still bundled, and still linked from the quota page, and it was the only page nobody was going to translate.

### Remote Hub is an app again

The previous rewrite turned the Hub into a dashboard — quota cards, a token counter, a session table, and a large empty panel. It read well and did little: the voice replies, the event feed and the "who is waiting for you" framing that made the Hub worth opening from a phone had all been dropped, even though the endpoints behind them were still there. This puts the app back, on top of the newer API instead of beside it.

- **Three places, not one page.** **Inbox** answers the only question a phone needs answered — who is waiting on you, and what is running right now. **Sessions** is all 686 of them, searchable and filterable. **Usage** is the quota windows and the token spend. On a phone that is a bottom tab bar with a badge; on a desktop it is a three-column workbench; between 860 and 1100px the list and the transcript take the width and the rest slides in as a drawer.
- **It installs to the Home Screen.** A web manifest, a service worker and a full icon set (including a maskable one for Android and an opaque one for iOS, which paints transparent pixels black). On iOS, Share → Add to Home Screen gives it its own icon and a full-screen window with no address bar. The manifest, the worker and the icons are served without a token — a browser fetching them does not send our Authorization header, and a 403 there means the install silently fails.
- **Replies take whichever route exists.** Into the live process through `/v2/actions` when the session is still running, or through `/reply` and `claude --resume` when it has exited. When neither is possible the reason is printed above the input box instead of surfacing as a failure after you press send.
- **Voice replies are back**, reusing the old page's recorder (WebAudio → 16 kHz mono WAV → `/asr`) rather than `MediaRecorder`, whose Safari output the speech service does not reliably accept.
- **Transcripts render as Markdown** — bold, inline code, code blocks, lists and links — escaped first, then marked up.
- **`#s=<session>` and `#tab=<name>` are deep links**, and the system Back gesture closes the transcript instead of quitting the app.
- **Codex sessions can be replied to.** Codex has no peer socket, but its CLI has `codex queue --thread <id> --message <text>`, which puts the message in that thread's queue for its next turn — and unlike Claude's inbox, it does not require the session to be running. So Codex replies skip the run-generation check (`expectedRunId`): queuing is not bound to one run, and enforcing it would have meant a permanent `STALE_RUN`. An archived thread is refused by Codex itself, so `capabilities.reply` now says that up front (`SESSION_ARCHIVED`) instead of letting the send fail. `transport` distinguishes the two routes, `claude-inbox` and `codex-queue`, and the composer says which one a reply will take. Because the Codex route spawns a process, these requests no longer run inside the monitor queue, where they would have blocked every other Hub request for seconds.
- **Sending has a 4-second undo.** The message parks on the Hub side first — a dimmed bubble with an Undo button and a progress line that delivers when it runs out. Undo puts the text back in the box; nothing was sent. Past that window it is gone: Claude's inbox takes effect the moment it is written to the socket, and the Codex queue row is already on disk, so the UI does not offer a fake recall after delivery. If delivery fails, the text returns to the box rather than vanishing.
- **The right column does not repeat the session list.** On a wide screen the list already answers "who is waiting on you" — waiting sessions sort first and carry an orange pill — so the sidebar is quota only, and Allow/Deny moved onto the session row itself. The phone's Inbox tab is untouched; being that answer is the whole reason it exists.
- **Transcripts render as real Markdown, and images show up.** Headings, lists, quotes, tables, rules, bold/italic/strike, inline code and fenced blocks, links — rendered in the page only: `/v2/messages` still returns raw text, so anything else reading the API gets the original. Images were being dropped entirely; they live in the transcript as base64 (600 KB for one screenshot), so the message list now carries just a reference and the bytes come from a new `/v2/attachment`, cached by the browser. That endpoint serves png/jpeg/gif/webp and nothing else — a transcript must not become a way to fetch arbitrary files — and it accepts `?token=` because an `<img>` tag cannot send an Authorization header. A message that was only an image used to vanish from the thread; it now appears.
- **Transcripts show what a person actually typed.** A reply sent from the Hub goes into the session's peer inbox, and Claude Code wraps it before writing it to disk: a header line, the message, then a fixed paragraph about peer permission boundaries, flagged `isMeta`. That paragraph is written for the model in the session, not by a human, and reading it back on a phone buried the one sentence that was actually sent. `/v2/messages` now unwraps it — and drops the other non-conversation rows that were crowding the thread (terminal echo, `Continue from where you left off.`), while a slash command reads as `/model claude-opus-5` instead of three lines of XML. If the wrapper's wording changes in a future Claude Code, the body survives and at worst a paragraph reappears; nothing is ever cut. Delivery is unchanged: the Hub still identifies itself as a peer rather than forging the user's own authority, so what the receiving session sees is exactly what it saw before.

**What the LAN cannot give you.** Plain `http://` on your Wi-Fi is not a secure context, so: Android's install prompt never fires (you get a plain shortcut), the service worker does not register (the offline shell only applies when you open the Hub on the Mac itself), and `navigator.mediaDevices` does not exist, so voice is unavailable from a phone — the mic button says exactly that instead of doing nothing. iOS's Add to Home Screen is unaffected and remains the path that works. Getting voice and offline on a phone needs an HTTPS origin for the Hub; that is not part of this change.

### The usage section in the menu says one true thing per line

- **Retired quota pools stopped masquerading as live ones.** Codex listed five rows: a 7-day pool, a `codex_bengalfox` pair and a `subscription` pair, two of which were last seen five days and *ten months* ago. A client reports every pool it currently has, so a pool that is missing from the newest report is history — a former plan, a model allowance that was withdrawn — not a second pool you are spending from. `/v2/quotas` now marks the live set with `current`; the old rows stay in the database, where they belong, and out of the menu, where they were unreadable. The menu and the Hub page both read that one flag.
- **Windows that already rolled over are no longer drawn.** An expired window has no meaningful number — not zero, not full — so it was printing "waiting for next request · resetting…", two rows of nothing, under a pool nobody uses. Those rows are gone; what is left is sorted shortest window first, so 5h always sits above 7d.
- **`codex_bengalfox` is not a name for a person to read.** When several pools *are* live, each gets a one-line subheading using the server's `limit_name` ("GPT-5.3-Codex-Spark"), with the unnamed main pool titled "Subscription". Previously the internal `limit_id` was pasted in front of every window label, which also pushed the progress bars to a different starting column on each row.
- **"剩余 72% · resets in 41m" is fixed.** The remaining-percent text was hard-coded Chinese sitting next to localized English, so an English menu came out half-translated. It goes through the string table now, in all six languages.
- **The footnote says how old the number is.** It used to read "本地观测 · 未强制刷新账户" under every tool at every moment, which is true and useless. It now reads "observed 3h12m ago" (or "just observed"), which is the one thing you need in order to decide whether to trust the bar above it.
- **A tool with nothing to report is omitted** instead of printing a heading with an empty body.

### Settings, decluttered

- **The explanations moved into "?" buttons.** Every section used to carry two or three lines of grey text under it, so opening Settings meant facing a wall of prose before you could find a single switch. Each note now lives behind a small `?` next to the thing it explains — click it and the full text pops up (hover gives you the short version as a tooltip). Nothing was deleted; the page just stopped shouting all of it at once.
- **The ESP32-CAM entry is a one-line strip.** It was a big card with an icon tile and a two-line description, competing for attention with the camera and engine settings — for optional hardware most people never attach. Same click target, a fraction of the height.
- **Every section got an icon**, so a long column of switches has some rhythm and you can find the section you want at a glance instead of reading every heading.
- **The window now opens at the height of its content.** With the prose gone, the old fixed 900 pt left a third of the window empty; it now measures both columns and sizes to the taller one (capped at the screen, and whatever height you drag it to is still remembered).

### The Hub page follows the new API

- **Local list is now the primary source, the cloud list is a bonus.** The dashboard used to build its list purely from `/cloud/sessions`, which needs a signed-in claude.ai tab in Chrome — no tab meant an empty page, and it never showed the sessions whose terminals had been closed. It now loads `/sessions` (from disk, works offline, 77 sessions here) and *merges* the cloud list on top when it's available: cloud-only rows (sessions started in the desktop app) get appended, and rows that exist in both are enriched with the status only the cloud knows (review-ready, unread, one-line summary). If Chrome isn't cooperating the page says so in the status bar and carries on.
- **Sessions are grouped by whether you can actually reply**, and the composer says which route it will take — web injection into the tab you have open, or `claude --resume` for a session that has already exited. The one read-only case (no bridge, process still running) is spelled out instead of silently failing on send.
- **Replies through the resume route show the answer inline**, since the API hands it back; long turns say so and let the transcript catch up.

### Every session is listed, not just the running ones

- **`/sessions` used to show 6; it now shows 74.** The list was built from Claude's runtime registry (`~/.claude/sessions/*.json`), which only records *live processes* — so the moment you closed a terminal, that session vanished from your phone. The list is now built from the transcripts on disk (`~/.claude/projects/**/*.jsonl`), with the registry demoted to what it's actually good for: is this one still alive, and does it have a web bridge.
- **It stays fast by only reading the ends of each file.** Head 64 KB for the working directory, tail 256 KB for state and title, cached by file mtime — 74 sessions come back in about a second instead of parsing megabytes per session on every refresh. Titles reuse the same rules as the notifications (aiTitle → first *real* user message → derived name), and `titleSource` says which one you got.
- **The working directory comes from the transcript, never from the folder name.** Claude encodes a cwd into a directory name by turning `/` into `-`, which is lossy — on this machine 18 of 21 project folders can't be decoded back (any path containing a hyphen). The `cwd` field inside the file is authoritative.
- **New `canReply` field** so a client knows, per session, whether `POST /reply` will work: web bridge → yes, no bridge but the process exited → yes (resume path), no bridge and still running → the one case that's read-only.

### Replying to sessions that have no web link

- **`POST /reply` now works for sessions the browser route can't reach.** It used to require a `bridgeSessionId` — a claude.ai share link — and sessions without one (most of them) were read-only from your phone. Those now go through `claude --resume <id> -p <text>` instead: same session id, same transcript, context intact (verified — ask it what you said one message ago and it answers correctly). The web route is still preferred when a bridge exists, because that lands in the session the user has open on screen.
- **It hands you the answer.** The resume route returns the agent's reply in the response body, so a phone doesn't have to poll the transcript to find out what happened. Long turns (the agent may actually go do work) return `pending: true` after 60s and finish through `/events` as usual.
- **It refuses to fight the terminal.** If the target session is still running, the request is rejected with `409` rather than starting a second process that writes the same transcript — the two histories would collide and the person at the keyboard would never see the message. Sessions whose id doesn't exist get a `404` instead of a generic failure.
- **Same billing as typing it yourself**: the CLI authenticates with your subscription (oauth), and the resume path explicitly strips `ANTHROPIC_API_KEY`-style variables so it can't silently fall through to metered API usage. Alerts triggered by a Hub-sent turn are logged and pushed to `/events` but don't raise a desktop banner — you're not at the Mac.

### Agent finished alerts

- **Know the moment the agent stops working — Claude Code *and* Codex.** Turn it on in *Settings → Agent finished alerts* and GestureApprove installs a `Stop` hook (Claude Code → `~/.claude/settings.json`, Codex → `~/.codex/config.toml`): every time the agent wraps up a turn you get a desktop banner with the project name and the last thing it said (Codex banners are tagged so you can tell the two apart). The hook only watches — it never blocks, delays, or changes what the agent does, and it stays quiet on the follow-up run when another Stop hook made the agent continue.
- **Codex goes through hooks, not `notify`.** `notify` is a single top-level key — one program per user, and on many machines it's already taken (Codex Computer Use claims it). Hooks are a list, so several tools coexist; GestureApprove writes its own marked block and leaves your `notify` and every other setting untouched. Codex asks you to trust a new hook once: the next time you open it, press `t` in the hooks review or the hook stays inert.
- **A sound you can recognize without looking.** Alerts play their own marimba cue instead of the system default — rendered offline from a few MIDI notes through macOS's built-in GM sound bank, so it ships as a 300 KB AIFF with no dependencies and can be re-scored from `Assets/sounds/render_agent_done.swift`. It is played by the app with the notification itself muted: `UNNotificationSound(named:)` silently substitutes the system default no matter where the file sits (app bundle *or* `~/Library/Sounds`), with no error to tell you — so "custom sound" would have been a lie. Playing it ourselves also means honouring Do Not Disturb by hand, which needs the one-time Focus-status permission macOS asks for; without it the app can't tell a Focus is on, so it keeps asking every launch (or offers to just turn the alerts off).
- **Three lines, ordered by what you actually look for.** Session title on the biggest line, then where it is (`~/LocalDev/project`) or what it wants ("Waiting for your input"), then the details. Several banners stacked up used to look identical because the title line read "Agent finished · project" for all of them.
- **The same alerts reach your phone.** Each completion is also pushed to the Remote Hub as an event stream: `GET /events?since=<version>&wait=25` is a cursor-based long poll (same shape as the approval `/state`), so a phone or an ESP32 that was offline for a while just asks with its old cursor and gets everything it missed (last 50 kept). The Hub dashboard shows the latest completions above the session list — tap one to jump into that session. Documented in `hub/HUB_API.md`.
- **Four independent switches.** Claude Code and Codex each have their own switch (that's what installs or removes that CLI's hook); desktop banners and the Hub push can each be turned off on their own. Everything is off until you ask for it — nothing is written to any CLI config before that. Gemini and Kimi have no equivalent "turn finished" event.
- **"Waiting for you" too, not just "done".** Claude Code's `Notification` hook is installed alongside `Stop`, so you also hear about it when the agent has been sitting idle waiting for your reply — the case where you'd otherwise wander off and lose ten minutes. Permission prompts are deliberately dropped: GestureApprove *is* the approval surface, so a gesture card plus a system notification for the same thing is just noise.
- **Titles you can tell apart.** The notification's biggest line is the session title, and it now falls back sensibly instead of showing the project name for everything: Claude uses its own `aiTitle`, then the first *real* user message (skipping `isMeta` entries, `<environment_context>`-style envelopes, `Caveat:` preambles, and rendering slash commands as `/command args`); Codex reads `name`/`title` straight out of its own `~/.codex/state_5.sqlite` — where it already keeps a per-thread title — instead of parsing rollout files.
- **Markdown gets flattened for display.** An agent's closing words are usually full of `**bold**`, backticks, tables and list markers; in a notification banner that's a screenful of punctuation. Banners now show cleaned plain text — cleaned *before* truncating, so a cut can't leave a dangling `**` behind — while the event stream keeps the original and offers `?plain=1` for clients that want it flattened too.
- **Grouped by project.** A few sessions running for a day pile up a hundred banners in Notification Center; completions from the same project now stack into one thread instead of carpeting the list.
- **Nothing is lost silently any more.** The Stop hook can't write to stdout (Claude would read it as an instruction), so a failed delivery used to vanish without a trace — if the app was restarting or its port hadn't come back up, the alert simply never happened and nothing said so. Both sides now log it: the hook records "couldn't reach the app, dropping this one", and the app logs any notification the system refuses.
- `GestureApprove --agent-notify [on|off|status] [claude|codex]` does the same from a terminal and prints whether each hook is actually in place. `--agent-notify test` goes further: it sends a real notification, then checks back whether it landed — separating "never delivered" from "delivered but you never saw it" (Focus mode, scheduled summary, or an alert style of *None*), which is otherwise unfalsifiable from the outside.

### Usage in the menu bar

- **Your AI CLI quotas live in the menu bar.** Open the menu-bar menu and each tool you actually use gets a block at the top: a bar, a percentage, and how long until the window resets. It doesn't wait for the tool to be running — quota is something you want to check *before* starting. A tool you've never used on this Mac stays out of the list.
- **Real numbers, not estimates.** Claude Code's **5-hour** and **7-day** windows come from the same source as `/usage`; Codex's come from its own usage endpoint. No token counting, no guessed plan limits. Codex's local session files are only a fallback now — they carry whatever snapshot the server last sent, which silently goes stale when a window resets (it read *50% used* on a window that had actually rolled over to *0%*).
- **You pick where Claude's numbers come from, and the browser is the good answer.** Claude Web reads them through a signed-in claude.ai tab: no permission prompts, and the login lasts months. The Keychain route works too, but macOS re-asks every time Claude Code rotates its token — so GestureApprove never falls back to it silently. It asks once, remembers, and asks again only if the browser route breaks (with the specific reason: no tab, or Chrome's *Allow JavaScript from Apple Events* is off). Not in the mood to decide? *Skip usage for now* stops the asking for 24 hours without taking the section away — the entry stays in the menu, one click away. Settings → General can switch sources or resume early. Picking a source gets you a notification with the numbers once they land; every other fetch stays silent.
- **Right account, not just any account.** The browser route asks for the organization Claude Code itself is signed in to (read from `~/.claude.json`, no Keychain involved) rather than whatever the browser happened to use last — so a second account signed in to claude.ai can't quietly show you someone else's quota. If the browser can't see that organization, it says so instead of substituting another one.
- **Costs nothing when you're not looking.** Data is only collected while the menu is open, the quota call is cached for 3 minutes with back-off on throttling, and nothing is collected at all unless a tool is actually running. Turn the whole section off in Settings → General.
- New diagnostics: `GestureApprove --usage` prints the same data to a terminal, `--usage-ask` previews the source dialog.

### Fixed

- **A runaway self-heal loop could pin a CPU core and fill the disk.** If the approval server's port was still held after a wake (or any bind failure), each failed listener scheduled its own restart, so the retry chains doubled every second and then fought each other for the port — a storm that never converged. Restarts are now single-flight with a real exponential back-off (1s→60s), and stale listeners' failures are ignored by generation. The log file also rotates at 10 MB; one machine had grown a 13 GB `/tmp/gestureapprove.log`.

## v0.9.0 — Session Hub & the smart hook

### Session Hub — control your Claude Code sessions from any device

- **New "Remote Hub" in the menu bar.** A single entry opens a local dashboard where you can watch every running Claude Code session — live status (running / using a tool / waiting for you / done), titles pulled from the client, and which sessions are repliable. From your phone, tablet, or an ESP32 on the same Wi-Fi you can see chat history, reply, and take over. Everything runs on your Mac and talks straight to your devices — no third party in the loop.
- **Reply by voice.** Tap the mic, speak, and it's transcribed (SiliconFlow SenseVoiceSmall) and dropped into the reply box; send it and it lands in the session on your claude.ai subscription (not metered API). The speech key lives only on your Mac in `~/.claude-session-hub/config.json` and is never sent to devices.
- **Built entirely into the app — zero dependencies.** The Hub is native Swift running inside Gesture Approve (no Python, no runtime to install, ~0 added size). Pages, session listing, transcript parsing, speech, and reply are all served by the app itself.
- **LAN on/off, first-run intro, and a config page.** A loopback-only config page shows pairing info (Base URL + token, phone link, ESP32 header), the device-approval endpoint, and the speech key. A **LAN toggle** switches between "phones/devices can connect" (bind `0.0.0.0`) and "this Mac only" (loopback). The dashboard greets first-time users with an intro and nudges you to set up speech before you tap the mic.
- **Follows your language.** Both pages are localized (Chinese / English) and automatically match Gesture Approve's language setting.
- **HTTP API for devices.** Token-protected LAN endpoints (`/sessions`, `/session/<id>/messages`, `/asr`, `/reply`, …) documented in `hub/HUB_API.md` — build an ESP32 or any client against them. No HTTPS required.

### Smart hook — Gesture Approve now respects Claude's own auto mode

- **The hook only steps in when Claude Code would actually prompt you.** The old hook intercepted *every* matched tool call, so in `acceptEdits` mode every edit still popped a card — Gesture Approve was overriding Claude's smarter auto-mode with dumber rules. The hook now reads Claude's `permission_mode` and defers (stays silent) when Claude wouldn't ask anyway: `bypassPermissions`, `dontAsk`, `plan`, and `auto` are handed fully back to Claude; in `acceptEdits`, file edits are deferred while `Bash` still routes to you; only in `default` mode does Gesture Approve take over. **Device/gesture approval is now a `default`-mode capability** — switch to `acceptEdits`/`auto` (⇧⇥) whenever you'd rather trust Claude's judgment, and the app gets out of the way.
- **Scoped to Claude.** `permission_mode` is Claude Code's concept, so this gating applies only to the Claude hook. Codex uses a `PermissionRequest` hook that already fires solely when it means to ask — it was never over-eager; Gemini and Kimi carry no such field and keep their previous behavior.

## v0.8.1

### Fixes

- **The hook no longer forces manual approval when Gesture Approve is idle, offline, or times out.** When the app returned `ask` — because it was closed, unreachable, or the approval card timed out — the Claude Code hook emitted `permissionDecision: "ask"`, which *overrides* auto-mode: it forced a manual confirmation for every matched `Edit`/`Write`/`Bash`, defeating your `acceptEdits` mode, your `permissions.allow` allowlist, and even `--dangerously-skip-permissions`. It now stays silent on `ask` (emits nothing, i.e. `defer`), handing the decision back to Claude Code's own permission logic — matching how the Codex and Gemini paths already behaved. `allow`/`deny` from an actual gesture are still honored. (Kimi shares this path.)

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
