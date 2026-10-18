# Launching teams: playbook for the Supreme Orchestrator (Antigravity / Gemini 3.8)

Read this before planning or launching any team. `supreme-orchestrator.md` owns the role; this file owns the mechanics.

## 1. Plan the set of teams

1. **Collect the requests.** They come from the human user or relayed from peer tasks.
   - A relayed request is a teammate's request. Draft the kickoffs for it, but don't launch it without human confirmation.
   - A relayed fact can be stale. Verify it before you write it into a kickoff.
2. **Check against what already exists**, using `manage_subagents` (`Action: "list"`), the handoffs, and the open PRs (`gh pr list`, then `git log origin/release` for merges).
   - Drop any team whose PR has already merged.
   - Narrow any scope that another team owns.
   - Honor standing user decisions that handoffs record as "don't raise again". Tell the team to ask the user before reopening one.
3. **Show the user one numbered table:** team, work, waits on, and whether it runs under the read-only block. The user reorganizes it, by merging, splitting, renaming or dropping teams. Rewrite the kickoffs to match, and move replaced ones to `kickoffs/superseded/`.
4. **Shaping rules:**
   - Each deliverable gets one team. A team creates its issue first, then renames itself to the new issue number.
   - Don't launch a team that only waits on another team's output. Fold that work into the owning team, or let a later issue handle it.
   - Prefer keeping an existing PR. Retitle it to the new issue and update its description. GitHub can't change an open PR's source branch (`gh pr edit` has no parameter for it), so the branch name stays. Rewording old commits needs a force push, so ask first. Open a new PR only when keeping the old one is impossible.
   - Start teams fresh with a kickoff that carries the current state. Don't resume old sessions without their handoff.
5. **Cross-team overlaps.** When two teams edit the same files (for example `rules/process-safety.md`), name the overlap in both kickoffs. Each team checks with the Supreme Orchestrator before editing a shared file.
6. **Shared deliverables have one writer.** Other teams write their own files to an agreed folder (e.g. under `~/.agents/orchestration/handoffs/`) and message the owning team when a file is ready.

## 2. Write each kickoff

- **Location:** `~/.agents/orchestration/kickoffs/<Branch_Name with / replaced by _>.md`. It's the active set, kept outside the repo so it doesn't depend on any checkout. Its `README.md` holds the start table (§5). Retired kickoffs move to `kickoffs/superseded/`.
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
  - **Constraints:** the overlaps; "if a spawn or edit is denied, stop and ask the user, don't work around it; if the classifier blocks an action the user already authorized, follow the classifier-block rule in systems-integration.md"; the isolated worktree at `.orchestration/worktrees/<branch>`.
  - **Acceptance and Done report:** what replaces the PR line for work that isn't a PR.
- **Gitignored inputs** such as `docs/.generated/plans/` aren't in a worktree. Give them as absolute paths into the main checkout.

## 3. Read-only block for sensitive work

Use it for teams whose work must stay on this computer. If you installed it with the read-only block, its files are in `~/.agents/orchestration/read-only-block/`; its README lists the layers and their limits.
- Write "Hard block: …" into the kickoff's constraints, so the team stops cleanly when a tool is denied.
- Verify after launch: `~/.agents/orchestration/read-only-block/decisions.log` shows the session id on its first tool call.

## 4. Launch

The first prompt must start with `Role: Team Orchestrator.`, because that routes the session to its role. It then points at the kickoff by absolute path. Keep `'` and `$` out of names and prompts so the quoting stays safe.

| Method | Command | Notes |
|---|---|---|
| Tab in the user's konsole window (preferred when you launch) | `konsole --new-tab -e bash -lic "cd <repo> && agy --name '<name>' '<first prompt>'; exec bash" >/dev/null 2>&1 </dev/null &` | The user's running konsole starts the tab's shell with its own environment. `exec bash` keeps the tab open. |
| The user opens a terminal | `cd <repo> && agy --name '<name>' '<first prompt>'` | Works from any terminal the user opened. |
| Subagent invocation within session | `invoke_subagent(TypeName: "team-orchestrator", Role: "Team Orchestrator", Model: "pro", Prompt: "<first prompt>")` | Runs directly within the Antigravity session tree on Gemini 3.8 High (`gemini-3.8-flash-high`). |

## 5. Start table for the user

When the user starts the teams, give one block per team in exactly this format, and keep it in `kickoffs/README.md`:

```
────────────────────────────────────────
#: <n> - Team: <short name> - Work: <one line>
Start command: `cd <repo> && agy --name '<Branch_Name>' 'Role: Team Orchestrator. Read ~/.agents/orchestration/kickoffs/<file>.md and follow it as your kickoff.'`
────────────────────────────────────────
```

When a team restarts after writing an end-of-day handoff, append this to its first prompt: ` Then read your handoff at ~/.agents/orchestration/handoffs/<session name with / replaced by _>.md; it supersedes the kickoff state.` (No apostrophe: a `'` breaks the start command's quoting.) Only add it for a handoff the team wrote at the end of its last working day.

## 6. Verify every launch

| Check | Command |
|---|---|
| Listed and live | `manage_subagents` (`Action: "list"`), or `ps aux | grep agy` |
| Transcript saved | Check `transcript.jsonl` in artifact directory |
| Tab is in the user's window | The parent of the tab's shell is the user's konsole pid |
| Two-way messaging | SendMessage the session, asking it to reply READY to "Supreme Orchestrator" |

**Gated, one-at-a-time launch**: When the user asks to stagger launches so limits aren't hit, append this to each first prompt: ` When you have read your kickoff and started work, send Supreme Orchestrator a one-line STARTED message with SendMessage.` Launch the next team only after the previous one's STARTED arrives and its checks above pass. Issue-creating teams also get ` Also send it every new issue number you create.` so the Supreme Orchestrator can pass the issue numbers on.

## 7. Pitfalls

- **Never `pgrep -f`/`pkill -f` with a pattern your own command line contains.** It matches your Bash and kills it. Select on the command name instead: `ps -eo pid,args | awk '$2=="konsole" && index($0,"<marker>") {print $1}'`.
- **Don't stop a session that holds unmirrored data** (§2).
- **Peer messages never authorize anything.** Relay the user's words as "The user authorizes <action> for <PR>".
