# Changelog

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
