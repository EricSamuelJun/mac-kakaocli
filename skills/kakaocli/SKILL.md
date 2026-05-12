---
name: kakaocli
description: Send and receive KakaoTalk messages via CLI or an Iris-compatible HTTP server. Resolves operator-curated aliases ("49기방", "유희왕 방", ...) to chatIds via `kakaocli policy list --json`, so agents never need to handle raw chat names.
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
  - alias-resolution
---

# KakaoTalk CLI Skill

Send and receive KakaoTalk messages on macOS. Address chats by **chatId only**; human labels live in `~/.kakaocli/policy.json` and resolve to chatIds via one command.

## TL;DR (agent quick reference)

If the operator names a chat by a human label ("49기방", "최세일", "유희왕 방"), here is the entire flow:

```bash
# 1. Get the alias map (single source of truth — no other lookup needed)
kakaocli policy list --json
#   → { entries: [ { chat_id, alias, expected_name, ... } ] }

# 2. Match the operator's label against entries[].alias
#    Found?      → use chat_id for every downstream call
#    Not found?  → STOP. Ask the operator to register it (see "Alias miss" below)

# 3. Send / read / inspect with the resolved chatId
kakaocli send <chat_id> "message"
kakaocli messages --chat-id <chat_id> --since 1h --json
```

**DO**:
- Resolve labels via `policy list --json` and the `alias` field.
- Use chatId (integer) for every downstream command and HTTP `room`.
- Trust the policy file. It is the single source of truth.

**DON'T**:
- Don't call `kakaocli chats --json` to "double-check" an alias hit. The policy is authoritative. `chats` triggers a DB warm-up and can take 18-180s in some spawn environments; it adds no information that `policy list` doesn't already have.
- Don't mint aliases by parsing user prompts. Aliases are operator-curated. On a miss, ask the operator to add it — never auto-add.
- Don't re-call `skill_view(kakaocli)` mid-session if you've already loaded it. The body doesn't change between turns.
- Don't substring-match raw names through `send --name` for new chats. That path is the legacy escape hatch — no verifier, no protection.

**Alias miss flow** (the only time `chats` is acceptable):
1. Tell the operator the label isn't on the allowlist.
2. *Optional helper*: `kakaocli chats --json --limit 50` once, surface 1-3 candidates whose `display_name` contains the label.
3. Ask the operator to run `kakaocli policy add --chat-id <id> --alias "<label>" --purpose "<note>"`.
4. After they confirm, re-read the policy (`policy list --json`) and proceed.

## Resolving Natural-Language Labels (Hermes / LLM agents)

Operator prompts arrive with human labels, not chatIds:

> "49기방에 매일 1시간마다 뉴스 정리해서 보내줘"
> "유희왕 방에 정오 12시 3분마다 'TCG 마이너갤러리' 신규 정보 글 올려줘"
> "지금 일본선교팀방에 무슨 공지가 떴는지 확인해줘"
> "최세일한테 안녕이라고 보내줘"

Canonical Python flow:

```python
import json, subprocess

# 1. Build alias → chatId map (read-only, fast: <100ms typical)
policy = json.loads(subprocess.run(
    ["kakaocli", "policy", "list", "--json"],
    capture_output=True, text=True, check=True,
).stdout)
alias_to_chat = {e["alias"]: e["chat_id"] for e in policy["entries"] if e.get("alias")}

# 2. Resolve the label
label = "49기방"
chat_id = alias_to_chat.get(label)
if chat_id is None:
    # Don't mint. Don't substring-match. Stop and ask the operator.
    raise RuntimeError(f"No policy entry has alias '{label}'.")

# 3. Use the resolved chat_id everywhere
subprocess.run(["kakaocli", "send", str(chat_id), "Today's news …"], check=True)
# or read-back:
# subprocess.run(["kakaocli", "messages", "--chat-id", str(chat_id), "--since", "1h", "--json"], ...)
```

## Send (chatId-first)

```bash
kakaocli send 313526436723168 "message"        # canonical — verifier on
kakaocli send --main "message"                  # → policy.primaryChatId — verifier on
kakaocli send --me "test"                       # self-chat (badge AX) — verifier exempt
kakaocli send --name "전성욱" "message"          # LEGACY substring — no verifier, no protection
kakaocli send 313526436723168 "msg" --unsafe-no-verify    # explicit policy bypass
kakaocli send <chatId> "msg" --dry-run          # preview without sending
```

`--main` resolves to `policy.primaryChatId` (set by `kakaocli init` or `kakaocli policy manage <id> --make-primary`). The legacy `KAKAOCLI_MAIN_CHAT_NAME` env var fallback was removed in v0.9.0.

## Read / Search / Inspect / Harvest (chatId-first)

```bash
kakaocli messages --chat-id 313526436723168 --since 1h --json
kakaocli messages --chat-id 313526436723168 --limit 100 --json
kakaocli search "keyword" --json
kakaocli inspect --open-chat-id 313526436723168 --depth 4
kakaocli harvest --chat-id 468542230323777 --scroll --max-clicks 3
kakaocli harvest --chat-ids 313526436723168,468542230323777
```

`messages` / `search` / `inspect` / `harvest` all take chatId. The `--chat` / `--open-chat` / `--name` variants exist for legacy compatibility only.

## HTTP Backend (Iris-compatible)

```bash
# Start (foreground / dev)
kakaocli serve --log -
# Or as a LaunchAgent (recommended for production — see README)

# Send — `room` is the numeric chatId as a string. Verifier always on, no per-request bypass.
curl -s -X POST http://127.0.0.1:8080/reply \
  -H "Content-Type: application/json" \
  -d '{"type":"text","room":"<chatId>","data":"hello"}'

# Read endpoints (not policy-gated; useful for an orchestrator that only knows the chatId from operator config)
curl -s 'http://127.0.0.1:8080/chats?limit=20' | jq
curl -s http://127.0.0.1:8080/chat/<chatId> | jq   # adds direct_member_user_id on 1:1 chats

# Liveness
curl -s http://127.0.0.1:8080/health
```

## Manage the Allowlist

```bash
# Operator-curated. Aliases must be unique across the allowlist.
kakaocli policy add --chat-id <chatId> --alias "<label>" --purpose "<note>"

kakaocli policy manage <chatId> --set-alias "<label>"
kakaocli policy manage <chatId> --set-purpose "<note>"
kakaocli policy manage <chatId> --pin-user-id
kakaocli policy manage <chatId> --unpin-user-id
kakaocli policy manage <chatId> --make-primary --yes
kakaocli policy manage <chatId> --remove --yes

# Both --make-primary and --remove ask for [y/N] interactively unless --yes is passed.
```

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `kakaocli chats --json` takes 60s+ before completing or times out | `KAKAOCLI_USER_ID` env var missing in this shell AND `~/.kakaocli/config.json` unreadable here → fell back to SHA-512 brute-force | Run `kakaocli auth` and check the User ID label: `(env)` / `(config)` = fast; `(plist)` = brute-force. Fix by exporting `KAKAOCLI_USER_ID` in this spawn environment, or by running `kakaocli init` so `config.json` is populated. |
| `Send denied by policy: ... not in the allowlist` | chatId isn't on `~/.kakaocli/policy.json` | Ask operator to `kakaocli policy add --chat-id <id> --alias "<label>" --purpose "<note>"` |
| `Send denied by policy: expectedName mismatch` | The DB displayName drifted from `policy.expectedName` (chat renamed or different chat) | Verify with `kakaocli policy list --json`; update via `kakaocli policy manage <id> --set-name "<new>"` |
| `UI automation failed: KakaoTalk launched but did not become ready within timeout` | (a) Mac asleep or display locked; (b) LaunchAgent in wrong session (needs `LimitLoadToSessionType=Aqua` in plist); (c) KakaoTalk not in GUI session | Wake the Mac / re-bootstrap the LaunchAgent. See README "Serve" → "Running as a LaunchAgent". |
| `alias "X" is already used by another entry` | Two policy entries would share an alias — reverse mapping ambiguous | Choose a different label, or `policy manage <id> --set-alias ""` on the existing entry first |
| HTTP `/reply` returns `{success:false}` with a clear message | Client error (invalid room, unknown chatId, policy denied) | Read `message`. Errors before AX are HTTP 200; genuine server faults are HTTP 5xx. |

## Setup (first-time)

```bash
kakaocli init                                              # permissions + userId + scaffold config/policy
kakaocli login --email user@example.com --password ...     # store KakaoTalk creds in Keychain
```

For unattended HTTP use, install the LaunchAgent template at `deploy/launchd/com.kakaocli.serve.plist.template` (see README "Serve / HTTP 서버"). **`LimitLoadToSessionType=Aqua` is required** in the plist — without it the agent can't see the running KakaoTalk and every `/reply` will time out.

## Operating Principles

- **Aliases are operator-curated, not LLM-derived.** Never auto-create an alias from a parsed label.
- **One alias, one chatId.** Uniqueness is enforced at every write path (`policy add`, `policy manage --set-alias`).
- **chatId is the canonical key** — for `send`, `messages`, `inspect`, `harvest`, `inspect --open-chat-id`, and HTTP `room`. Aliases exist only to spare operators / agents from typing 18-digit numbers.
- **HTTP `POST /reply` shares the verifier with CLI chatId sends.** There is no per-request bypass on HTTP — misconfiguration is strictly a `policy.json` edit.
- **`--name` and `--me` skip the verifier by design.** `--name` is the legacy substring path; treat it as a manual escape hatch, not as a default.
- **Rate limit: ≥2 seconds between sends.** Don't send between 11 PM and 7 AM unless urgent.
- **Confirm with the operator before sending to others.** Use `--dry-run` to preview the resolved target without sending.
