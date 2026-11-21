# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This changelog covers releases **v0.4.0 through v0.7.3**. For the full history of earlier
versions, see [Earlier releases (v0.1.0–v0.3.0)](#earlier-releases-v010v030) below.

## [v0.7.3] - 2026-11-20

### Fixed
- **Windows PowerShell 5.1 & WSL2 bootstrap fixes** (`windows/install-windows.ps1`):
  - Fixed PowerShell 5.1 `EmptyPipeElement` parse errors (moved pipes to trailing line ends and removed raw UTF-8 em-dash), `Test-IsAdmin` operator precedence cast, DISM `.State` detection (plus Windows 11 Store WSL2 where `VirtualMachinePlatform` is enabled without legacy `Microsoft-Windows-Subsystem-Linux`), `Write-State` parenthesized string cast, and Step 2 distro-present reboot-loop guard.
  - Added `--cd ~` to all `wsl.exe` invocations to eliminate UNC path translation warnings, and kept `install.sh` interactive by default (only passing `-y` when `-Quiet` is set).
- **OpenCode auto-install & systemd service resolution** (`install.sh`):
  - Automatically installs the `opencode` CLI (`https://opencode.ai/install`) when missing, symlinks `~/.local/bin/opencode -> ~/.opencode/bin/opencode`, patches `ExecStart=` in `opencode-server.service`, and verifies port `4096` health.
- **Python 3.12 standalone venv for SGLang** (`install.sh`):
  - Provisions Python 3.12 via `uv` when the host ships Python 3.13/3.14+ (e.g. Ubuntu 26.04) so PyTorch/SGLang wheels install cleanly without compiling from source.
- **Hardware-probed model & GPU capability protection** (`install.sh`, `harness/hardware/probe.py`):
  - Fixed `SGLANG_MODEL` default clobbering `gpu_probe.sh` auto-selection so 16 GB GPUs (e.g. RTX 4090 Laptop / RTX 4080) cleanly select and run `sglang-ornith-1.5-9b.service` across systemd, `env`, `opencode.json`, and compiled agents unless `--sglang-model` is explicitly passed.
  - Added NVIDIA compute-capability (`>= 7.5`) and VRAM (`>= 8 GB`) pre-flight guard to skip local SGLang installation, model weight download, and healthcheck polling on unsupported GPUs (e.g. Pascal GTX 1060), plus fail-fast systemd crash-loop detection (`SubState=auto-restart`).
- **Hugging Face token persistence & modern `hf` CLI** (`install.sh`):
  - Replaced deprecated `huggingface-cli` with the modern `hf` CLI (`hf download`), added a step-by-step Hugging Face account & Read token prompt (only prompted when `HF_TOKEN` is unset), and reliably persisted user-pasted tokens into `~/.config/opencode-backends/env`.
- **Guided T3 Code pairing UX** (`install.sh`):
  - Replaced internal jargon with plain-English T3 Code login instructions and runs `t3 pair --ttl 1h` directly during install while showing how to re-run it later.

### Changed
- Added PowerShell 5.1 compatibility assertions in `windows/tests/wsl-bootstrap.tests.ps1` and GPU guard / `hf` CLI / probed-model tests in `tests/test_guided_config_gate.sh`.
- Version bump `0.7.2` → `0.7.3`.

## [v0.7.2] - 2026-11-20

### Added
- **Two self-extracting release artifacts** (`release-build/make_linux_installer.sh`,
  `release-build/make_windows_installer.ps1`, `release-build/release-test`): deterministic
  `base64(tar.gz)` self-extracting installers (`install-agent-harness-v0.7.2-linux.sh` and
  `install-agent-harness-v0.7.2-windows10-11.ps1`) with embedded SHA-256 verification before
  extraction/execution; removes the legacy separate source-tarball release path. —
  [#64](https://github.com/weignerg/agent-harness/issues/64),
  [#65](https://github.com/weignerg/agent-harness/issues/65)
- **Guided per-runtime configuration wizard + human-confirmed T3 completion gate** in
  `install.sh`: interactive checklist covering OpenCode, Claude Code, and Antigravity / T3 Code
  pairing, `OPENCODE_SERVER_USERNAME` ↔ WSL `[user] default=` reconciliation, and a
  human-confirmed end-to-end T3 Supreme Orchestrator verification gate. —
  [#67](https://github.com/weignerg/agent-harness/issues/67)
- **Windows/WSL bootstrap test suite** (`windows/tests/wsl-bootstrap.tests.ps1`) and guided
  wizard/gate regression suite (`tests/test_guided_config_gate.sh`).

### Fixed
- **WSL2 bootstrap hardening** (`windows/install-windows.ps1`): rewritten `Get-InstalledDistro`
  exact-instance detection with `0x80070xxx` error surfacing, `[boot] systemd=true` persistence
  in `/etc/wsl.conf` (and removal of `--no-healthcheck`), interactive Linux username/password/sudo
  setup decoupled from Windows login, and Task Scheduler at-logon auto-resume across the
  mandatory WSL reboot. — [#66](https://github.com/weignerg/agent-harness/issues/66)

### Changed
- **T3 top-level-thread dispatch for team-orchestrators**: refactored harness orchestration rules,
  `core/manifest.json`, and `harness/installer/compiler.py` so per-issue team-orchestrators
  launch as T3 top-level threads (gated on running under T3 Code) with durable `variant: high`
  options compilation. — [#68](https://github.com/weignerg/agent-harness/issues/68)
- Version bump `0.7.1` → `0.7.2`.

## [v0.7.1] - 2026-11-16

### Added
- `windows/install-windows.ps1` — Windows 11 (WSL2) one-command install bootstrap: run from
  inside the downloaded v0.7.1 source bundle; provisions WSL + Ubuntu, handles the single
  mandatory reboot via a resume marker, copies the bundle to a canonical install target, and
  runs `install.sh` inside WSL. (Issue #61)
- `docs/WINDOWS.md` — Windows (WSL) install guide (TLDR one-liner, reboot note,
  requirements, troubleshooting, update/uninstall).
- `README.md` — "Windows (WSL) — PowerShell One-Command Install" quick-start section
  + documentation pointer.

### Changed
- Version bump `0.6.0` → `0.7.1`.

## [v0.6.0] - 2026-11-15

### Added
- Adaptive multi-machine GPU/RAM sizing and CPU offload — [#49](https://github.com/weignerg/agent-harness/issues/49)
- Standardized `sglang-<model>.service` names and deployed `opencode-model-proxy` on port 30000 — [#52](https://github.com/weignerg/agent-harness/issues/52)
- Optional `qwen3.8` model alias; formalized qwen 3.8 as the designated fallback target — [#43](https://github.com/weignerg/agent-harness/issues/43)

### Changed
- Restored full RTX 5090 context and completed the dynamic model proxy — [#48](https://github.com/weignerg/agent-harness/issues/48)
- Synced OpenCode/T3 model lists dynamically from the catalog and rejected unknown models — [#56](https://github.com/weignerg/agent-harness/issues/56)

### Fixed
- Preserved `SGLANG_UNIT=%n` for the OOM handler and guarded proxy startup readiness — [#52](https://github.com/weignerg/agent-harness/issues/52) _(follow-up commit 53f61fe, no issue number in subject)_
- Bumped Qwen 27B Mamba cache size to 5, isolated OOM state, and cleaned up install loops — [#54](https://github.com/weignerg/agent-harness/issues/54)

### Documentation
- Documented supreme-on-qwen / qwen-3.8 fallback + leaf-ornith behavior — [#43](https://github.com/weignerg/agent-harness/issues/43)

### Chore
- Version bump to 0.6.0 — [#58](https://github.com/weignerg/agent-harness/pull/58)

## [v0.5.2] - 2026-11-05

### Added
- Dynamic model router and idle-unloader proxy for orchestrators — [#46](https://github.com/weignerg/agent-harness/pull/46) _(unattributed; no issue number derivable)_

### Changed
- _(none)_

### Fixed
- _(none)_

### Documentation
- _(none)_

### Chore
- Version bump to 0.5.2 — [#47](https://github.com/weignerg/agent-harness/pull/47)

## [v0.5.1] - 2026-11-05

### Added
- `t3-serve.service` working-directory configuration and a `--t3-workdir` installer flag — [#35](https://github.com/weignerg/agent-harness/issues/35)
- Thread-dispatch mechanisms: instruct agents to recognize T3 Code and use thread-dispatch — [#41](https://github.com/weignerg/agent-harness/issues/41)

### Changed
- Synced harness instructions, rules, and workspace entrypoints for T3 Code sessions — [#37](https://github.com/weignerg/agent-harness/issues/37)

### Fixed
- SGLang text-generation corruption fixed, model names cleaned, 256k context verified, supreme-orchestrator restored — [#39](https://github.com/weignerg/agent-harness/issues/39)
- Quoted `MAMBA_ARGS` and enforced whitespace quoting in the env file — [#44](https://github.com/weignerg/agent-harness/pull/44) _(unattributed; no issue number derivable)_

### Documentation
- _(no dedicated docs-only commits in range; docs were folded into feature PRs)_

### Chore
- Version bump to 0.5.1 — [#45](https://github.com/weignerg/agent-harness/pull/45)

## [v0.5.0] - 2026-11-01

### Added
- Automatic `t3-serve` setup: env config, systemd activation, and healthcheck parity with `opencode serve` — [#24](https://github.com/weignerg/agent-harness/issues/24)
- T3 pairing token minted and displayed in the installer summary, with a documented `t3 pair` workflow — [#29](https://github.com/weignerg/agent-harness/issues/29)

### Changed
- SGLang providers/models synced into existing `opencode.json`; sandbox daemon leaks prevented — [#31](https://github.com/weignerg/agent-harness/issues/31)
- Clean, concise model display names for T3 Code readability — [#33](https://github.com/weignerg/agent-harness/issues/33)

### Fixed
- Qwen 27B NVFP4 warmup: switched to `nvidia/Qwen3.8-27B-NVFP4`, validated warmup & service flags, and resolved 27b-q6 GGUF quantization — [#20](https://github.com/weignerg/agent-harness/issues/20)
- Fixed `opencode-sglang-qwen27b.service` sed corruption, warmup CUDA-graph timeout, and service startup — [#23](https://github.com/weignerg/agent-harness/issues/23)
- Used unbraced variable expansion for optional flags in the qwen27b service — [#23](https://github.com/weignerg/agent-harness/issues/23)
- Guarded `opencode` reload and sandbox-regex-pattern review findings — [#31](https://github.com/weignerg/agent-harness/issues/31)
- Pass 1 review findings: Test-18 schema handling and Python timeout fallback — [#29](https://github.com/weignerg/agent-harness/issues/29)

### Documentation
- Codified zero-warmup session context, drive-to-completion, and host invariants in the charter — [#25](https://github.com/weignerg/agent-harness/issues/25)
- Aligned the T3 Code systemd unit name to `t3-serve.service` — [#25](https://github.com/weignerg/agent-harness/issues/25)
- Authored the TL;DR Quickstart & Multi-Runtime Usage Guide — [#19](https://github.com/weignerg/agent-harness/issues/19)

### Chore
- Version bump to 0.5.0 and `develop`→`release` merge — [#21](https://github.com/weignerg/agent-harness/pull/21)

## [v0.4.0] - 2026-10-31

### Added
- Adopted the Qwen 3.8 27B dense profile alongside Ornith 35B, plus a selectable Qwen 3.5 27B dense profile — [#16](https://github.com/weignerg/agent-harness/issues/16)
- Added Claude `--bg` agent-teams dispatch and settings permissions — [#12](https://github.com/weignerg/agent-harness/issues/12)
- Added `t3-serve` systemd unit, installer flags, and docs for T3 Code sessions — [#15](https://github.com/weignerg/agent-harness/issues/15)
- Added base-branch and existing-branch support for hierarchical worktree provisioning — [#10](https://github.com/weignerg/agent-harness/issues/10)
- Added dual-scope (global vs workspace) configuration for the AGY runtime — [#10](https://github.com/weignerg/agent-harness/issues/10)

### Changed
- SSOT architecture + MCP hardening across runtimes, removing legacy templates in favor of a shared core/config — [#10](https://github.com/weignerg/agent-harness/issues/10)
- Multi-runtime parity: canonical 3-agent architecture, refreshed `supreme-orchestrator` permissions, and a clean agent-teams rule — [#9](https://github.com/weignerg/agent-harness/pull/9)

### Fixed
- Runtime bash ask/deny gates and per-role task fan-out for safety — [#13](https://github.com/weignerg/agent-harness/issues/13)
- Review findings for orchestrator git gates and claude parity — [#13](https://github.com/weignerg/agent-harness/issues/13)
- Claude Pass 1 review findings: interactive inspection, kickoff paths, and wildcard deny rules — [#12](https://github.com/weignerg/agent-harness/issues/12)
- AGY: restored `send_message` to silent leaves, compiler-tool invariants, native tool-name alignment, and the multi-tier subagent hierarchy — [#14](https://github.com/weignerg/agent-harness/issues/14)
- SGLang: purged legacy `qwen35` references and enforced per-role task gates; resolved installer-test syntax and clean markers during rollup — [#11](https://github.com/weignerg/agent-harness/issues/11)
- Installer hardening: bare `python3` path, venv-before-sync ordering, leaf `task:deny` compilation, SSOT paths, uninstallation safety, and audit findings across agy/opencode/claude — [#10](https://github.com/weignerg/agent-harness/issues/10)
- opencode: restored sampling hyperparams and the question-tools map; corrected permission-evaluation order, MCP module pathing, and host safety guards — [#10](https://github.com/weignerg/agent-harness/issues/10)

### Documentation
- Codified the hierarchical epic & nested-issue workflow across runtimes — [#10](https://github.com/weignerg/agent-harness/issues/10)

### Chore
- Version bump to 0.4.0 — [#18](https://github.com/weignerg/agent-harness/pull/18)

## Earlier releases (v0.1.0–v0.3.0)

<a name="earlier-releases-v010v030"></a>
Full release notes and history for versions **v0.1.0 through v0.3.0** live on the GitHub release
pages (linked in the repository's [Releases](https://github.com/weignerg/agent-harness/releases)
section). This file begins tracking from v0.4.0.
