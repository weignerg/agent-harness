# ⚡ TL;DR Quickstart & Multi-Runtime Usage Guide

`agent-harness` is the canonical, multi-runtime agent framework unifying **OpenCode**, **Anthropic Claude Code**, and **Google Antigravity (AGY)** with local high-throughput **SGLang** inference and **T3 Code** unified control.

---

## 1. ⚡ 60-Second TL;DR Install & Update Commands

### Full Default Install
Deploys Ornith 1.5 35B-A3B MoE (workhorse) + Ornith 1.5 9B (fast leaf), Obsidian knowledge vault memory, FastMCP servers, and native agent profiles across Antigravity, Claude Code, and OpenCode:
```bash
./install.sh
```

### Install with Qwen 3.8 27B Dense (NVFP4 / Q6 VRAM Speculative Decoding)
Configures SGLang for Qwen 3.8 27B Dense (`qwen3.8-27b`, HuggingFace model path `nvidia/Qwen3.8-27B-NVFP4`) fitting 100% in GPU VRAM with FP8 KV cache (`fp8_e4m3`) and `NEXTN`/`EAGLE3` speculative decoding:
```bash
./install.sh --sglang-model qwen3.8-27b

# Or specify an explicit quantization profile:
./install.sh --sglang-model 27b-nvfp4
./install.sh --sglang-model 27b-q6
```

### T3 Code (`t3 serve`) Unified Web UI Server
The T3 Code unified frontend server listening on port `3773` is set up and enabled by default on standard installs (and honors `--no-t3` / `--without-t3` to disable). If the `t3` CLI is not yet installed on the machine, install it anytime via `curl -fsSL https://t3.codes/install.sh | sh`:
```bash
# Standard installation automatically sets up and enables t3 serve:
./install.sh

# Or disable T3 Code serve:
./install.sh --no-t3
```

#### Pairing Token & Authentication (`t3 pair`)
T3 Code requires a pairing token to connect your browser, desktop, or mobile client to `t3-serve.service` (port `3773`).
- By default, pairing tokens expire after **5 minutes** (`--ttl 5m`).
- At the end of `./install.sh`, a fresh pairing token and Pairing URL are minted and displayed automatically.
- Whenever your token expires or when pairing a new device, run:
  ```bash
  # Mint a new 5-minute pairing token, QR code, and Pairing URL:
  t3 pair

  # Or mint a longer-lived 1-hour pairing token:
  t3 pair --ttl 1h
  ```
- Open the printed `Pairing URL: http://<host>:3773/pair#token=<TOKEN>` in your browser, or paste the `Token` into the T3 Code prompt.

### Fast Config-Only Resync (~5 Seconds)
Quickly recompiles and synchronizes agent charters, tools, permissions, and FastMCP configs across all 3 runtimes without restarting SGLang or re-running warmup:
```bash
./install.sh --target all --global --no-backends --no-firewall --no-obsidian --no-t3 --skip-warmup --no-healthcheck -y
```

### Per-Repository Local Sandboxed Installation
Deploys local `.opencode/`, `.claude/`, or `.orchestration/` configs into a targeted repository without modifying your home directory:
```bash
./install.sh --local /path/to/your/repo
```

### Verification & Safe Rollback
```bash
# Verify cryptographic SHA-256 integrity of all deployed files:
./install.sh --verify

# Safely roll back all installed harness files and restore backups:
./install.sh --uninstall
```

---

## 2. 🚀 How to Use Each Runtime (TL;DR Cheat Sheet)

### A. OpenCode (`opencode`)

OpenCode runs locally with terminal TUI and connects directly to local SGLang on port `30000`.

- **Launch Interactive TUI**:
  ```bash
  opencode
  ```
- **Primary Agent**: Starts automatically in `supreme-orchestrator` (`ornith-local/ornith-1.5-35b` by default, or `local-sglang/qwen3.8-27b` if selected).
- **In-Session Model Selection**:
  ```bash
  # Override model via CLI launcher:
  opencode --model local-sglang/qwen3.8-27b
  opencode --model ornith-local/ornith-1.5-35b
  ```
- **Built-in Slash Commands**:
  - `/handoff` — Synthesize current session progress into a durable handoff checkpoint.
  - `/colbert` — Run CPU ColBERTv2 late-interaction neural search over Obsidian vault notes.
  - `/reindex` — Rebuild or refresh the ColBERTv2 index over `~/Vaults/home`.
  - `/escalate` — Escalate architectural decisions or safety gate requests to the human operator.
  - `/review` — Run 4-tier adversarial review and security audit on current git diff.
  - `/test` — Execute the two-stage TDD pipeline.
  - `/worktree` — Provision, list, or prune isolated `.orchestration/worktrees/`.
- **Inspect Agent Config & Permission Gates**:
  ```bash
  opencode debug config
  opencode debug agent supreme-orchestrator
  ```

---

### B. Claude Code (`claude`) + Background Agent Teams (`claude --bg`)

Claude Code features native agent team orchestration with experimental background teams enabled by default (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` pre-configured in `~/.claude/settings.json`).

- **Start Interactive Primary Session**:
  ```bash
  claude --agent supreme-orchestrator
  ```
- **Launch Background Per-Issue Team Orchestrators**:
  `supreme-orchestrator` (or human operators) dispatch autonomous background teams targeting isolated git worktrees:
  ```bash
  claude --bg -n "feat/issue-42-my-feature" \
    --agent team-orchestrator \
    --add-dir "/path/to/repo/.orchestration/worktrees/issue-42-my-feature" \
    -p "Execute Issue #42 in isolated worktree"
  ```
- **Manage & Attach to Background Sessions**:
  ```bash
  claude agents                              # List active background agent teams
  claude agents --all --json                 # JSON status across all workspaces
  claude logs "feat/issue-42-my-feature"     # Tail live execution logs
  claude attach "feat/issue-42-my-feature"   # Interactively attach terminal
  ```

---

### C. Google Antigravity (`agy`)

Google Antigravity provides multi-tier subagent spawning, reactive message awakenings, and background daemon execution powered by Google Gemini 3.8 models.

- **Launch Interactive IDE or CLI Session**:
  ```bash
  agy
  ```
- **Launch Explicit Role with Gemini 3.8 Reasoning Effort Tier**:
  ```bash
  agy --agent supreme-orchestrator --effort high     # Gemini 3.8 High (pro)
  agy --agent worker --effort medium                 # Gemini 3.8 Medium (flash)
  agy --agent scout --effort low                     # Gemini 3.8 Low (flash_lite)
  ```
- **List Installed Agent Profiles**:
  ```bash
  agy agents
  ```
- **Native Subagent Trees**:
  In-session multi-tier subagents run automatically via native tools: `invoke_subagent`, `send_message`, and `manage_subagents(Action="list")`.
- **Background Remote-Control Daemon**:
  ```bash
  agy remote-control start    # Start headless remote daemon
  agy remote-control status   # Check daemon status and port
  agy remote-control stop     # Terminate daemon safely
  ```

---

### D. T3 Code (`t3 serve`) Unified Multi-Runtime Frontend

T3 Code provides a single web-based interface and REST/WebSocket API to manage Claude Code (`~/.claude`), OpenCode (`~/.config/opencode`), and isolated `.orchestration/worktrees/` in one unified cockpit.

- **Manage via Systemd User Unit**:
  ```bash
  systemctl --user enable --now t3-serve.service
  systemctl --user status t3-serve.service
  ```
- **Install CLI**:
  ```bash
  curl -fsSL https://t3.codes/install.sh | sh
  ```
- **Or Run Ad-Hoc CLI**:
  ```bash
  t3 serve --host 0.0.0.0 --port 3773
  ```
- **Mint Pairing Token (`t3 pair`)**:
  ```bash
  # Mint new 5-minute pairing token, QR code, and Pairing URL:
  t3 pair

  # Or mint a longer-lived 1-hour pairing token:
  t3 pair --ttl 1h
  ```
- **Access Web Cockpit**:
  Open `http://127.0.0.1:3773` (or `http://<lan_or_tailscale_ip>:3773`) in any modern browser or mobile client and authenticate using your pairing token or follow the `Pairing URL`.
- **View Initial Service Token**:
  ```bash
  journalctl --user -u t3-serve.service -n 30 --no-pager
  ```

---

## 3. 🧠 Switching Between Ornith 1.5 35B and Qwen 3.8 27B (SGLang Port 30000)

Both model backends bind to `127.0.0.1:30000/v1` for OpenAI-compatible API parity. Only one backend service runs at a time.

### Switch to Qwen 3.8 27B Dense (100% VRAM NVFP4 + NEXTN Speculative Decoding + FP8 KV Cache)
Target weights: `nvidia/Qwen3.8-27B-NVFP4` (dense 27B NVFP4 on GPU VRAM)
```bash
# 1. Stop Ornith 35B and activate Qwen 3.8 27B service:
systemctl --user stop opencode-sglang-ornith-35b.service
systemctl --user enable --now opencode-sglang-qwen27b.service

# 2. Resync OpenCode configuration to Qwen profile:
./install.sh --sglang-model qwen3.8-27b --no-backends --no-firewall --no-obsidian --skip-warmup --no-healthcheck -y
```

### Switch Back to Ornith 1.5 35B-A3B MoE (Workhorse Model)
```bash
# 1. Stop Qwen 27B and activate Ornith 35B service:
systemctl --user stop opencode-sglang-qwen27b.service
systemctl --user enable --now opencode-sglang-ornith-35b.service

# 2. Resync OpenCode configuration to Ornith profile:
./install.sh --sglang-model ornith-35b --no-backends --no-firewall --no-obsidian --skip-warmup --no-healthcheck -y
```

### OOM Watchdog & Memory Fraction Management
```bash
# Check SGLang memory utilization and OOM watchdog status:
~/.local/share/opencode-sglang-stack/sglang_oom_handler.sh --status

# Reset watchdog counter and restore default KV cache fraction:
~/.local/share/opencode-sglang-stack/sglang_oom_handler.sh --reset
```

---

## 4. 🛠️ Two-Tier Agent Roster & Permission Matrix Reference Table

| Role | Mode | Logical Tier | OpenCode Model | Claude Code Model | Antigravity Model & Tier | Allowed Subagents Fan-Out | Edit / Write Gates | Bash Deny / Ask Safety Invariants |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `supreme-orchestrator` | `primary` | `heavy` | `ornith-1.5-35b` / `qwen3.8-27b` | `opus` | `gemini-3.8-flash-high` (`pro`) | `team-orchestrator` only | ❌ Deny | **Deny**: `git commit*`, `git merge*`, `kill*`, `pkill*`, `systemctl stop*`<br>**Ask**: `git push*`, `gh pr *`, `gh issue *`, `gh workflow run*` |
| `team-orchestrator` | `subagent` | `heavy` | `ornith-1.5-35b` / `qwen3.8-27b` | `opus` / `sonnet` | `gemini-3.8-flash-high` (`pro`) | `architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt` | ❌ Deny | **Deny**: `git commit*`, `git merge*`, `kill*`, `pkill*`, `systemctl stop*`<br>**Ask**: Outward-facing writes |
| `architect` | `subagent` | `heavy` | `ornith-1.5-35b` / `qwen3.8-27b` | `opus` (read-only) | `gemini-3.8-flash-high` (`pro`) | `scout` only | ❌ Deny | **Deny**: `git commit*`, `git merge*`, mutating shell ops |
| `worker` | `subagent` | `workhorse` | `ornith-1.5-35b` / `qwen3.8-27b` | `sonnet` | `gemini-3.8-flash-medium` (`flash`) | `grunt`, `scout` only | ✅ Allow (worktree only) | **Deny**: Killing orchestrators / SGLang<br>**Ask**: Outward-facing writes |
| `tester` | `subagent` | `workhorse` | `ornith-1.5-35b` / `qwen3.8-27b` | `sonnet` | `gemini-3.8-flash-medium` (`flash`) | `grunt`, `scout` only | ✅ Allow (test repairs) | **Deny**: Killing orchestrators / SGLang |
| `reviewer` | `subagent` | `workhorse` | `ornith-1.5-35b` / `qwen3.8-27b` | `sonnet` | `gemini-3.8-flash-medium` (`flash`) | `scout` only | ❌ Deny | **Deny**: `git commit*`, `git merge*`, mutating shell ops |
| `scout` | `subagent` (leaf) | `fast` | `ornith-1.5-9b` | `haiku` | `gemini-3.8-flash-low` (`flash_lite`) | *None (Silent Leaf)* | ❌ Deny | **Deny**: `git commit*`, mutating shell ops |
| `grunt` | `subagent` (leaf) | `fast` | `ornith-1.5-9b` | `haiku` | `gemini-3.8-flash-low` (`flash_lite`) | *None (Silent Leaf)* | ✅ Allow (atomic edits) | **Deny**: Killing orchestrators / SGLang |
