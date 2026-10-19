---
name: read-only-block
description: PreToolUse guard and local security sandbox for read-only sensitive sessions. Use when working on sensitive codebases, proprietary assets, air-gapped workflows, or when tasked with read-only audits.
---

# Read-Only Block & Security Sandbox Skill

## Overview

The **Read-Only Block** enforces strict local execution boundaries for sensitive, air-gapped, or confidential coding tasks. When enabled, all mutating external network calls, remote agent invocations, and code-pushing operations are intercepted and denied at the PreToolUse level.

## Enforcement Layers

1. **PreToolUse Hook (`block_external_writes.py`)**:
   - Fails closed: only read verbs (`get|list|search|find|ping|compare`) are permitted for MCP tools.
   - Blocks remote agent spawns (`isolation: "remote"`).
   - Records every decision into `decisions.log` (`timestamp`, `session_id`, `tool`, `decision`).
2. **Permission Deny Policy**:
   - Denies outgoing mutating operations: `git push`, `curl`, `wget`, `ssh`, `scp`, `rsync`, `nc`, `socat`.
   - Denies issue/PR and repository mutating API tools across GitHub and external web APIs.
   - Denied tools are pruned from the session's available tool list.

## Usage & Activation

- **Claude Code**: Launch with `--settings ~/.claude/orchestration/read-only-block/settings.json`
- **Antigravity (`agy`) / OpenCode (`opencode`)**: Run commands with `block_external_writes.py` policy enforcement or configure `rules/process-safety.md`.
