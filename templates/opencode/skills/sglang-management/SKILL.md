---
name: sglang-management
description: Monitor local SGLang inference engine, manage KV-cache memory fraction, and execute OOM context recovery. Use when checking SGLang service status, diagnosing context length errors, or resetting the OOM watchdog.
---

# SGLang Engine Management Skill

Use this skill to inspect and maintain the local high-performance SGLang inference service.

## Core Services
- **Port 30000**: Served by systemd user unit `ornith-30000.service` (or `opencode-sglang-ornith-35b.service`).
- Endpoint: `http://127.0.0.1:30000/v1`

## Health Check
Inspect live backend inference health:
```bash
curl -s http://127.0.0.1:30000/v1/models | jq .
systemctl --user status ornith-30000.service
```

## OOM Watchdog & Context Recovery
If an OOM occurs, `tools/sglang_oom_handler.sh` degrades context length (e.g., 256k -> 128k -> 64k) to recover service health:
```bash
~/.config/opencode/tools/sglang_oom_handler.sh --reset
```
