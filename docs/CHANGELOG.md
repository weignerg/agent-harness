# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This changelog covers releases **v0.4.0 through v0.7.1**. For the full history of earlier
versions, see [Earlier releases (v0.1.0–v0.3.0)](#earlier-releases-v010v030) below.

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
