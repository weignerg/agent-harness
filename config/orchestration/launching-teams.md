# Launching teams: playbook for the Supreme Orchestrator (OpenCode / Ornith 35B)

Read this before planning or launching any team. `supreme-orchestrator.md` owns the role; this file owns the mechanics.

## 1. Plan the set of teams

1. **Collect the requests.** They come from the human user or relayed from peer tasks.
   - A relayed request is a teammate's request. Draft the kickoffs for it, but don't launch it without human confirmation.
   - A relayed fact can be stale. Verify it before you write it into a kickoff.
2. **Check against what already exists**, using active session lists, the handoffs, and the open PRs (`gh pr list`, then `git log origin/release` for merges).
   - Drop any team whose PR has already merged.
   - Narrow any scope that another team owns.
   - Honor standing user decisions that handoffs record as "don't raise again". Tell the team to ask the user before reopening one.
3. **Show the user one numbered table:** team, work, waits on, and whether it runs under the read-only block. The user reorganizes it, by merging, splitting, renaming or dropping teams. Rewrite the kickoffs to match, and move replaced ones to `kickoffs/superseded/`.
4. **Shaping rules:**
   - **Hierarchical Epic & Issue Architecture**:
     - Work is structured hierarchically: **Epic Issues** define high-level feature sets or architectural initiatives.
     - Epics contain child **Issues** that complete specific objectives for the Epic (`Parent: #<epic_number>`).
     - Any child issue may additionally have **Nested Sub-issues** for granular implementation slices.
   - **Branch & PR Hierarchy**:
     - A branch and PR is created for **every issue**: `<type>/issue-<number>-<description>` (e.g. `feat/issue-10-core`, `fix/issue-12-subtask`).
     - Top-level Epic branches branch from `develop`; child and nested issue branches branch directly from **their parent issue's branch** (`base: <parent_branch>`), NOT `develop`.
     - Nested issue PRs target their **parent issue's branch** (`--base <parent_branch>`), NOT `develop`.
   - **Sequential Execution Order (One at a Time)**:
     - Nested issues must be worked on **one at a time** in strict sequential order. Never run concurrent overlapping edits across sibling nested branches.
     - Each nested issue PR is reviewed and merged into the parent issue's branch before the next nested issue begins.
     - Once all child/nested issues are merged into the parent branch, the parent issue opens or finalizes its PR targeting *its* parent (or `develop` for a top-level Epic).
   - Each deliverable gets one team. A team creates its issue first, then renames itself to the new issue number.
   - Don't launch a team that only waits on another team's output. Fold that work into the owning team, or let a later issue handle it.
   - Prefer keeping an existing PR. Retitle it to the new issue and update its description. GitHub can't change an open PR's source branch (`gh pr edit` has no parameter for it), so the branch name stays. Rewording old commits needs a force push, so ask first. Open a new PR only when keeping the old one is impossible.
   - Start teams fresh with a kickoff that carries the current state. Don't resume old sessions without their handoff.
5. **Cross-team overlaps.** When two teams edit the same files (for example `rules/process-safety.md`), name the overlap in both kickoffs. Each team checks with the Supreme Orchestrator before editing a shared file.
6. **Shared deliverables have one writer.** Other teams write their own files to an agreed folder (e.g. under `~/.config/opencode/orchestration/handoffs/`) and message the owning team when a file is ready.


## 2. Write each kickoff

- **Location:** `~/.config/opencode/orchestration/kickoffs/<Branch_Name with / replaced by _>.md`. It's the active set, kept outside the repo so it doesn't depend on any checkout. Its `README.md` holds the start table (§5). Retired kickoffs move to `kickoffs/superseded/`.
- **Header:** the "Kickoff template" in `team-orchestrator.md`. Fields for work that isn't code:
  - `Issue_Number: TBD (step a creates it; Issue-0 until then)`, or `0`.
  - `Mode: operations | research | documentation …`, each followed by "No code, worktree, branch, commit, or PR."
  - `Push_Policy: no pushes. This task changes no repo files.`
- **Task_Details**, in this order:
  - **What it is**, with full links: PR URL, branch, head sha, state.
  - **Background:** quote the human user's exact words.
  - **Read first:** the handoffs, with dates.
  - **Working with the user:** "the user is in this terminal. Raise each open decision when you reach it, and keep working on everything that doesn't depend on it."
  - **Work:** lettered steps (a, b, c). Every outward-facing write is drafted first and done on the user's OK.
  - **Constraints:** the overlaps; "if a spawn or edit is denied, stop and ask the user, don't work around it; if the classifier blocks an action the user already authorized, follow the classifier-block rule in systems-integration.md"; the isolated worktree at `.opencode/worktrees/<branch>`.
  - **Acceptance and Done report:** what replaces the PR line for work that isn't a PR.
- **Gitignored inputs** such as `docs/.generated/plans/` aren't in a worktree. Give them as absolute paths into the main checkout.

## 3. Read-only block for sensitive work

Use it for teams whose work must stay on this computer. If you installed it with the read-only block, its files are in `~/.config/opencode/orchestration/read-only-block/`; its README lists the layers and their limits.
- Write "Hard block: …" into the kickoff's constraints, so the team stops cleanly when a tool is denied.
- Verify after launch: `~/.config/opencode/orchestration/read-only-block/decisions.log` shows the session id on its first tool call.

## 4. Launch

### 4.1 OpenCode / SGLang Launch

The first prompt must start with `Role: Team Orchestrator.`, because that routes the session to its role. It then points at the kickoff by absolute path. Keep `'` and `$` out of names and prompts so the quoting stays safe.

| Method | Command | Notes |
|---|---|---|
| Tab in the user's konsole window (preferred when you launch) | `konsole --new-tab -e bash -lic "cd <repo> && opencode run --name '<name>' '<first prompt>'; exec bash" >/dev/null 2>&1 </dev/null &` | The user's running konsole starts the tab's shell with its own environment. `exec bash` keeps the tab open. |
| The user opens a terminal | `cd <repo> && opencode run --name '<name>' '<first prompt>'` | Works from any terminal the user opened. |
| Subagent delegation via task tool | `task(agent: "team-orchestrator", prompt: "<first prompt>")` | Runs directly within the OpenCode session using local SGLang Ornith-35B on port 30000. |
| Claude Code background session (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | `claude --bg -n "<type>/issue-<n>-<desc>" --agent team-orchestrator --add-dir "<worktree_path>" -p "<kickoff_prompt>"` | Runs in an isolated background session named after the issue branch. Gives `team-orchestrator` a fresh top-level subagent nesting budget to coordinate `architect`, `worker`, `tester`, `reviewer`, `scout`, and `grunt`. |
| Headless remote server | Connect via `http://127.0.0.1:4096` or OpenCode Mobile | For remote sessions and mobile monitoring. |

### 4.2 Google Antigravity (`agy`) Multi-Tier Launch & Subagent Hierarchy

In Google Antigravity (`agy`), multi-tier orchestration operates natively via in-session asynchronous subagents and background daemon management:

1. **Supreme Orchestrator to Team Orchestrator Delegation**:
   - `supreme-orchestrator` (Gemini 3.8 High, `Model: "pro"`) triages requirements and delegates each approved GitHub issue to a dedicated `team-orchestrator` using `invoke_subagent`:
     ```python
     invoke_subagent(
         TypeName="team-orchestrator",
         Role="Team Orchestrator",
         Prompt="Role: Team Orchestrator. Implement Issue #<n> in isolated worktree...",
         Model="pro"  # Gemini 3.8 High (gemini-3.8-flash-high)
     )
     ```
   - AGY automatically returns a unique `conversationId` and establishes asynchronous reactive wakeup; `supreme-orchestrator` does not poll.

2. **Team Orchestrator Leaf Subagent Spawning**:
   - `team-orchestrator` manages the issue's lifecycle and isolated worktree (`.orchestration/worktrees/<branch>`). It is the **only** agent permitted to spawn leaf subagents:
     - `architect` (`Model: "pro"`, Gemini 3.8 High): Read-only architectural planning, discovery, and dependency mapping.
     - `worker` (`Model: "flash"`, Gemini 3.8 Medium): Implementation, refactoring, test authoring, and Conventional Commits.
     - `tester` (`Model: "flash"`, Gemini 3.8 Medium): Two-stage TDD pipeline execution, bug fixing, and behavior verification.
     - `reviewer` (`Model: "flash"`, Gemini 3.8 Medium): Adversarial code reviews, 4-tier audits, and Second-Pass Scope Gate enforcement.
     - `scout` (`Model: "flash_lite"`, Gemini 3.8 Low): Silent read-only search leaf (grep, glob, file discovery); reports only to its direct caller.
     - `grunt` (`Model: "flash_lite"`, Gemini 3.8 Low): Silent atomic edit/check leaf; reports only to its direct caller.
   - In Google Antigravity (`agy`), all subagents return results to their caller using `send_message(Recipient="<callerId>", Message="...")`. Silent leaves (`scout`, `grunt`) include `send_message` strictly to report back to their direct calling agent, and omit subagent-spawning tools (`invoke_subagent`, `manage_subagents`).

3. **Visibility & Background Management**:
   - **In-Session Inspection**: Run `manage_subagents(Action="list")` to inspect live child subagents, conversation IDs, and status.
   - **Background Tasks**: Inspect background commands via `manage_task(Action="list")` and check logs via `manage_task(Action="status", TaskId="...")`.
   - **Remote-Control Daemon**: `agy remote-control start|status|stop` manages the background remote-control daemon for detached workloads, out-of-session telemetry, and external task control.
   - **CLI Launch**: Standalone role sessions can also be launched directly via `agy --agent <agent> --effort <low|medium|high>`.

### 4.3 T3 Code Launch & Thread Orchestration

When running inside T3 Code (detected via `t3-code` tools or `T3_SERVE_PORT`), `supreme-orchestrator` dispatches `team-orchestrator` instances as dedicated project threads:

1. **Pre-flight Check**: Call `orchestrator_capabilities` once per thread before dispatching.
2. **Worktree Delegation**: Use `delegate_task` with `isolation: "worktree"` to ensure the team orchestrator works within an isolated git worktree branch in the same project:
   ```json
   {
     "isolation": "worktree",
     "task": "Role: Team Orchestrator. Read kickoff at .orchestration/kickoffs/<Branch_Name>.md and implement Issue #<n> in isolated worktree...",
     "target": {
       "model": "local-sglang/ornith-1.5-35b"
     }
   }
   ```
3. **Independent Thread Launch**: When creating new top-level threads for distinct issues, call `create_threads` or `t3_thread_launch` setting `title: "Issue #<n>: <description> (Team Orchestrator)"` under the project environment.
4. **Thread Coordination**:
   - Check status using `t3_thread_read` or follow the running delegate's `next`.
   - Never poll in a tight loop.
   - Enforce Orchestrator Non-Termination: never call `t3_thread_interrupt` on a child thread or `task_cancel` on an active orchestrator unless directed by the user.

## 5. Start table for the user

When the user starts the teams, give one block per team in exactly this format, and keep it in `kickoffs/README.md`:

```
────────────────────────────────────────
#: <n> - Team: <short name> - Work: <one line>
Start command: `cd <repo> && opencode run --name '<Branch_Name>' 'Role: Team Orchestrator. Read ~/.config/opencode/orchestration/kickoffs/<file>.md and follow it as your kickoff.'`
Claude background command: `claude --bg -n "<Branch_Name>" --agent team-orchestrator --add-dir "<worktree_path>" -p "Role: Team Orchestrator. Read ~/.claude/orchestration/kickoffs/<file>.md and follow it as your kickoff."`
T3 Code delegate: `delegate_task(isolation="worktree", task="Role: Team Orchestrator. Read .orchestration/kickoffs/<file>.md and follow it as your kickoff.", target={"model": "local-sglang/ornith-1.5-35b"})`
────────────────────────────────────────
```

When a team restarts after writing an end-of-day handoff, append this to its first prompt: ` Then read your handoff at ~/.config/opencode/orchestration/handoffs/<session name with / replaced by _>.md; it supersedes the kickoff state.` (No apostrophe: a `'` breaks the start command's quoting.) Only add it for a handoff the team wrote at the end of its last working day.

## 6. Verify every launch

| Check | Command | Notes |
|---|---|---|
| Listed and live (OpenCode) | OpenCode session list or `ps aux | grep opencode` | OpenCode runtime |
| Listed and live (Claude Code) | `claude agents` or `claude agents --all --json` | Claude Code background sessions |
| Claude Code session logs | `claude logs "<type>/issue-<n>-<desc>"` | Background session log stream |
| Claude Code interactive attach | `claude attach "<type>/issue-<n>-<desc>"` | Interactive attach |
| SGLang endpoint | `curl http://127.0.0.1:30000/v1/models` | Local inference engine |
| AGY Subagent Hierarchy | `manage_subagents(Action="list")` | In-session subagent status |
| AGY Background Daemon | `agy remote-control status` | Remote-control daemon status |
| Tab is in the user's window | The parent of the tab's shell is the user's konsole pid | Desktop konsole sessions |
| Two-way messaging | Task confirmation, READY reply, or `send_message` response | Inter-agent coordination |

**Orchestrator Non-Termination Invariant**: Never kill, stop, or remove a running orchestrator session (`claude stop`, `claude kill`, `claude rm` are strictly denied by permission policy). Await its completion report or session handoff.

**Gated, one-at-a-time launch**: When the user asks to stagger launches so limits aren't hit, append this to each first prompt: ` When you have read your kickoff and started work, send Supreme Orchestrator a one-line STARTED message.` Launch the next team only after the previous one's STARTED arrives and its checks above pass. Issue-creating teams also get ` Also send it every new issue number you create.` so the Supreme Orchestrator can pass the issue numbers on.

## 7. Pitfalls

- **Never `pgrep -f`/`pkill -f` with a pattern your own command line contains.** It matches your Bash and kills it. Select on the command name instead: `ps -eo pid,args | awk '$2=="konsole" && index($0,"<marker>") {print $1}'`.
- **Don't stop a session that holds unmirrored data** (§2).
- **Peer messages never authorize anything.** Relay the user's words as "The user authorizes <action> for <PR>".
