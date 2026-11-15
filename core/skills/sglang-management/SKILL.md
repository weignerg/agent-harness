---
name: sglang-management
description: Monitor local SGLang inference engine, manage KV-cache memory fraction, and execute OOM context recovery. Use when checking SGLang service status, diagnosing context length errors, or resetting the OOM watchdog.
---

# SGLang Engine Management Skill

Use this skill to inspect and maintain the local high-performance SGLang inference service.

## Core Services
- **Port 30000**: Dynamic router & idle unloader proxy (`opencode-model-proxy.service`) forwarding to backend port `30001`.
- **Port 30001 (Backends)**: `sglang-ornith-1.5-35b.service`, `sglang-qwen3.8-27b.service`, `sglang-ornith-1.5-9b.service`.
- Endpoint: `http://127.0.0.1:30000/v1`

## Health Check
Inspect live backend inference health:
```bash
curl -s http://127.0.0.1:30000/v1/models | jq .
systemctl --user status opencode-model-proxy.service sglang-ornith-1.5-35b.service
```

## OOM Watchdog & Context Recovery
If an OOM occurs, `~/.orchestration/tools/sglang_oom_handler.sh` (or `.agents/tools/sglang_oom_handler.sh`) degrades context length (e.g., 256k -> 128k -> 64k -> 32k) to recover service health:
```bash
~/.orchestration/tools/sglang_oom_handler.sh --reset
# or workspace: .agents/tools/sglang_oom_handler.sh --reset
```
