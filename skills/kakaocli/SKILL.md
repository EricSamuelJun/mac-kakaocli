---
name: kakaocli
description: Send and receive KakaoTalk messages via CLI or an Iris-compatible HTTP server
version: 0.9.0
requires:
  binaries:
    - kakaocli
  platform: darwin
tags:
  - messaging
  - kakaotalk
  - korea
  - http
---

# KakaoTalk CLI Skill

Read and send KakaoTalk messages from the command line. Requires macOS with KakaoTalk desktop app installed. Auto-launches and auto-logs in when credentials are stored.

## Setup (Required First Time)

Two commands. `init` is one-shot — it triggers permission prompts, recovers the operator's userId, and scaffolds `~/.kakaocli/config.json` + `policy.json`. `login` stores credentials for KakaoTalk auto-login.

```bash
kakaocli init                                             # bootstrap
kakaocli login --email user@example.com --password ...    # credentials for auto-login
```

## Available Commands

### Check Status
```bash
kakaocli auth              # verify operator config decrypts the DB
kakaocli login --status    # KakaoTalk app state and credential storage
```

### List Chats
```bash
kakaocli chats --json   # the `id` field is the chatId — use it everywhere downstream
```

### Read Messages (chatId-first)
```bash
kakaocli messages --chat-id 313526436723168 --since 1h --json
kakaocli messages --chat "Name" --since 1h --json          # legacy substring
```

### Send Message (chatId-first)
```bash
kakaocli send 313526436723168 "Your message"               # primary form — verifier on
kakaocli send --main "Notification"                         # policy.primaryChatId — verifier on
kakaocli send --me "Test message"                           # self-chat — verifier exempt
kakaocli send --name "Mom" "Hello"                          # legacy substring — no verifier
kakaocli send 313526436723168 "msg" --unsafe-no-verify     # explicit bypass
```

`--main` resolves to `policy.primaryChatId` (set during `kakaocli init`). The legacy `KAKAOCLI_MAIN_CHAT_NAME` env var fallback was removed in v0.9.0.

### Send Policy

Sends through chatId paths (`send <chatId>`, `send --main`, HTTP `/reply`) are verified against `~/.kakaocli/policy.json`:

- chatId in allowlist: name + userId cross-checked, mismatch → deny
- chatId not in allowlist: denied when `strictMode` or `denyByDefault` is true; otherwise warn + allow
- CLI `--name` and `--me` skip verification by design

Re-run `kakaocli init --force` to refresh the allowlist after KakaoTalk schema or chat changes.

### Run as an HTTP Backend (Iris-compatible)
```bash
# Foreground (dev / debug); defaults: 127.0.0.1:8080, log at ~/.kakaocli/serve.log
kakaocli serve --log -

# Send via HTTP — `room` is the numeric chatId as a string. Verifier always on.
curl -s -X POST http://127.0.0.1:8080/reply \
  -H "Content-Type: application/json" \
  -d '{"type":"text","room":"<chatId>","data":"hello"}'

# Look up chats (read-only, not policy-gated) — useful when the caller only knows a name.
curl -s 'http://127.0.0.1:8080/chats?limit=20' | jq
curl -s http://127.0.0.1:8080/chat/<chatId> | jq   # adds direct_member_user_id for 1:1 chats

# Health check
curl -s http://127.0.0.1:8080/health
```
For unattended use, install the LaunchAgent template at `deploy/launchd/com.kakaocli.serve.plist.template` (see README "Serve / HTTP 서버" section). The LaunchAgent is required because macOS isolates SSH sessions from the Accessibility APIs the UI automation depends on.

### Export Database Schema
```bash
kakaocli schema --format markdown -o docs/SCHEMA.md
```

### Manage the Send-Policy Allowlist
```bash
# Resolve a human alias (e.g. "49기방") to its chatId
kakaocli policy list --json | jq -r '.entries[] | select(.alias=="49기방") | .chat_id'

# Add a chat to the allowlist (non-interactive)
kakaocli policy add --chat-id <chatId> --alias "<label>" --purpose "<note>"

# Modify an entry
kakaocli policy manage <chatId> --set-alias "<label>"
kakaocli policy manage <chatId> --pin-user-id
kakaocli policy manage <chatId> --make-primary --yes
kakaocli policy manage <chatId> --remove --yes
```
Aliases must be unique across the allowlist; collisions return a non-zero exit. `--yes` skips the [y/N] confirmation that `--make-primary` and `--remove` ask for interactively.

### Resolving Natural-Language Labels (Hermes / LLM agents)

Operator prompts arrive with human labels, not chatIds:

> "49기방에 매일 1시간마다 뉴스 정리해서 보내줘"
> "유희왕 방에 정오 12시 3분마다 'TCG 마이너갤러리' 신규 정보 글 올려줘"
> "지금 일본선교팀방에 무슨 공지가 떴는지 확인해줘"

The agent's job is to turn each label into a chatId via the policy file. Recommended flow:

```python
import json, subprocess

# 1. Build alias → chatId map (read-only, fast)
policy = json.loads(subprocess.run(
    ["kakaocli", "policy", "list", "--json"],
    capture_output=True, text=True, check=True,
).stdout)
alias_to_chat = {e["alias"]: e["chat_id"] for e in policy["entries"] if e["alias"]}

# 2. Resolve the label the operator used
label = "49기방"
chat_id = alias_to_chat.get(label)
if chat_id is None:
    # Aliases are operator-curated. If missing, ask the operator to run:
    #   kakaocli policy add --chat-id <id> --alias "<label>" --purpose "<note>"
    raise RuntimeError(f"No policy entry has alias '{label}'.")

# 3. Drive any downstream command with the resolved chatId
subprocess.run(["kakaocli", "send", str(chat_id), "Today's news …"], check=True)
# or read-back:
subprocess.run(["kakaocli", "messages", "--chat-id", str(chat_id), "--since", "1h", "--json"], ...)
```

Operating principles:

- **Aliases are operator-curated, not LLM-derived.** Never auto-create an alias from a parsed label — the operator must `kakaocli policy add` it explicitly. This keeps the policy file authoritative and the verifier honest.
- **One alias, one chatId.** `policy add` / `policy manage --set-alias` reject collisions, so the reverse mapping stays total.
- **Aliases work for read paths too.** `kakaocli messages --chat-id <resolved>`, `inspect --open-chat-id <resolved>`, and `sync --follow` all take the chatId; the policy file is the only place that knows the human-readable label.
- **HTTP path is identical.** `POST /reply` body's `room` is the same chatId string; resolve once and call either `kakaocli send` or the HTTP endpoint with the same value.

### Watch for New Messages
```bash
kakaocli sync --follow
```

### Search Messages
```bash
kakaocli search "keyword" --json
```

### Inspect AX Tree (debug)
```bash
kakaocli inspect --open-chat-id 313526436723168 --depth 4
kakaocli inspect --open-chat "Name" --depth 4    # legacy substring
```

### Harvest Chat Names & History
```bash
kakaocli harvest --chat-id 313526436723168               # single chat (stable across UI reorders)
kakaocli harvest --chat-ids 313526436723168,468542230323777
kakaocli harvest --scroll --top 20                       # legacy top-N by recency
```

## Usage Guidelines

- **Always identify targets by chatId** — `kakaocli chats --json` exposes it as `id`. chatId is the canonical key across send / messages / inspect / harvest. Substring name matching is a legacy convenience and is **not** verifier-protected.
- Always confirm before sending messages to others
- Use `--me` flag and `--dry-run` for testing
- Rate limit: max 1 message per 2 seconds
- Don't send messages between 11 PM and 7 AM unless urgent
- KakaoTalk is auto-launched and auto-logged-in when credentials are stored
- First-time setup: `kakaocli init` then `kakaocli login --email ... --password ...`
- HTTP `POST /reply` enforces the same policy as CLI chatId sends — there is no per-request bypass on the HTTP path
