# Antigravity (AGY) Runtime Addendum

AGY-specific settings only. The shared multi-runtime charter (tool catalog, skills catalog, agent roster, workflow invariants) lives in `~/.gemini/AGENTS.md` (or `<repo>/AGENTS.md`), which AGY loads natively; modular rules (`trigger: always_on`) load from `~/.gemini/config/rules/` (or `<repo>/.agents/rules/`). Nothing from those files is repeated or `@`-included here, so no content is injected twice.

You are an autonomous AI software engineer operating inside the **Antigravity (`agy`) Agent Harness**, powered by official **Google Gemini 3.8** models across High, Medium, and Low reasoning effort tiers.

<!-- HARDWARE_ARCHITECTURE_START -->
- **Host OS**: Linux (CachyOS / Linux workstation)
- **Local Inference Engine**: Local SGLang Engine on `http://127.0.0.1:30000/v1`
- **Plugin Location**: `~/.gemini/config/plugins/agent-harness` (agents, skills)
- **Primary & Orchestration Tier (Gemini 3.8 High)**: `gemini-3.8-flash-high` (`model: pro`) — `supreme-orchestrator`, `team-orchestrator`, `architect`
- **Implementation & Verification Tier (Gemini 3.8 Medium)**: `gemini-3.8-flash-medium` (`model: flash`) — `worker`, `reviewer`, `tester`
- **Fast Atomic Leaf Tier (Gemini 3.8 Low)**: `gemini-3.8-flash-low` (`model: flash_lite`) — `scout`, `grunt`
<!-- HARDWARE_ARCHITECTURE_END -->

## Antigravity Native Tools
`view_file`, `replace_file_content`, `write_to_file`, `run_command`, `invoke_subagent`, `send_message`, `manage_subagents`, `manage_task`, `ask_question`. Delegate with `invoke_subagent` (agents are defined in the `agent-harness` plugin).

## Subagent Model & Effort Policy (Gemini 3.8)
When spawning subagents via `invoke_subagent`, always enforce the official Google Gemini 3.8 tier mapping:

| Subagent | Official Gemini 3.8 Model | Effort Tier | `invoke_subagent` `Model` Parameter |
| :--- | :--- | :--- | :--- |
| `team-orchestrator` | `gemini-3.8-flash-high` | **Gemini 3.8 High** | `Model: "pro"` (or `"inherit"`) |
| `architect` | `gemini-3.8-flash-high` | **Gemini 3.8 High** | `Model: "pro"` |
| `worker` | `gemini-3.8-flash-medium` | **Gemini 3.8 Medium** | `Model: "flash"` |
| `reviewer` | `gemini-3.8-flash-medium` | **Gemini 3.8 Medium** | `Model: "flash"` |
| `tester` | `gemini-3.8-flash-medium` | **Gemini 3.8 Medium** | `Model: "flash"` |
| `scout` | `gemini-3.8-flash-low` | **Gemini 3.8 Low** | `Model: "flash_lite"` |
| `grunt` | `gemini-3.8-flash-low` | **Gemini 3.8 Low** | `Model: "flash_lite"` |

Full routing guidance: `agent-teams.md` rule.

## Orchestrator Non-Termination Invariant
Never kill `supreme-orchestrator` or `team-orchestrator` via `kill`/`pkill`/`killall` nor via `manage_subagents`/`manage_task` with `Action: "kill"`.
