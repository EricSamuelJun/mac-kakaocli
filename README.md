# kakaocli

**CLI tool for KakaoTalk on macOS — read chats, search messages, send texts, and integrate with AI agents.**

**macOS용 카카오톡 CLI 도구 — 채팅 읽기, 메시지 검색, 텍스트 전송, AI 에이전트 연동.**

<p align="center">
  <img src="assets/demo.svg" alt="kakaocli demo" width="820">
</p>

> [!NOTE]
> This tool reads KakaoTalk's local database and automates the UI via macOS Accessibility APIs. It does not reverse-engineer the KakaoTalk protocol or call any Kakao APIs. See [Disclaimer](#disclaimer) for details.

---

**[English](#overview)** | **[한국어](#개요)**

---

## Overview

kakaocli lets AI agents (Claude Code, Cursor, custom bots) check and send your KakaoTalk messages — something Kakao's official APIs simply can't do.

- **AI Agent Integration** — JSON output for every command, MCP skill definition, webhook delivery, auto-login
- **Init** — guided first-time setup: permissions, multi-threaded userId recovery, config and policy scaffolding
- **Read** — list chats, view messages, full-text search, raw SQL queries
- **Send** — chatId-first send with optional policy allowlist enforcement (impersonation defence)
- **Serve** — Iris-compatible HTTP server (`POST /reply`) so an orchestrator can swap kakaocli ↔ Iris backends without changing client code
- **Sync** — real-time NDJSON message stream with webhook support
- **Harvest** — bulk-capture chat names and load older message history

### Why?

Kakao's official APIs cannot read chat history, export conversations, or send free-form messages. If you want an AI agent to check your messages, summarize conversations, or reply on your behalf — there's no official way to do it. kakaocli fills that gap by reading the local database and automating the native macOS client.

## 개요

kakaocli는 AI 에이전트(Claude Code, Cursor, 커스텀 봇)가 카카오톡 메시지를 확인하고 보낼 수 있게 해줍니다 — 카카오 공식 API로는 불가능한 기능입니다.

- **AI 에이전트 연동** — 모든 명령의 JSON 출력, MCP 스킬 정의, 웹훅 전달, 자동 로그인
- **초기화** — 권한 안내, 멀티스레드 userId 복원, config/policy 스캐폴딩을 한 번에
- **읽기** — 채팅 목록, 메시지 조회, 전체 텍스트 검색, SQL 쿼리
- **전송** — chatId 기반 송신 + 정책 allowlist 검증 (사칭 방어)
- **HTTP 서버** — Iris 호환 `POST /reply` 엔드포인트. 오케스트레이터가 kakaocli ↔ Iris 백엔드를 클라이언트 코드 변경 없이 교체 가능
- **동기화** — 실시간 NDJSON 메시지 스트림 및 웹훅 지원
- **수집** — 채팅방 이름 일괄 수집 및 이전 메시지 로드

### 왜 필요한가요?

카카오 공식 API로는 채팅 기록을 읽거나, 대화를 내보내거나, 자유로운 메시지를 보낼 수 없습니다. AI 에이전트가 메시지를 확인하거나, 대화를 요약하거나, 대신 답장하게 하고 싶어도 공식적인 방법이 없습니다. kakaocli는 로컬 데이터베이스를 읽고 네이티브 macOS 클라이언트를 자동화하여 이 부분을 해결합니다.

## Getting Started / 시작하기

### 1. Install / 설치

**Option A: Homebrew (recommended)**

```bash
brew install silver-flight-group/tap/kakaocli
```

This installs sqlcipher automatically and builds from source (~20 seconds).

**Option B: Build from source**

```bash
brew install sqlcipher
git clone https://github.com/silver-flight-group/kakaocli.git
cd kakaocli
swift build -c release
# Binary is at .build/release/kakaocli
# Either add to PATH or run directly:
.build/release/kakaocli status
# Or use swift run:
swift run kakaocli status
```

### 2. Grant permissions / 권한 부여

Your terminal app needs two permissions in **System Settings > Privacy & Security**:

터미널 앱에 다음 두 가지 권한이 필요합니다 (**시스템 설정 > 개인정보 보호 및 보안**):

- **Full Disk Access** (전체 디스크 접근) — to read KakaoTalk's encrypted database
- **Accessibility** (접근성) — for UI automation (sending messages, harvest)

> [!NOTE]
> Full Disk Access is required for all commands. Accessibility is only needed for `send`, `harvest`, and `inspect`.

### 3. Initialize / 초기 설정

```bash
# Bootstrap: trigger Accessibility / Full Disk Access prompts,
# recover userId (multithreaded brute-force, ~3-30s),
# scaffold ~/.kakaocli/config.json and ~/.kakaocli/policy.json
kakaocli init
```

The interactive flow lists your most recent direct chats and asks you to pick a primary 1:1 — that chatId becomes the allowlisted target for `send --main` and the policy verifier's first entry. Re-run with `--force` to overwrite; pass `--non-interactive` or `--primary-chat-id <id>` for unattended setup.

초기 설정이 권한 다이얼로그를 띄우고, userId 복원, 본계정 1:1 채팅 선택, `config.json`/`policy.json` 작성을 한 번에 처리합니다. 선택한 chatId가 `send --main`의 타겟이자 정책 verifier의 1차 항목이 됩니다.

### 4. Verify and try it out / 검증 및 사용해보기

```bash
# Verify the resolved config decrypts the DB
kakaocli auth

# List recent chats — note the `id` column; that's the chatId
kakaocli chats --limit 10

# Read messages by chatId (preferred)
kakaocli messages --chat-id 313526436723168 --since 7d

# Send by chatId — verifier-protected
kakaocli send 313526436723168 "안녕!"

# Or by the configured primary chat
kakaocli send --main "test"

# Self-chat (verifier exempt — badge AX)
kakaocli send --me "test message"

# Full-text search
kakaocli search "점심"

# Stream new messages as JSON
kakaocli sync --follow

# Raw SQL
kakaocli query "SELECT COUNT(*) FROM NTChatMessage"
```

> [!TIP]
> `kakaocli send` is chatId-first; pass `--name "name"` for legacy substring matching. Sends to chatIds outside `~/.kakaocli/policy.json` are denied when `denyByDefault` or `strictMode` is on — re-run `kakaocli init` to add entries, or pass `--unsafe-no-verify` for one-off bypass on the chatId path.

## Commands

### Read / 읽기

| Command | Description |
|---------|-------------|
| `kakaocli init` | First-time setup: permissions, userId recovery, scaffold `~/.kakaocli/{config,policy}.json` |
| `kakaocli doctor` | Self-check 13 prerequisites (identity, app, permissions, DB, LaunchAgent, credentials) as `[ok]`/`[warn]`/`[fail]`. `--json` for machine-readable output |
| `kakaocli status` | Check KakaoTalk installation and permissions |
| `kakaocli auth` | Verify the operator config decrypts the database (`(config)`/`(env)`/`(override)`/`(plist)` source label) |
| `kakaocli chats` | List chats sorted by last activity |
| `kakaocli messages --chat-id <id>` | Show messages from a chat by chatId (`--chat "name"` for legacy substring match) |
| `kakaocli search "keyword"` | Full-text search across all messages |
| `kakaocli schema` | Dump raw database schema. `--format markdown\|sql`, `--output PATH` for a versioned dump (e.g. `docs/SCHEMA.md`) |
| `kakaocli query "SQL"` | Run read-only SQL against the decrypted database |
| `kakaocli inspect --open-chat-id <id>` | Open a chat by chatId and dump its AX tree (`--open-chat "name"` for legacy) |

All read commands support `--json` for structured output.

모든 읽기 명령은 `--json` 옵션으로 구조화된 출력을 지원합니다.

### Send / 전송

chatId-first. The chatId path runs through the send-policy verifier (see [Configuration](#configuration--설정)); `--name` is the explicit legacy substring path and is not verifier-protected.

chatId 우선 방식. chatId 경로는 정책 verifier를 통과하며, `--name`은 명시적 legacy 경로로 verifier 적용 안 됨.

```bash
kakaocli send <chatId> "message"                      # primary form — verifier on
kakaocli send --main "message"                         # policy.primaryChatId — verifier on
kakaocli send --me "message"                           # self-chat — badge AX, verifier exempt
kakaocli send --name "chat name" "message"             # legacy substring match — no verifier
kakaocli send --dry-run <chatId> "message"             # preview without sending
kakaocli send <chatId> "message" --unsafe-no-verify    # explicit bypass on chatId path
```

`--main` resolves to `policy.primaryChatId` set during `kakaocli init`. The legacy `KAKAOCLI_MAIN_CHAT_NAME` env var fallback was removed in v0.9.0 — operators on older setups should run `kakaocli init` or `kakaocli policy manage <chatId> --make-primary`.

`--main`은 `kakaocli init`에서 설정한 `policy.primaryChatId`를 사용합니다. 기존 `KAKAOCLI_MAIN_CHAT_NAME` env var fallback은 v0.9.0에서 제거됨 — 구버전 사용자는 `kakaocli init` 또는 `kakaocli policy manage <chatId> --make-primary`로 마이그레이션.

### Sync / 동기화

```bash
kakaocli sync --follow                              # NDJSON stream of new messages
kakaocli sync --follow --interval 1                  # Poll every 1 second
kakaocli sync --follow --webhook http://localhost:8080/kakao  # POST to webhook
kakaocli sync --follow --exclude-self                # Drop messages this bot account sent
```

`--exclude-self` filters out messages where `is_from_me == true` before they reach stdout / the webhook. Required for the **inbound command** flow (Option C) so a dispatcher's own replies don't loop back as fresh commands. See [Configuration → Inbound commands](#configuration--설정) and the LaunchAgent template at `deploy/launchd/com.kakaocli.sync.plist.template`.

`--exclude-self`는 봇 계정이 직접 보낸 메시지를 stdout/webhook 도달 전에 제거합니다. **Option C 인바운드 명령 흐름**에 필수 — 디스패처가 자기 응답을 다시 명령으로 받아 무한 루프 도는 것 차단.

See [AGENTS.md](AGENTS.md) for AI agent integration instructions.

### Serve / HTTP 서버

Expose an Iris-compatible HTTP endpoint so an orchestrator (Spring Boot, Hermes, etc.) can talk to kakaocli over the network. Wire format matches the [Iris bot's](https://github.com/dolidolih/Iris) `POST /reply` so the same orchestrator can later swap to `irisbot` (Android) by only changing the target URL.

Iris 호환 HTTP 엔드포인트를 노출합니다. 오케스트레이터(Spring Boot, Hermes 등)가 네트워크로 kakaocli에 접근할 수 있고, 와이어 포맷이 [Iris bot의](https://github.com/dolidolih/Iris) `POST /reply`와 동일해서 향후 `irisbot`(Android)으로 교체 시 URL만 바꾸면 됩니다.

```bash
# Start the server. Defaults: 127.0.0.1:8080, logs at ~/.kakaocli/serve.log
kakaocli serve

# Tailscale / LAN exposure (Spring Boot on a separate node)
kakaocli serve --host 0.0.0.0 --port 8080

# Foreground with stdout logs (development)
kakaocli serve --log -

# Environment variable overrides (LaunchAgent / docker)
KAKAOCLI_SERVE_HOST=0.0.0.0 KAKAOCLI_SERVE_PORT=8080 kakaocli serve
```

Endpoints:
- `POST /reply` — body `{"type":"text","room":"<chatId>","data":"<message>","threadId":null}` (the `threadId` field is accepted for Iris compatibility but currently ignored). Send-policy gated, **no per-request bypass**.
- `GET /chats?limit=N` — chat list in the same shape as `kakaocli chats --json`. Default limit `50`, must be a positive integer.
- `GET /chat/{room}` — single chat by chatId. Adds `direct_member_user_id` (omitted for groups / channels). Returns `404` + `{success:false}` for unknown chatIds.
- `GET /health` — `{"status":"ok"}`.

`room` is the numeric KakaoTalk chatId as a string. Look it up with `kakaocli chats --json`, `kakaocli query "SELECT chatId FROM NTChatRoom WHERE ..."`, or `GET /chats` over HTTP.

Every `/reply` is gated by the send-policy verifier — chatIds outside `~/.kakaocli/policy.json` are denied when `denyByDefault` or `strictMode` is on. The HTTP path has **no per-request bypass**; misconfiguration is strictly a `policy.json` edit. See [Configuration](#configuration--설정). The read endpoints (`/chats`, `/chat/{room}`) are **not** policy-gated — they expose the same data `kakaocli chats` and `kakaocli messages` already produce from the CLI on the same host.

`room`은 카카오톡 chatId(숫자)를 문자열로 받습니다. `kakaocli chats --json`, `kakaocli query`, 또는 HTTP `GET /chats`로 조회하세요. 모든 `/reply` 호출은 정책 verifier를 통과해야 하며, HTTP 경로에는 per-request 우회 옵션이 없습니다. 읽기 엔드포인트(`/chats`, `/chat/{room}`)는 정책 검증 대상이 아닙니다 — 같은 호스트의 `kakaocli chats` / `kakaocli messages`가 이미 노출하는 데이터입니다.

#### Running as a LaunchAgent (recommended for production)

macOS isolates SSH sessions from the GUI WindowServer / Accessibility APIs, so `kakaocli serve` started over SSH listens on the port but every `/reply` request fails with `did not become ready within timeout` when it tries to drive the UI. Launching the server inside the user's GUI session via `launchctl` solves this. A template is provided.

macOS는 SSH 세션을 GUI WindowServer/접근성 API와 분리하기 때문에, SSH에서 띄운 `kakaocli serve`는 포트는 열리지만 `/reply` 요청 시 UI 자동화가 실패합니다. `launchctl`로 GUI 세션에 띄우면 해결됩니다. 템플릿이 함께 제공됩니다.

```bash
# 1. Copy the template and edit __REPLACE_*__ placeholders
cp deploy/launchd/com.kakaocli.serve.plist.template \
   ~/Library/LaunchAgents/com.kakaocli.serve.plist
$EDITOR ~/Library/LaunchAgents/com.kakaocli.serve.plist

# 2. Validate plist syntax
plutil ~/Library/LaunchAgents/com.kakaocli.serve.plist

# 3. Load
launchctl bootstrap gui/$(id -u) \
   ~/Library/LaunchAgents/com.kakaocli.serve.plist

# 4. Verify
launchctl list | grep kakaocli      # PID + exit code
curl -s http://127.0.0.1:8080/health
tail -f ~/.kakaocli/serve.log

# Unload
launchctl bootout gui/$(id -u) \
   ~/Library/LaunchAgents/com.kakaocli.serve.plist
```

The first `/reply` after a fresh install may trigger Accessibility / Full Disk Access prompts — approve them via Chrome Remote Desktop or another GUI session. They are persistent after the first approval.

신규 설치 후 첫 `/reply` 호출 시 접근성/전체 디스크 접근 프롬프트가 뜰 수 있습니다 — Chrome Remote Desktop 등 GUI 세션에서 승인하세요. 한 번 승인 후 영구 유지됩니다.

> [!IMPORTANT]
> The shipped template includes `<key>LimitLoadToSessionType</key><string>Aqua</string>`. Without it, even `launchctl bootstrap gui/<uid>` can put the LaunchAgent in a session where `NSRunningApplication.runningApplications(withBundleIdentifier:)` returns an empty array for KakaoTalk. The agent then mis-detects the app as `notRunning` and every `/reply` times out with `KakaoTalk launched but did not become ready within timeout`. If you're upgrading from a plist written before 2026-05-12, add the two lines manually and `bootout` → `bootstrap`.
>
> 템플릿엔 `LimitLoadToSessionType=Aqua` 가 포함되어 있습니다. 빠지면 `launchctl bootstrap gui/<uid>`로 띄워도 LaunchAgent가 GUI 세션 밖에 떠서 `NSRunningApplication.runningApplications(...)`가 카카오톡 process를 못 봅니다 — 모든 `/reply`가 "did not become ready within timeout"으로 실패합니다. 2026-05-12 이전 plist는 두 줄 수동 추가 후 `bootout`/`bootstrap` 재시작.

### Harvest / 수집

```bash
kakaocli harvest                   # Capture display names for all chats
kakaocli harvest --scroll          # Also load older message history
kakaocli harvest --scroll --top 20 # Process top 20 most recent chats
kakaocli harvest --dry-run         # Preview without changes
```

The harvest command iterates through your chat list to:
1. Capture **display names** from the UI (many group chats show `(unknown)` in the database)
2. With `--scroll`: open each chat, scroll to top, click "View Previous Chats" to load older messages
3. Auto-dismiss **Talk Drive Plus paywall** popups
4. Save metadata to `~/.kakaocli/metadata.json`

Chats with unread messages are skipped to avoid marking them as read.

### Login / 로그인

```bash
kakaocli login                                       # Store credentials (interactive)
kakaocli login --email user@example.com --password pw # Non-interactive
kakaocli login --status                               # Check status
kakaocli login --clear                                # Remove credentials
```

When you run `send`, `sync`, or any command that needs KakaoTalk, the tool automatically launches the app, detects the login screen, fills credentials, and waits for login to complete.

## Configuration / 설정

`kakaocli init` scaffolds two JSON files in `~/.kakaocli/`. Both are owner-readable only (0600).

### `config.json` — operator identity

```json
{
  "version": 1,
  "userId": 361746971,
  "deviceUUID": null,
  "databasePath": null
}
```

- `userId` — your KakaoTalk userId, recovered via parallel SHA-512 brute-force during init. Required to derive the SQLCipher database key.
- `deviceUUID`, `databasePath` — optional overrides for unusual setups. `null` means auto-detect.

Resolution order for `userId`: `KAKAOCLI_USER_ID` env var → `config.json` → plist auto-detection. The env var still wins as a one-off override (useful for cron / CI / alternate accounts).

### `policy.json` — send-policy allowlist

```json
{
  "version": 1,
  "allowlist": [
    {
      "chatId": 313526436723168,
      "expectedName": "전성욱",
      "expectedUserId": 68062272,
      "purpose": "primary_account_1on1",
      "alias": null
    },
    {
      "chatId": 468542230323777,
      "expectedName": "테스트",
      "expectedUserId": null,
      "purpose": "test_group",
      "alias": "49기방"
    }
  ],
  "strictMode": false,
  "denyByDefault": true,
  "primaryChatId": 313526436723168
}
```

`alias` is an optional human-friendly label that orchestrators (Hermes, LLMs) resolve to a chatId via `kakaocli policy list --json`. Aliases must be unique across the allowlist; the `policy add` / `policy manage` commands reject duplicates.

Sends through chatId paths (`send <chatId>`, `send --main`, HTTP `POST /reply`) are verified against this allowlist:

| Decision matrix | strictMode | denyByDefault | Unknown chatId | Allowlist mismatch |
|-----------------|------------|---------------|----------------|---------------------|
| Strict | `true` | (any) | **deny** | **deny** |
| Deny-by-default | `false` | `true` | **deny** | **deny** |
| Advisory | `false` | `false` | warn + allow | **deny** |

- `expectedName` is compared via NFC + trim + lowercase **substring** match — group titles with member-count suffixes ("테스트 5" matching "테스트") still verify cleanly.
- `expectedUserId` pins the other side of a 1:1 chat against `NTChatRoom.directChatMemberUserId`. `null` skips this check (groups, self-chat, open channels).
- CLI `send --name` and `send --me` skip verification by design. HTTP `/reply` has no bypass — misconfiguration is a `policy.json` edit, not a per-request override.

#### Managing entries via `kakaocli policy`

`kakaocli init --force` re-scaffolds the file from scratch; for incremental edits the `policy` subcommand group is the recommended path. Both interactive and non-interactive flows exist so the same commands work for operators at a terminal and for Hermes / LLM agents driving the skill manifest.

```bash
# Inspect current state (★ marks the primary chat)
kakaocli policy list
kakaocli policy list --json           # for orchestrators — includes is_primary per entry

# Add a chat — no flags = interactive picker over recent un-allowlisted chats
kakaocli policy add

# Non-interactive add (Hermes / scripts)
kakaocli policy add --chat-id 468542230323777 \
                    --alias "49기방" \
                    --purpose "test_group_cron"

# Edit / remove a single entry — interactive menu by default
kakaocli policy manage 468542230323777

# Or flag-driven (any combination)
kakaocli policy manage 468542230323777 --set-alias "49기방"
kakaocli policy manage 468542230323777 --pin-user-id
kakaocli policy manage 468542230323777 --make-primary       # prompts to replace current primary
kakaocli policy manage 468542230323777 --remove --yes       # skips the confirmation
```

Editing `policy.json` by hand still works — a malformed file is logged to stderr and treated as "no policy" so a bad edit doesn't lock the operator out.

설정 파일은 두 개로 도메인 분리되어 있습니다 — `config.json`은 식별자/경로, `policy.json`은 송신 권한. chatId 경로 송신은 allowlist를 통과해야 하고, 이름·userId 불일치 시 거부됩니다 (사칭 / 채팅 리스트 재정렬 방어). 잘못 편집된 `policy.json`은 "no policy"로 처리되니 락아웃되지 않습니다.

#### Inbound commands (Option C, opt-in)

By default kakaocli treats every inbound KakaoTalk message as conversation. Operators who want KakaoTalk to be a **command channel** (not just an output channel) opt in by adding three fields to `policy.json`:

```json
{
  "commandPrefix": "!명령",
  "commandAcl": [
    { "userId": 68062272, "role": "system",  "purpose": "owner" },
    { "userId": 11111111, "role": "general", "purpose": "family" }
  ],
  "rolePermissions": {
    "system":  ["*"],
    "general": ["search", "messages.read"]
  }
}
```

- `commandPrefix` — message must trim-start with this string to be a command attempt. Pre-LLM gate.
- `commandAcl` — operator-curated `userId → role` mapping. Senders not on the list are denied regardless of message content.
- `rolePermissions` — `role → [permission strings]`. `"*"` grants every permission. Permission names are operator-defined; kakaocli treats them opaquely.

Verification CLI for dispatchers (Hermes, custom scripts):

```bash
kakaocli policy verify-command \
  --sender-id <senderUserId> \
  --message "<raw text>" \
  --permission "<derived permission>"
# Exit code: 0 allow, 1 deny (logs reason), 2 not a command (silent ignore)
```

The end-to-end flow is documented in [skills/kakaocli/SKILL.md](skills/kakaocli/SKILL.md#inbound-command-processing-option-c) — the dispatcher subscribes to `kakaocli sync --follow --exclude-self`, extracts intent via the LLM, calls `verify-command`, and branches on the exit code. The LaunchAgent template at `deploy/launchd/com.kakaocli.sync.plist.template` runs that subscription in the Aqua session.

기본값은 인바운드 카톡 메시지를 대화로만 처리합니다. Option C는 명시적 opt-in — 위 세 필드를 `policy.json`에 추가하면 prefix로 시작하는 메시지만 명령으로 해석되고, ACL/role로 권한이 제한됩니다. 디스패처 (Hermes 등)는 `kakaocli policy verify-command`를 호출해 exit code (0/1/2)로 분기합니다.

## AI Integration / AI 연동

kakaocli is designed to work with AI coding assistants and agents. Every read command outputs structured JSON, and the tool handles KakaoTalk's full lifecycle automatically (launch, login, window management).

### Claude Code

Add kakaocli as a skill in your project's `CLAUDE.md`:

```markdown
## KakaoTalk Integration

Use `kakaocli` to read and send KakaoTalk messages. The `id` field in
`kakaocli chats --json` is the chatId — that's the canonical identifier
across all commands.

- `kakaocli chats --json` — list all chats
- `kakaocli messages --chat-id <id> --json` — read messages by chatId
- `kakaocli search "keyword" --json` — full-text search
- `kakaocli send <chatId> "message"` — send by chatId (verifier-protected)
- `kakaocli send --main "message"` — send to the operator's primary chat
- `kakaocli send --me "message"` — send to self-chat (safe for testing)
```

Or copy the skill file directly:

```bash
# Copy the skill definition to your project
cp skills/kakaocli/SKILL.md /path/to/your/project/.claude/skills/
```

Claude Code can then read your KakaoTalk messages, search conversations, and send messages on your behalf.

### Cursor / Windsurf / Other AI Editors

Add to your project rules or `.cursorrules`:

```
You have access to kakaocli for KakaoTalk messaging.
Run `kakaocli chats --json` to list chats — each row's `id` is the chatId.
Run `kakaocli messages --chat-id <id> --since 1d --json` to read messages.
Run `kakaocli send <chatId> "message"` to send by chatId (verifier on).
Always use --me flag when testing: `kakaocli send --me "test"`.
Always ask for confirmation before sending messages to other people.
```

### Webhooks & Real-time Agents

For agents that need to react to incoming messages in real-time:

```bash
# Stream new messages as NDJSON (pipe to your agent)
kakaocli sync --follow | your-agent-processor

# Or POST to a webhook endpoint
kakaocli sync --follow --webhook http://localhost:8080/kakao
```

Each new message is delivered as a JSON object:

```json
{"chatId": 123, "logId": 456, "author": "김지수", "message": "안녕!", "sentAt": "2026-02-20T09:15:00Z"}
```

### OpenClaw

A kakaocli [skill definition](skills/kakaocli/SKILL.md) is included for use with [OpenClaw](https://github.com/nichochar/open-claw) or similar skill registries.

See [AGENTS.md](AGENTS.md) for detailed integration instructions including credential setup, lifecycle management, and error handling.

## How It Works / 동작 원리

kakaocli reads KakaoTalk's local SQLCipher-encrypted database in **read-only mode** — it never modifies the database. For sending messages and UI interactions, it uses macOS Accessibility APIs (AXUIElement) to automate the native KakaoTalk client.

kakaocli는 카카오톡의 로컬 SQLCipher 암호화 데이터베이스를 **읽기 전용 모드**로 읽습니다 — 데이터베이스를 절대 수정하지 않습니다. 메시지 전송 및 UI 상호작용에는 macOS 접근성 API(AXUIElement)를 사용하여 네이티브 카카오톡 클라이언트를 자동화합니다.

## Known Limitations / 알려진 제한 사항

> [!WARNING]
> **macOS only.** This tool works exclusively with KakaoTalk for Mac. It does not support Windows, mobile, or web versions.

- **Incomplete message history.** KakaoTalk Mac only syncs messages from the server when you open a chat. If you haven't opened a chat on your Mac in a while (or ever), older messages won't be in the local database. Use `kakaocli harvest --scroll` to trigger loading older history, but this is limited by KakaoTalk's own sync behavior and the Talk Drive Plus paywall.
- **Group chat names may show as `(unknown)`.** The database doesn't always store display names for group chats. Run `kakaocli harvest` to capture names from the UI.
- **Sending requires KakaoTalk to be running.** Read commands work without the app open, but `send`, `sync`, and `harvest` need the KakaoTalk window. kakaocli launches and logs in automatically if credentials are stored.
- **GUI session must be awake.** Accessibility automation talks to the WindowServer, which is only reachable from an active GUI login session. `send` / `harvest` / `serve` will silently fail (or time out with "did not become ready") when the Mac is in sleep mode, the display is locked at the login window, or only an SSH session is active. For unattended operation, keep the Mac logged in via Chrome Remote Desktop / a kiosk session and disable display sleep (`System Settings > Lock Screen`, `caffeinate -d`, or `pmset -a displaysleep 0` for desk machines).
- **One Mac at a time.** KakaoTalk only allows one Mac logged in per account.
- **Media and non-text messages.** Currently only text messages are fully supported. Photos, videos, stickers, and other media types are visible in the database but not rendered.

> [!WARNING]
> **macOS 전용.** 이 도구는 카카오톡 Mac 버전에서만 작동합니다.

- **불완전한 메시지 기록.** 카카오톡 Mac은 채팅을 열어야 서버에서 메시지를 동기화합니다. Mac에서 오래 열지 않은 채팅은 이전 메시지가 로컬 데이터베이스에 없을 수 있습니다. `kakaocli harvest --scroll`로 이전 메시지 로드를 시도할 수 있지만, 카카오톡 자체 동기화 및 톡드라이브 플러스 페이월에 의해 제한됩니다.
- **그룹 채팅 이름이 `(unknown)`으로 표시될 수 있습니다.** `kakaocli harvest`를 실행하여 UI에서 이름을 수집하세요.
- **전송 시 카카오톡 실행 필요.** 읽기 명령은 앱 없이 작동하지만, `send`, `sync`, `harvest`는 카카오톡 창이 필요합니다.
- **GUI 세션 활성 상태 필요.** 접근성 자동화는 macOS GUI 세션의 WindowServer를 거치므로, Mac이 슬립 상태이거나 로그인 화면이 잠겨있거나 SSH 세션만 떠 있으면 `send` / `harvest` / `serve`가 조용히 실패합니다 ("did not become ready" 타임아웃). 무인 운영 시엔 GUI 로그인을 유지하고 (Chrome Remote Desktop 등) 디스플레이 슬립을 끄세요 (`시스템 설정 > 잠금 화면`, `caffeinate -d`, 또는 `pmset -a displaysleep 0`).
- **계정당 Mac 1대.** 카카오톡은 계정당 하나의 Mac만 로그인을 허용합니다.
- **미디어 및 비텍스트 메시지.** 현재 텍스트 메시지만 완전히 지원됩니다.

## Disclaimer

> **This project is not affiliated with, endorsed by, or associated with Kakao Corp. in any way.**
>
> "KakaoTalk" and "카카오톡" are trademarks of Kakao Corp. This tool is an independent, unofficial project.
>
> **What this tool does:**
> - Reads the KakaoTalk local database on your own machine (read-only, never modifies it)
> - Automates the native KakaoTalk Mac client via standard macOS Accessibility APIs
>
> **What this tool does NOT do:**
> - Does not reverse-engineer or reimplement the KakaoTalk protocol (LOCO)
> - Does not call any Kakao APIs or servers
> - Does not decompile or modify the KakaoTalk application
> - Does not bypass any authentication or security mechanisms
>
> This tool accesses only your own data stored locally on your own computer. Use responsibly and at your own risk. The authors are not responsible for any consequences of using this software, including but not limited to account restrictions by Kakao.

## 면책 조항

> **이 프로젝트는 카카오와 제휴, 보증, 또는 관련이 없습니다.**
>
> "KakaoTalk" 및 "카카오톡"은 카카오의 상표입니다. 이 도구는 독립적인 비공식 프로젝트입니다.
>
> **이 도구가 하는 것:**
> - 사용자의 컴퓨터에 있는 카카오톡 로컬 데이터베이스를 읽기 전용으로 읽습니다
> - 표준 macOS 접근성 API를 통해 카카오톡 Mac 클라이언트를 자동화합니다
>
> **이 도구가 하지 않는 것:**
> - 카카오톡 프로토콜(LOCO)을 역분석하거나 재구현하지 않습니다
> - 카카오 API나 서버를 호출하지 않습니다
> - 카카오톡 애플리케이션을 디컴파일하거나 수정하지 않습니다
>
> 이 도구는 사용자 본인의 컴퓨터에 저장된 본인의 데이터에만 접근합니다. 책임감 있게 사용하시기 바랍니다. 카카오의 계정 제한 등 이 소프트웨어 사용으로 인한 결과에 대해 저자는 책임지지 않습니다.

## Credits / 크레딧

Developed by **[Brian ByungHyun Shin](https://github.com/brianshin22)** at **[Silver Flight Group](https://github.com/silver-flight-group)**.

Database decryption approach based on research by [blluv](https://gist.github.com/blluv/8418e3ef4f4aa86004657ea524f2de14).

Inspired by [wacli](https://github.com/steipete/wacli) by Peter Steinberger — a similar CLI tool for WhatsApp on Mac.

Built with [Claude Code](https://claude.ai/code).

## License

MIT License. Copyright (c) 2026 Silver Flight Group, LLC. See [LICENSE](LICENSE) for details.

## [Changelog](CHANGELOG.md)
