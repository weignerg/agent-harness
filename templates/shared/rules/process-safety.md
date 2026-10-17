# Rule: Process, Credential & Execution Safety

- **Orchestrator Non-Termination Invariant**: Never kill, stop, or terminate `supreme-orchestrator` or `team-orchestrator` — neither via OS commands (`kill`, `pkill`, `killall`, `systemctl stop`) nor via subagent/task management tools (`manage_subagents` with `Action: "kill"` or `manage_task` with `Action: "kill"`).
- **Process Protection**: Never kill or restart parent orchestrator sessions, background terminals, or active inference services (`opencode-sglang-ornith-35b.service` / `ornith-30000.service`).
- **History Protection**: Subagents and leaf agents must NEVER read, write, or modify `~/HISTORY.md` (strictly reserved for the primary orchestrator).
- **Credential Protection**: Never print, leak, or commit `HF_TOKEN`, API keys, or credentials. Read environment files only from `%h/.config/opencode-backends/env` or secure keyrings.
- **Portability**: Never hardcode host-specific mount paths (network mounts, absolute user home directories). Resolve paths via `$HOME` or XDG variables.
- **Read-Only Sandbox Guard**: When executing sensitive, air-gapped, or audit tasks, sessions must run with read-only sandbox enforcement (`block_external_writes.py` / read-only block settings). Mutating external operations (`git push`, `curl`, `wget`, `ssh`, mutating MCP API calls) are blocked fail-closed at the PreToolUse level.
- **Human Authorization for Outward Writes**: Any outward-facing modification (pushing commits to remote origin, closing/transitioning tracking tickets, creating public PR comments) requires explicit human go-ahead. Local authoring and testing within isolated worktrees do not require pre-approval.
