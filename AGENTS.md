# AGENTS.md — KakaoCLI for AI Agents

Instructions for AI agents that want to read and send KakaoTalk messages.

## Prerequisites

- macOS 14+ with KakaoTalk desktop app installed
- `kakaocli` binary built and in PATH (or run via `swift run kakaocli`)
- System Settings > Privacy & Security: **Full Disk Access** + **Accessibility** granted to your terminal
- KakaoTalk credentials stored (see First-Time Setup below)

## First-Time Setup

Before using kakaocli, store credentials so the tool can auto-login:

```bash
# Store KakaoTalk credentials (saved in macOS Keychain)
kakaocli login --email user@example.com --password yourpassword

# Verify everything is working
kakaocli login --status
# Expected output includes: "Stored credentials: Yes"
```

**Important for AI agents:** The `--password` flag is required in non-interactive contexts (scripts, automation, Claude Code). The interactive `kakaocli login` prompt uses `getpass()` which doesn't work outside a real terminal.

### Credential Storage

- Stored in macOS login Keychain under service `com.kakaocli.credentials`
- Two items: `kakaotalk-email` and `kakaotalk-password`
- Persists across reboots, encrypted by macOS (AES-256-GCM)
- Accessible by any process running as the current macOS user
- Uses `security` CLI tool (not Security.framework) to avoid code-signing ACL issues

To inspect or manage credentials manually:
```bash
# Read stored email
security find-generic-password -s "com.kakaocli.credentials" -a "kakaotalk-email" -w

# Delete stored credentials
security delete-generic-password -s "com.kakaocli.credentials" -a "kakaotalk-email"
security delete-generic-password -s "com.kakaocli.credentials" -a "kakaotalk-password"
```

## Automatic Lifecycle Management

You do **NOT** need to manually launch or log into KakaoTalk. The tool handles it automatically:

| Situation | What happens |
|-----------|-------------|
| App not running | Launches KakaoTalk via `NSWorkspace` |
| Login screen showing | Auto-fills credentials and clicks "Log in" |
| "Keep me logged in" | Checked automatically — future launches skip login |
| Window hidden (menu bar only) | Detects state via status bar menu items |
| Already logged in | Proceeds immediately |

The first auto-login after a fresh install takes 5-10 seconds. With "Keep me logged in" checked, subsequent launches are near-instant.

### App State Detection

```bash
kakaocli login --status
```

| State | Meaning |
|-------|---------|
| `loggedIn` | Ready to use |
| `loginScreen` | Needs login (will auto-login if credentials stored) |
| `notRunning` | KakaoTalk not running (will auto-launch on next command) |
| `launching` | App starting up |
| `unknown` | Transient state during transitions |

### Known AX Quirks

KakaoTalk's macOS Accessibility (AX) hierarchy is non-standard:
- `kAXWindowsAttribute` may return `AXApplication` elements instead of `AXWindow`
- When the window is hidden (app running in menu bar), there are zero real AXWindow elements
- The **status bar menu** is the most reliable state indicator ("Log out" present = logged in)
- After login, the window briefly disappears during the transition — don't poll aggressively

## Quick Start

```bash
# Verify database access
kakaocli auth

# List recent chats
kakaocli chats --json

# Read messages from a specific chat
kakaocli messages --chat "Mom" --since 1h --json

# Send a message (auto-launches and logs in if needed)
kakaocli send "Mom" "I'll be home soon"

# Send to self-chat (for testing — ALWAYS use this for tests)
kakaocli send x --me "Test message"

# Watch for new messages (NDJSON stream)
kakaocli sync --follow
```

## Reading Messages

### List Chats
```bash
kakaocli chats --json --limit 20
```
Returns: `[{"id", "type", "display_name", "member_count", "unread_count", "last_message_at"}]`

### Read Messages
```bash
kakaocli messages --chat "Name" --since 1h --json
kakaocli messages --chat-id 12345 --limit 100 --json
```
Returns: `[{"id", "chat_id", "sender_id", "sender", "text", "type", "timestamp", "is_from_me"}]`

### Search
```bash
kakaocli search "keyword" --json
```

## Sending Messages

```bash
kakaocli send "Chat Name" "Message text"
kakaocli send _ --me "Self-chat message"     # --me flag for self-chat
kakaocli send _ --main "Notification"        # --main reads KAKAOCLI_MAIN_CHAT_NAME env
kakaocli send "Mom" "Hello" --dry-run        # Preview without sending
```

**Important constraints:**
- KakaoTalk is auto-launched if needed (no need to start it manually)
- UI automation needs Accessibility permission granted to your terminal
- Rate limit: wait at least 2 seconds between sends
- The chat window opens, types, sends, then closes automatically
- The `--me` flag sends to self-chat regardless of the chat name argument (use `_` as placeholder)
- The `--main` flag is the same pattern but reads the chat name from `KAKAOCLI_MAIN_CHAT_NAME` — use it from cron/agent scripts so the operator's primary-account name is not baked in. `--me` and `--main` are mutually exclusive.

## HTTP Server (Iris-Compatible)

For agents and orchestrators that prefer HTTP over a CLI subprocess, `kakaocli serve` exposes a minimal endpoint that accepts the same JSON shape as the [Iris bot's](https://github.com/dolidolih/Iris) `POST /reply`. This means a Spring Boot / Hermes orchestrator can target `kakaocli serve` today and swap to `irisbot` (Android) later by changing only the URL — both backends accept identical payloads.

### Starting the Server

```bash
# Foreground, stdout logs (development)
kakaocli serve --log -

# Bind to all interfaces (e.g. Tailscale exposure)
kakaocli serve --host 0.0.0.0 --port 8080

# Env-driven (LaunchAgent / Docker)
KAKAOCLI_SERVE_HOST=0.0.0.0 KAKAOCLI_SERVE_PORT=8080 kakaocli serve
```

Defaults: `127.0.0.1:8080`. Log file: `~/.kakaocli/serve.log` (JSON-line). Pass `--log -` to stream to stdout instead.

### Wire Format

`POST /reply` — Content-Type: `application/json`

Request:
```json
{"type": "text", "room": "313526436723168", "data": "Hello"}
```
- `type`: only `"text"` is supported in Phase 1.
- `room`: numeric KakaoTalk chatId as a string. Look up with `kakaocli chats --json`. No name-based aliases on the HTTP path — use the CLI `--main` / `--me` for those.
- `data`: the message body. KakaoTalk's ~10,000-char limit applies.
- `threadId` (optional): accepted for Iris compatibility but currently ignored.

Response (always HTTP 200, except 5xx for genuine server faults):
```json
{"success": true, "message": "sent to 전성욱 (chatId=313526436723168)"}
```

Errors before the AX step (unknown chatId, invalid `room`, unsupported `type`) return `{"success": false, "message": "..."}` with HTTP 200, matching Iris semantics.

`GET /health` returns `{"status":"ok"}` for liveness checks.

### Running Unattended (LaunchAgent)

macOS isolates SSH sessions from the WindowServer / Accessibility APIs, so `kakaocli serve` started over SSH listens on the port but every `/reply` request fails with `"did not become ready within timeout"` when it tries to drive the UI. Launching the server inside the user's GUI session via `launchctl` fixes this. A plist template ships in the repo:

```bash
cp deploy/launchd/com.kakaocli.serve.plist.template \
   ~/Library/LaunchAgents/com.kakaocli.serve.plist
$EDITOR ~/Library/LaunchAgents/com.kakaocli.serve.plist     # fill __REPLACE_*__
plutil ~/Library/LaunchAgents/com.kakaocli.serve.plist      # validate
launchctl bootstrap gui/$(id -u) \
   ~/Library/LaunchAgents/com.kakaocli.serve.plist
launchctl list | grep kakaocli                              # PID + exit code
```

First call after install may surface Accessibility / Full Disk Access prompts — approve them via Chrome Remote Desktop or another GUI session. Persistent thereafter.

### Concurrency / Ordering

Requests are dispatched to a single serial work queue so KakaoTalk's UI is never driven by two requests at once. Burst senders should expect serialized processing (~2-3s per message including AX wait).

## Sync Mode (Real-Time Monitoring)

### NDJSON Stream
```bash
kakaocli sync --follow
```
Outputs one JSON object per line (NDJSON) for each new message:
```json
{"type":"message","log_id":123,"chat_id":456,"chat_name":"Mom","sender_id":789,"sender":"Mom","text":"Are you coming?","message_type":1,"timestamp":"2026-02-20T10:30:00Z","is_from_me":false}
```

### With Webhook
```bash
kakaocli sync --follow --webhook http://localhost:8080/kakao
```
POSTs batches of new messages as JSON arrays to the webhook URL.

### Options
- `--interval <seconds>` — Poll frequency (default: 2s)
- `--since-log-id <id>` — Start from a specific point instead of latest
- `--webhook <url>` — POST new messages to this URL

### One-Shot Status
```bash
kakaocli sync
```
Returns: `{"status":"ready","max_log_id":12345}` — useful for getting the current high-water mark.

## Agent Integration Pattern

Pick the transport that fits your agent:

### Option A: CLI subprocess (same host)

```python
import subprocess, json

# 1. Check for new messages
proc = subprocess.run(["kakaocli", "messages", "--since", "5m", "--json"],
                      capture_output=True, text=True)
messages = json.loads(proc.stdout)

# 2. Process and respond
for msg in messages:
    if not msg["is_from_me"] and needs_response(msg):
        subprocess.run(["kakaocli", "send", msg["chat_name"], response_text])
```

### Option B: HTTP (cross-host, Iris-compatible)

For an orchestrator on a different node (e.g. Spring Boot on Ubuntu, kakaocli serve on a Mac mini reachable over Tailscale):

```python
import requests

requests.post(
    "http://mac-mini.tailnet:8080/reply",
    json={"type": "text", "room": "313526436723168", "data": "hello"},
    timeout=60,
)
```

The same orchestrator code will keep working when the backend is later swapped to `irisbot` (Android) — only the URL changes.

### Option C: Sync mode for real-time

```bash
kakaocli sync --follow | while read -r line; do
  echo "$line" | jq -r '.text' | process_message
done
```

## Harvest (Bulk Chat History)

The `harvest` command automates bulk extraction of chat display names and message history loading.

### Names Only (Fast)
```bash
kakaocli harvest
```
Captures display names for all chats from the UI (many group chats show `(unknown)` in the DB). Saves to `~/.kakaocli/metadata.json`.

### Full History Loading
```bash
kakaocli harvest --scroll --max-clicks 5
```
Opens each chat, scrolls to top, and clicks "View Previous Chats" to load older messages from the server. Automatically handles Talk Drive Plus paywall popups.

### Options
- `--top <N>` — Process only top N most recent chats
- `--scroll` — Enable full scroll + click mode (without this, only captures names)
- `--max-clicks <N>` — Max "View Previous Chats" clicks per chat (default: 10)
- `--scroll-delay <seconds>` — Delay between actions (default: 1.5s)
- `--dry-run` — Preview without making changes

### Output
Returns JSON array with per-chat results:
```json
[{"chatId": 123, "name": "Chat Name", "messagesBefore": 48, "messagesAfter": 148, "newMessages": 100, "skipped": false}]
```

### Notes
- Chats with unread messages are automatically skipped (to avoid marking them as read)
- The Talk Drive Plus paywall blocks loading older messages — the tool detects and dismisses it
- Uses Vision OCR + CGEvent clicks for reliable UI interaction
- Metadata saved to `~/.kakaocli/metadata.json`

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Keychain error` | Run `kakaocli login --clear` then re-store credentials |
| `No login window found` | KakaoTalk window may be hidden — run `kakaocli login --status` to check |
| `Login did not succeed` | Verify credentials: `kakaocli login --email ... --password ...` |
| `Chat not found` | Use exact substring match — run `kakaocli chats` to see available names |
| `No open windows` | KakaoTalk may need manual interaction first time — open it once manually |
| Login works but send fails | Window may need time to load — retry after 2-3 seconds |

## Safety Rules

1. **Never send test messages to other people's chats.** Use `--me` flag for testing.
2. **Always use `--dry-run` first** when testing new send logic.
3. **Rate limit sends** — at least 2 seconds between messages.
4. **Respect hours** — avoid sending between 11 PM and 7 AM unless urgent.
5. **Confirm before sending** — agents should verify message content with the user before sending to others.
