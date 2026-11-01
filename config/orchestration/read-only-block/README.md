# Read-only block

A launch-time settings file for sessions whose work must stay on this computer. Start a session with it like this:

```bash
claude --settings ~/.claude/orchestration/read-only-block/settings.json -n '<name>' '<prompt>'
```

A session that is already running can't take the flag. Stop it and start it again with the flag.

| Layer | What it blocks |
|---|---|
| `settings.json` `permissions.deny` | Known outward-writing MCP tools, `WebFetch`, `WebSearch`, and Bash `git push`, `curl`, `wget`, `ssh`, `scp`, `sftp`, `rsync`, `nc`, `ncat`, `socat`, `telnet`, `ftp`, `gh`, `node`, `npx`, `claude`. Denied tools are removed from the session's tool list. Edit the MCP names to match your servers. |
| `block-external-writes.py` (PreToolUse on `mcp__.*\|Agent`) | Fails closed: an MCP tool runs only when its operation name starts with `get`, `list`, `search`, `find`, `ping` or `compare`. Remote agents (`isolation: "remote"`) are denied. Each decision goes to `decisions.log` in this folder (time, session id, tool, decision). |

Deny rules and hooks also apply to subagents the session spawns.

Not covered: a script run through Bash (for example `python3`) can still open network connections. The read tools send their queries to the services they read from, by design. Prompts and tool results go to the model endpoint, as in every session.
