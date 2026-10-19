---
description: Systems integration standards, GitHub CLI patterns, and FastMCP conventions
trigger: always_on
---

# Systems integration standards

This file loads at the start of every session. It defines system identifier mapping, tools, naming conventions, and interaction patterns across GitHub engineering tools, GitHub CLI (`gh`), and FastMCP servers. If the current repo's charter specifies otherwise, follow the repo.

## Identifiers & Platform Routing

| When you see | It refers to | Primary Tool | Link format |
|---|---|---|---|
| `#<id>`, `GH-<id>`, `issue-<n>`, "issue", "ticket" | GitHub Issue (or Project item) | GitHub CLI (`gh issue view <id>`) or MCP | `https://github.com/<owner>/<repo>/issues/<id>` |
| `PR #1234`, `#1234`, "the PR" | GitHub Pull Request | GitHub CLI (`gh pr view <id>`) or MCP | `https://github.com/<owner>/<repo>/pull/<id>` |
| `run <id>`, "the build", "actions", red/green check | GitHub Actions workflow run | GitHub CLI (`gh run view <id>`, `gh pr checks`) | `https://github.com/<owner>/<repo>/actions/runs/<run_id>` |
| A commit sha (`7a3b1c...`) | Git commit | `git show` or GitHub CLI (`gh api /repos/<owner>/<repo>/commits/<sha>`) | `https://github.com/<owner>/<repo>/commit/<sha>` |
| A wiki page or doc | GitHub Wiki or Repository Markdown doc | Git repository doc (`docs/`) or GitHub Wiki | `https://github.com/<owner>/<repo>/wiki/<Page>` |
| Code scanning / Security Alert / Dependabot | GitHub Code Scanning (CodeQL) or Dependabot alert | GitHub CLI (`gh api /repos/<owner>/<repo>/code-scanning/alerts`, `gh api /repos/<owner>/<repo>/dependabot/alerts`) | `https://github.com/<owner>/<repo>/security/code-scanning` |
| An identifier you don't recognize | Unknown system | Ask the user which system it belongs to; do not guess or probe every API | — |

## Naming Conventions

| Item | Pattern |
|---|---|
| Branch | `<prefix>/issue-<n>-<name>` or `<prefix>/gh-<n>-<name>`. Prefixes: `feat/`, `fix/`, `docs/`, `refactor/`, `test/`, `task/`. Letters, digits, `_`, `-` only. |
| Commit | Conventional Commits: `<type>(<scope>): <summary>` (e.g. `feat(auth): add login flow (#12)`). Co-authored attribution on final line when pair programming. |
| PR title | `<type>(<scope>): <Issue_Name> (#<n>)` |
| PR body | **Description of changes**, **Test Cases** (white-box variations, happy-path, edge cases), **Closes #<n>** (GitHub Issue link). |
| Session name | Branch name (`/rename <branch>`). Root session is `Supreme Orchestrator`. |
| Handoff | `~/.config/opencode/orchestration/handoffs/<session_name_with_underscores>.md` |
| Temporary files & logs | Workspace `tmp/` folder, never global `/tmp` |

## Interaction & Safety Rules

- **Read before you write.** Fetch the current remote state first: PR head, existing comments, or GitHub Actions status. A PR update replaces remote entities; preserve reviewers and labels. On a conflict, re-read and retry.
- **Outward-facing writes need user authorization.** Pushes to remote origin (`git push`), creating/updating PRs (`gh pr create`), posting review verdicts (`gh pr review --approve`), closing/creating issues (`gh issue ...`), and triggering GitHub Actions workflow runs (`gh workflow run`) require explicit human go-ahead. Drafting and local testing are always permitted.
- **Classifier block handling:** When auto-mode classifier blocks an authorized action, ask the user to switch the session to accept-edits mode (`Shift+Tab`), retry the action through the standard permission prompt, and switch back to auto-mode.
- **Link at first mention.** Every issue, PR, or build run mentioned in team communications must include its full URL. In Markdown: `[PR #<id>](<url>)`, `[Issue #<id>](<url>)`, `[Run #<id>](<url>)`.
- **GitHub API Rate Limiting & Clean Pagination:** GitHub REST and GraphQL APIs are rate-limited. Batch queries by key, use page sizes $\le 100$, and back off immediately on 429 or secondary rate limit responses.
- **Structured Review Threads:** All code reviews follow the 4-tier severity system (🔴 BLOCKER, 🟠 MUST FIX, 🟡 WARNING, 🟢 BEST PRACTICE) with single consolidated response comments linked to individual thread comments.
- **Secret & Credential Perimeter:** Never include API tokens, passwords, private keys, or credentials in commit messages, logs, PR comments, or handoffs.
- **Timestamps:** User-facing timestamps follow `dd mmm yy // hhmm` (e.g., `17 Oct 26 // 1710`).
