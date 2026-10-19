#!/usr/bin/env python3
"""PreToolUse guard for read-only sessions: MCP is read-only and nothing leaves this computer.

Loaded only through `claude --settings ~/.claude/orchestration/read-only-block/settings.json`, so
other sessions in the repo are unaffected. Fails closed: an MCP tool runs only when its operation name
starts with a read verb, so a write tool missing from the settings deny list is still blocked.
Each decision is appended to decisions.log (time, session, tool, decision; never tool input).
"""
import json
import os
import re
import sys
import time

READ_VERB = re.compile(r"(get|list|search|find|ping|compare)(?=[A-Z_]|$)")
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "decisions.log")


def log(session, tool, decision):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')}\t{session}\t{tool}\t{decision}\n")
    except OSError:
        pass


def deny(session, tool, reason):
    log(session, tool, "deny")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason + " Don't retry or work around this; tell the user.",
    }}))
    sys.exit(0)


def is_read_only_mcp(tool):
    parts = tool.split("__", 2)
    if len(parts) != 3:
        return False
    server, op = parts[1], parts[2]
    prefix = server.replace("-", "_") + "_"
    if op.startswith(prefix):
        op = op[len(prefix):]
    return bool(READ_VERB.match(op))


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        deny("?", "?", "The read-only guard couldn't parse this tool call, so it's blocked.")
    tool = event.get("tool_name", "")
    session = event.get("session_id", "?")
    tool_input = event.get("tool_input") or {}

    if tool.startswith("mcp__"):
        if is_read_only_mcp(tool):
            log(session, tool, "allow")
            return
        deny(session, tool, f"{tool} is blocked: read-only sessions may only read from MCP tools.")

    if tool == "Agent" and tool_input.get("isolation") == "remote":
        deny(session, tool, "Remote agents are blocked: read-only work stays on this computer.")


if __name__ == "__main__":
    main()
