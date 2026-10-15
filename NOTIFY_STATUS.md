# notify_status.py — Integration Guide

Post real-time status notifications and updates to Slack from any tool —
shell scripts, Python, Ansible, or anything that can run a subprocess.

---

## 1. Prerequisites

### Python packages
```bash
pip install slack-sdk python-dotenv
```

### Directory layout
```
aap/                        ← parent directory
├── .env                    ← credentials live here
└── slack-aap/
    └── notify_status.py    ← this script
```

The script automatically reads `.env` from the **parent `aap/` directory**.
You do not need to set env vars manually before calling it.

---

## 2. Environment Setup

Edit `aap/.env` and add/confirm these three lines:

```env
SLACK_BOT_TOKEN=xoxb-...          # Bot token — provided by team lead
SLACK_NOTIFY_CHANNEL=C0C6JSQM0RG  # Channel ID — provided by team lead
```

> `SLACK_APP_TOKEN` (xapp-...) is **not needed** for `notify_status.py`.
> It is only used by the interactive Slack bot.

---

## 3. Status Values & Emojis

| Status      | Emoji | When to use                              |
|-------------|-------|------------------------------------------|
| `running`   | ⏳    | Tool has started / a step is in progress |
| `completed` | ✅    | Tool finished successfully               |
| `failed`    | ❌    | Tool encountered an error                |
| `paused`    | ⏸️   | Waiting for input / approval             |

---

## 4. Command Reference

```
python notify_status.py <status> <title> [description] [--thread TS] [--broadcast]
```

| Argument / Option | Required | Description |
|---|---|---|
| `status` | ✅ | One of: `running` `completed` `failed` `paused` |
| `title` | ✅ | Short one-liner (quote if it contains spaces) |
| `description` | ✗ | Optional detail text. Supports multiple lines. |
| `--thread TS` | ✗ | Post inside an existing thread (TS from a prior call) |
| `--broadcast` | ✗ | Also show threaded reply in the channel (use for final status) |

**Exit codes:** `0` = success, `1` = error (bad args / Slack API error / missing config)

**stdout vs stderr:**
- `stdout` — only the thread `ts` when creating a new parent message (capture with `$()`)
- `stderr` — human-readable confirmations and errors (visible in terminal, not captured by `$()`)

---

## 5. Threading Model

Every message in Slack has a unique timestamp (`ts`).
To group messages into a thread, the first call creates the **parent** and
returns its `ts`. All follow-up calls pass `--thread <ts>` to reply inside it.

```
#aap-status channel
┌──────────────────────────────────────┐
│ ⏳  Deploying inventory_05           │  ← parent (visible in channel)
│   💬 3 replies  View thread ›        │
└──────────────────────────────────────┘

  Inside thread:
  ├─ ⏳  Step 1/3 — inventory created
  │      Host count: 21
  ├─ ⏳  Step 2/3 — migration running
  └─ ✅  All done                       ← also shown in channel (--broadcast)
         21 hosts moved, 0 errors.
```

---

## 6. Usage Examples

### 6.1 Single message (no thread)
```bash
python notify_status.py completed "Backup finished"
python notify_status.py failed    "Backup failed" "Disk quota exceeded on node01"
```

### 6.2 Multiline description
```bash
# Bash $'...' syntax for literal newlines
python notify_status.py failed "Deploy failed" $'Step 2 timed out.\nCheck job #1042 for details.'
```

### 6.3 Threaded workflow — shell script
```bash
#!/bin/bash
set -euo pipefail

# 1. Open thread — capture ts silently (stderr goes to terminal, stdout is ts only)
TS=$(python notify_status.py running "Deploying inventory_05")

# 2. Step updates — post inside the thread
python notify_status.py running "Step 1/3 — inventory created" "Host count: 21" --thread $TS
python notify_status.py running "Step 2/3 — migration running"                  --thread $TS

# 3. Final status — post in thread AND resurface in channel
python notify_status.py completed "All done" "21 hosts moved, 0 errors." --thread $TS --broadcast

# On error — replace step 3 with:
# python notify_status.py failed "Deploy failed" "Step 2 timed out." --thread $TS --broadcast
```

### 6.4 Threaded workflow — Python
```python
import subprocess, sys

def notify(status, title, description=None, thread_ts=None, broadcast=False):
    """Call notify_status.py and return ts (only set when thread_ts is None)."""
    cmd = ["python", "notify_status.py", status, title]
    if description:
        cmd.append(description)
    if thread_ts:
        cmd += ["--thread", thread_ts]
    if broadcast:
        cmd.append("--broadcast")

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise RuntimeError(f"notify_status.py failed: {result.stderr.strip()}")

    # stderr goes to terminal so operator can see it
    print(result.stderr, end="", file=sys.stderr)

    # stdout = ts only when creating a new parent (no --thread)
    return result.stdout.strip() or None


# Open thread
ts = notify("running", "Deploying inventory_05")

# Steps
notify("running",   "Step 1/3 — inventory created", "Host count: 21", thread_ts=ts)
notify("running",   "Step 2/3 — migration running",                   thread_ts=ts)

# Final
notify("completed", "All done", "21 hosts moved, 0 errors.",          thread_ts=ts, broadcast=True)
```

### 6.5 Passing thread ts between separate tools
When multiple tools share the same thread, pass `TS` via environment variable
so every tool automatically knows where to post:

```bash
#!/bin/bash
# orchestrator.sh

TS=$(python notify_status.py running "Workflow started")
export SLACK_THREAD_TS=$TS          # tools inherit this

python tool_inventory.py            # reads $SLACK_THREAD_TS internally
python tool_migration.py            # reads $SLACK_THREAD_TS internally
python tool_verify.py               # reads $SLACK_THREAD_TS internally
```

Inside each tool (Python example):
```python
import os, subprocess

TS = os.environ.get("SLACK_THREAD_TS", "")

def notify(status, title, desc=None):
    cmd = ["python", "/path/to/notify_status.py", status, title]
    if desc:
        cmd.append(desc)
    if TS:
        cmd += ["--thread", TS]
    subprocess.run(cmd)

notify("running",   "Migrating group web02...")
# ... do work ...
notify("completed", "Migration done", "4 hosts moved")
```

---

## 7. Quick Reference Card

```bash
# New thread (returns ts on stdout)
TS=$(python notify_status.py running   "Job started")
TS=$(python notify_status.py paused    "Waiting for approval")

# Reply in thread
python notify_status.py running   "Step N — doing X"              --thread $TS
python notify_status.py running   "Step N — doing X" "Detail..."  --thread $TS

# Final — resurface in channel
python notify_status.py completed "Done"           "Summary..."   --thread $TS --broadcast
python notify_status.py failed    "Job failed"     "Reason..."    --thread $TS --broadcast

# Single message (no thread)
python notify_status.py completed "Quick task done"
python notify_status.py failed    "Quick task failed" "Error msg"
```

---

## 8. Troubleshooting

| Error message | Cause | Fix |
|---|---|---|
| `SLACK_BOT_TOKEN is not set` | Missing in `.env` | Add token to `aap/.env` |
| `SLACK_NOTIFY_CHANNEL is not set` | Missing in `.env` | Add channel ID to `aap/.env` |
| `Slack API error: channel_not_found` | Wrong channel ID | Verify `SLACK_NOTIFY_CHANNEL` value |
| `Slack API error: not_in_channel` | Bot not in channel | Invite bot: `/invite @<botname>` in Slack |
| `Slack API error: invalid_auth` | Bad token | Check `SLACK_BOT_TOKEN` in `.env` |
| Exit code `1`, no Slack error | Bad args / unknown status | Check spelling of status value |
