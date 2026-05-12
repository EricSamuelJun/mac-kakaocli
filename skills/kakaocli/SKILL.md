---
name: kakaocli
description: Send and receive KakaoTalk messages via CLI or an Iris-compatible HTTP server
version: 0.7.0
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

`--main` resolves to `policy.primaryChatId` (set during `kakaocli init`). Falls back to `KAKAOCLI_MAIN_CHAT_NAME` env var with a deprecation warning.

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
