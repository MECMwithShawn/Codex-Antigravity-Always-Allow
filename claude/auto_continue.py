#!/usr/bin/env python3
"""Claude Code Stop hook: continue automatically unless a human gate or a wait applies.

Install with install_claude_auto_continue.ps1 (-Scope User or -Scope Project), which copies
this file and merges the Stop hook into the settings without a BOM.

Stops (lets the turn end) when the last assistant message mentions a human gate (approval,
spending, credentials, deletion, broker or order capability, ledger writes, a decision that
is the user's), says it is waiting on a background task, or after 8 continuations in a row.
Follow-through of work the user already asked for, such as pushing a requested change or
asking "want me to...?", is not a gate: the hook continues.
"""
import json
import re
import sys
from pathlib import Path

GATES = re.compile(
    r"approv|freez|spend|purchas|\$\d|credential|api key|password|token|delete|destructive|"
    r"broker|order submission|ledger|your (call|decision)", re.I)
WAITING = re.compile(r"waiting (on|for)|running in the background|will report|still running", re.I)
MAX_CHAIN = 8
STATE = Path(__file__).with_name(".auto_continue_count")


def last_assistant_text(transcript: str) -> str:
    text = ""
    try:
        for line in Path(transcript).read_text(encoding="utf-8").splitlines():
            e = json.loads(line)
            if e.get("type") == "assistant":
                parts = e.get("message", {}).get("content", [])
                t = "".join(p.get("text", "") for p in parts if p.get("type") == "text")
                if t.strip():
                    text = t
    except (OSError, ValueError):
        pass
    return text


def main() -> int:
    data = json.load(sys.stdin)
    count = int(STATE.read_text()) if STATE.exists() else 0
    text = last_assistant_text(data.get("transcript_path", ""))
    if count >= MAX_CHAIN or not text or GATES.search(text) or WAITING.search(text):
        STATE.write_text("0")
        return 0
    STATE.write_text(str(count + 1))
    print(json.dumps({"decision": "block",
                      "reason": "Continue with the next step. Stop only for a human gate."}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
