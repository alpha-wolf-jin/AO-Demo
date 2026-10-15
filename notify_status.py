#!/usr/bin/env python3
"""
notify_status.py — Post a status notification to a Slack channel, with optional threading.

Usage:
    # Open a new thread — prints thread ts to stdout
    TS=$(python notify_status.py <status> <title> [description])

    # Post a follow-up inside that thread
    python notify_status.py <status> <title> [description] --thread <ts>

    # Post final status in thread AND resurface it in the channel
    python notify_status.py <status> <title> [description] --thread <ts> --broadcast

Arguments:
    status       One of: running, completed, failed, paused
    title        Short one-liner summary
    description  Optional multiline detail (use $'line1\\nline2' in bash)

Options:
    --thread TS   Post as a reply inside an existing thread (TS from a prior call)
    --broadcast   Also show the threaded reply in the channel (useful for final status)

Environment (read from ../aap/.env):
    SLACK_BOT_TOKEN      xoxb-... bot token
    SLACK_NOTIFY_CHANNEL Channel ID to post to (e.g. C0123ABCDEF)

Exit codes:
    0  Message posted successfully
    1  Bad arguments / unknown status / Slack API error / missing config

Examples:
    # Start a new thread — save the ts
    TS=$(python notify_status.py running "Deploying inventory_05")

    # Post steps inside the thread
    python notify_status.py running   "Step 1/3 — inventory created" "Host count: 21" --thread $TS
    python notify_status.py running   "Step 2/3 — migration running"                  --thread $TS

    # Final status: post in thread AND resurface in channel
    python notify_status.py completed "All done" "21 hosts moved, 0 errors."           --thread $TS --broadcast
    python notify_status.py failed    "Deploy failed" $'Step 2 timed out.\\nJob #1042' --thread $TS --broadcast
"""

import os
import sys

# ── Path bootstrap (mirrors aap-slack-DeepSeek.py) ───────────────────────
_THIS_DIR   = os.path.dirname(os.path.abspath(__file__))  # slack-aap/
_PARENT_DIR = os.path.dirname(_THIS_DIR)                   # aap/

from dotenv import load_dotenv
load_dotenv(os.path.join(_PARENT_DIR, ".env"))

from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

# ── Status → emoji ────────────────────────────────────────────────────────
_STATUS_EMOJI: dict[str, str] = {
    "running":   "⏳",
    "completed": "✅",
    "failed":    "❌",
    "paused":    "⏸️",
}


def _build_blocks(emoji: str, title: str, description: str | None) -> list:
    """Build a Slack Block Kit payload.

    Layout:
      [header]  ⏳ Title text          ← large bold, plain text only
      [section] Description line 1     ← mrkdwn, only present if description given
                Description line 2
    """
    blocks: list = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"{emoji} {title}",
                "emoji": True,
            },
        }
    ]
    if description:
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": description,
                },
            }
        )
    return blocks


def _parse_args() -> tuple[str, str, str | None, str | None, bool]:
    """Parse sys.argv manually to keep zero extra dependencies.

    Returns (status, title, description, thread_ts, broadcast).
    Raises SystemExit(1) on bad input.
    """
    args = sys.argv[1:]

    # Extract flags first so positional parsing stays simple
    broadcast = "--broadcast" in args
    if broadcast:
        args = [a for a in args if a != "--broadcast"]

    thread_ts: str | None = None
    if "--thread" in args:
        idx = args.index("--thread")
        if idx + 1 >= len(args):
            print("Error: --thread requires a timestamp argument", file=sys.stderr)
            sys.exit(1)
        thread_ts = args[idx + 1]
        args = args[:idx] + args[idx + 2:]

    if len(args) < 2:
        print(
            "Usage: notify_status.py <status> <title> [description] [--thread TS] [--broadcast]\n"
            f"  status: {' | '.join(_STATUS_EMOJI)}",
            file=sys.stderr,
        )
        sys.exit(1)

    status      = args[0].lower().strip()
    title       = args[1]
    description = args[2] if len(args) >= 3 else None

    return status, title, description, thread_ts, broadcast


def main() -> int:
    status, title, description, thread_ts, broadcast = _parse_args()

    # ── Validate status ───────────────────────────────────────────────────
    emoji = _STATUS_EMOJI.get(status)
    if emoji is None:
        print(
            f"Error: unknown status '{status}'.\n"
            f"Must be one of: {', '.join(_STATUS_EMOJI)}",
            file=sys.stderr,
        )
        return 1

    # ── Config from environment ───────────────────────────────────────────
    token   = os.environ.get("SLACK_BOT_TOKEN", "")
    channel = os.environ.get("SLACK_NOTIFY_CHANNEL", "")

    if not token:
        print("Error: SLACK_BOT_TOKEN is not set in .env", file=sys.stderr)
        return 1
    if not channel:
        print("Error: SLACK_NOTIFY_CHANNEL is not set in .env", file=sys.stderr)
        return 1

    # ── Build payload ─────────────────────────────────────────────────────
    blocks   = _build_blocks(emoji, title, description)
    fallback = f"{emoji} {title}"       # shown in push notifications / unfurls
    if description:
        fallback += f"\n{description}"

    # ── Post to Slack ─────────────────────────────────────────────────────
    client = WebClient(token=token)
    try:
        kwargs: dict = dict(
            channel=channel,
            text=fallback,
            blocks=blocks,
        )
        if thread_ts:
            kwargs["thread_ts"]       = thread_ts
            kwargs["reply_broadcast"] = broadcast

        resp = client.chat_postMessage(**kwargs)

    except SlackApiError as exc:
        print(f"Slack API error: {exc.response['error']}", file=sys.stderr)
        return 1

    ts = resp["ts"]

    # When creating a new parent thread: print ts to stdout so the caller
    # can capture it with TS=$(python notify_status.py ...).
    # Follow-up replies print a confirmation to stderr only.
    if thread_ts is None:
        print(ts)                       # stdout — captured by $()
        print(
            f"[notify_status] New thread ts={ts} [{status}] {title}",
            file=sys.stderr,
        )
    else:
        bcast_note = " (broadcast to channel)" if broadcast else ""
        print(
            f"[notify_status] Reply posted{bcast_note} [{status}] {title}",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
