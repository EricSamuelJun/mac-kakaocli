---
name: kakaocli
description: Send and receive KakaoTalk messages via CLI or an Iris-compatible HTTP server
version: 0.6.0
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

```bash
# Store credentials for auto-login
kakaocli login --email user@example.com --password yourpassword
```

## Available Commands

### Check Status
```bash
kakaocli login --status
```

### List Chats
```bash
kakaocli chats --json
```

### Read Messages
```bash
kakaocli messages --chat "Name" --since 1h --json
```

### Send Message
```bash
kakaocli send "Name" "Your message here"
```

### Send to Self-Chat (Testing)
```bash
kakaocli send _ --me "Test message"
```

### Send to Primary Account (env-configured)
```bash
# Requires KAKAOCLI_MAIN_CHAT_NAME env var set to the operator's primary chat name
kakaocli send _ --main "Notification text"
```

### Run as an HTTP Backend (Iris-compatible)
```bash
# Foreground (dev / debug); defaults: 127.0.0.1:8080, log at ~/.kakaocli/serve.log
kakaocli serve --log -

# Send a message via HTTP from any caller (Spring Boot, curl, agent)
curl -s -X POST http://127.0.0.1:8080/reply \
  -H "Content-Type: application/json" \
  -d '{"type":"text","room":"<chatId>","data":"hello"}'

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

### Harvest Chat Names & History
```bash
# Capture display names for all chats
kakaocli harvest

# Full harvest with scroll + history loading
kakaocli harvest --scroll --top 20
```

## Usage Guidelines

- Always confirm before sending messages to others
- Use `--me` flag and `--dry-run` for testing
- Rate limit: max 1 message per 2 seconds
- Don't send messages between 11 PM and 7 AM unless urgent
- KakaoTalk is auto-launched and auto-logged-in when credentials are stored
- First-time setup requires `kakaocli login --email ... --password ...`
- For HTTP `POST /reply`, always identify the target by numeric `chatId` (not name). Lookup with `kakaocli chats --json`. The HTTP path does not support name-based aliases — use `--main` / `--me` on the CLI for those.
