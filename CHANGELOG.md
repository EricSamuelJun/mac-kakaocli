# Changelog

### v0.11.0 - AppLifecycle multi-source cascade
- `AppLifecycle.detectState` and `isRunning` no longer depend on `NSRunningApplication` alone. New `AppLifecycle.findProcess()` cascades through `NSRunningApplication` (in-process Cocoa) → `pgrep -x KakaoTalk` (kernel process table, session-independent). Any positive signal wins; only an all-negative result concludes "not running".
- New public types `AppLifecycle.RunningProcess` (`{pid, source}`) and `DetectionSource` (`.nsRunningApp` / `.pgrep`) so callers can distinguish the cross-session case from the normal one.
- Closes the v0.9.0-era failure mode where a LaunchAgent without `LimitLoadToSessionType=Aqua` would land in a session where `NSRunningApplication` returned empty for KakaoTalk, the lifecycle code mis-classified the state as `notRunning`, and `/reply` mis-launched the app on every request. `pgrep` sees the process regardless of session, so the cascade keeps the diagnosis truthful even when an operator's LaunchAgent or shell environment lacks Aqua.
- `kakaocli doctor`'s "KakaoTalk running" check now reports the source: `[ok] pid 1234 (NSRunningApplication)` in the normal case, `[warn] pid 1234 via pgrep (NSRunningApp empty — session isolation suspected)` when the cascade rescues us. The warn case ships an actionable hint pointing at the Aqua pin.
- Tests cover the cascade decision policy as a pure function (`cascadeWithSources(nsRunningPid:pgrepPid:)`): NSRunningApp wins when present, pgrep is the fallback, nil when both negative, priority is stable even on synthetic disagreements.
- No public API change to `isRunning()` / `detectState()`; existing callers see strictly more accurate results. `NSRunningApplication.activate()` is still used to raise the window when the process was found via NSRunningApp; the pgrep path skips activation since cross-session activation is a no-op anyway.

### v0.10.0 - `kakaocli doctor` self-check
- New `kakaocli doctor` command: runs 13 read-only checks against the operator environment and reports each as `[ok]` / `[warn]` / `[fail]`. Covers identity (userId source, `config.json`, `policy.json`), KakaoTalk app (installed, running, app state), macOS permissions (Accessibility, Full Disk Access), database (found, decryption), and operations (LaunchAgent plist + Aqua pin, bootstrapped, Keychain credentials).
- `--json` flag for machine-readable output (snake_case keys + summary block), suitable for orchestrator health checks. Exit code `0` unless any check fails; warnings stay informational.
- Doctor never mutates state — no AX dialogs triggered, no files written, `detectState` runs non-aggressively. Safe to wire into cron / monitors / Hermes pre-flight.
- Closes plan §2 (the remaining short-term item from `quiet-singing-hartmanis.md`); regression triage on macOS / KakaoTalk updates should now take ~30 seconds instead of bisecting the failure mode by hand.

### v0.9.0 - Aqua session pin, env var removal, agent-facing docs
- **BREAKING**: `kakaocli send --main` no longer falls back to the `KAKAOCLI_MAIN_CHAT_NAME` env var. `policy.primaryChatId` (set via `kakaocli init` or `kakaocli policy manage <id> --make-primary`) is now the only source. The deprecation warning has been on stderr since v0.6.0.
- LaunchAgent plist template pins to the Aqua session via `LimitLoadToSessionType=Aqua`. Without this, `launchctl bootstrap gui/<uid>` could still land the agent in a session where `NSRunningApplication.runningApplications(...)` returned an empty array for KakaoTalk, causing every `/reply` to time out with `"did not become ready within timeout"`. Operators upgrading from a hand-written plist need to add the two lines and re-bootstrap.
- README "Serve" + AGENTS "Running Unattended" call out the Aqua requirement explicitly so migrating operators don't re-derive the failure mode.
- SKILL.md gains a "Resolving Natural-Language Labels" section: operator prompts like "49기방에 …" arrive without chatIds, and the agent's job is to resolve via `kakaocli policy list --json` → `{alias: chat_id}` map before driving any send / messages / sync call. Aliases stay operator-curated (never LLM-derived).
- Audit: `chats / messages / search / query` JSON outputs all surface chatId in the documented field (`id` or `chat_id`). No code change — confirmation only.

### v0.8.0 - `kakaocli policy` subcommand group + aliases
- New `kakaocli policy` subcommand group: `list`, `add`, `manage`.
- `PolicyEntry.alias`: optional human-friendly label (e.g. "49기방") that orchestrators resolve to a chatId. Optional + backward-compatible — pre-existing `policy.json` files continue to decode unchanged.
- Alias uniqueness is enforced at every write path (`policy add`, `policy manage --set-alias`). Reverse mapping (alias → chatId) stays total for Hermes / LLM agents.
- `policy list` / `policy list --json` — read-only inspection. JSON shape: `{policy_path, strict_mode, deny_by_default, primary_chat_id, entries:[{chat_id, alias, expected_name, expected_user_id, purpose, is_primary}]}`. Snake_case keys match the existing CLI / HTTP output.
- `policy add` — interactive picker over chats not yet on the allowlist by default; non-interactive when `--chat-id` is given (with `--alias`, `--purpose`, `--no-pin-user-id` flags). Pin auto-resolves to the friend's `directChatMemberUserId` on 1:1 chats.
- `policy manage <chatId>` — interactive numbered menu by default; flag-driven when any of `--set-alias`, `--set-purpose`, `--set-name`, `--pin-user-id`, `--unpin-user-id`, `--make-primary`, `--remove` is set. `--make-primary` and `--remove` ask for `[y/N]` confirmation unless `--yes` is passed. Removing the current primary auto-clears `policy.primaryChatId`.
- README "Configuration" section now documents the alias field plus the full `kakaocli policy` workflow. AGENTS.md adds an orchestrator example for alias → chatId → send.

### v0.7.0 - HTTP read endpoints (Phase 3 gate)
- `GET /chats?limit=N` returns the chat list in the same snake_case schema as `kakaocli chats --json`. Default limit `50`; non-integer or non-positive `limit` returns HTTP 400.
- `GET /chat/{chatId}` returns a single chat. Adds `direct_member_user_id` for 1:1 chats (omitted via `encodeIfPresent` for groups / channels). `404 {success:false, message:"Chat not found"}` for unknown chatIds; `400` for non-numeric path segments.
- Read endpoints are intentionally **not** policy-gated — they expose the same data the CLI's `chats` / `messages` already surface on the same host. `POST /reply` remains the only write surface and stays verifier-gated.
- `ReplyServer` now takes a shared `DatabaseReader` alongside the `MessageSender` so the read path reuses the same connection.
- README "Known Limitations" calls out the GUI-session requirement explicitly: `send` / `harvest` / `serve` silently fail when the WindowServer is unreachable (sleep mode, locked login window, SSH-only session). Practical knobs (`caffeinate -d`, `pmset -a displaysleep 0`, CRD-kept session) are listed.

### v0.6.0 - Init, Config, Send Policy (Phase 2 잔여)
- `init` command: one-shot first-time setup — triggers Accessibility / Full Disk Access prompts, recovers userId, scaffolds `~/.kakaocli/config.json` + `policy.json`. Flags: `--non-interactive`, `--force`, `--skip-permissions`, `--primary-chat-id`, `--max-seconds`.
- `~/.kakaocli/config.json` for persistent operator identity. Resolution order for `userId`: `KAKAOCLI_USER_ID` env var → config.json → plist heuristics.
- `~/.kakaocli/policy.json` send-policy allowlist with per-entry `{chatId, expectedName, expectedUserId, purpose}` plus top-level `strictMode`, `denyByDefault`, `primaryChatId`.
- `send` chatId-first surface — **breaking change**: `kakaocli send <chatId> <message>` is the default; `--name "name" <message>` for legacy substring matching. `_` placeholder convention removed. `--me` / `--main` now take a single positional message argument.
- `send --main` resolves via `policy.primaryChatId` (verifier on). Falls back to `KAKAOCLI_MAIN_CHAT_NAME` env var with a stderr deprecation warning.
- `send --unsafe-no-verify` for explicit operator bypass on the chatId path.
- `inspect --open-chat-id <id>` for unambiguous chat debugging.
- `messages --chat-id` is documented as the preferred filter over `--chat`.
- HTTP `POST /reply` enforces the send-policy verifier with no per-request bypass.
- Multi-threaded userId brute-force in `UserIdRecovery`: 10s single-thread timeout → configurable 60s default scaling across all cores, plus filtering of the four preloaded official-sender IDs.
- Chat-window header cross-check on `send` and `harvest` — opens the chat, verifies the AX title matches the row label before typing (impersonation / row-reorder defence).
- `auth` simplified to pure verification. Source label (`config` / `env` / `override` / `plist`) reveals where the resolved userId came from. Candidate-IDs probe loop removed.
- Tests migrated from swift-testing to XCTest for portability across non-stable toolchains. 36 cases across KeyDerivation / UserIdRecovery / ChatHeader / Config / Policy / SendPolicy.

### v0.5.0 - Chat Harvest (Phase 4)
- `harvest` command: bulk-capture chat display names and load message history
- Vision framework OCR to locate "View Previous Chats" button
- CGEvent-based clicking for reliable UI interaction
- CGWindow API for paywall popup detection
- Auto-dismiss Talk Drive Plus paywall dialogs
- MetadataStore: persistent chatId → displayName at `~/.kakaocli/metadata.json`
- `query` command: raw read-only SQL queries against the decrypted database

### v0.4.1 - Robust Auto-Login
- Fix credential storage: switch from Security framework to `security` CLI
- Fix state detection: use status bar menu when AX window is not visible
- Fix login transition: non-aggressive polling avoids interfering with login flow

### v0.4.0 - App Lifecycle & Login (Phase 3.5)
- `login` command: store/check/clear credentials (macOS Keychain)
- AppLifecycle: auto-launch KakaoTalk, auto-login via AX automation
- `ensureReady()` called before all send operations

### v0.3.0 - Agent Integration (Phase 3)
- `sync` command with `--follow` for real-time NDJSON message streaming
- Webhook support: `--webhook <url>` POSTs new message batches
- AGENTS.md: AI agent integration instructions

### v0.2.0 - UI Automation (Phase 2)
- Send messages via macOS Accessibility API
- `send` command with chat name matching
- `--me` flag for self-chat (나와의 채팅) via badge detection
- `inspect` command to dump UI element tree

### v0.1.0 - Database Reader (Phase 1)
- SQLCipher database decryption (PBKDF2-SHA256, cipher_default_compatibility=3)
- Auto-detect device UUID, user ID, container path
- `auth`, `chats`, `messages`, `search`, `schema`, `status` commands
- JSON output for all read commands
