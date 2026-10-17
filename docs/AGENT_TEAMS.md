# OpenCode AI Agent Teams & Adversarial Quality Assurance Architecture

## 1. Philosophical Foundation & Team Charter

High-reliability agentic software engineering demands zero tolerance for ungrounded architectural drift, execution regressions, memory/VRAM leaks, or compromised master sessions. To eliminate rubber-stamping, complacency, and confirmation bias, development in this repository is governed by an **OpenCode AI Agent Team** characterized by strict separation of duties, adversarial peer review, grounded architectural stewardship, and human sovereign authority.

---

## 2. Team Hierarchy & Roles

```mermaid
graph TD
    User["Human Operator & Merge Manager<br/>(Sovereign Authority & Co-Mediator)"] <--> Arch["Architect Agent<br/>(architect-local / Qwen-3.8-Flash-Next / 256k)"]
    Arch --> WorkPool["Worker Implementation Agents<br/>(worker-local / Ornith-1.5-35B-A3B MoE / 256k)"]
    WorkPool --> SubPool["Sub-Agent Task Workers<br/>(sub-agent-local / Ornith-1.5-9B / 4k-128k)"]
    WorkPool --> PR["Pull Request & Git Branch"]
    PR --> RevPool["Adversarial Reviewer Agents<br/>(reviewer-local / Ornith-1.5-35B-A3B MoE / 256k)"]
    RevPool -- "Critiques & Requested Revisions" --> WorkPool
    RevPool -- "Approval (Gate 1)" --> MergeGate{"Two-Key Merge Gate"}
    User -- "Sovereign Sign-off (Gate 2)" --> MergeGate
    MergeGate --> TargetBranch["Target Branch (develop)"]
```

### 2.1 Human Operator & Repository Owner / Merge Manager (The User)
- **Role**: Sovereign repository owner, final merge authority, and supreme coordinator.
- **Responsibilities**:
  - Sets project priorities, epics, and engineering objectives.
  - Co-mediates agent coordination alongside the Architect Agent.
  - Holds the second key to the Two-Key Merge Gate. No PR may merge without explicit human operator approval.

### 2.2 Architect Agent (`architect-local`)
- **Model**: Local Qwen-3.8-Flash-Next (up to 256k context).
- **Role**: Systems architect, structural design, and grounded gatekeeper.
- **Responsibilities**:
  - Structural analysis, high-context reasoning, dependency mapping, and hardware alignment.
  - Prevents scope creep and ensures all designs conform to local inference compute precision and FlashInfer decode attention.

### 2.3 Worker Agent (`worker-local`)
- **Model**: Local Ornith-1.5-35B-A3B MoE (256k context, zero CPU offload).
- **Role**: Dedicated builder assigned to specific GitHub Issues and branch PRs (`<type>/issue-<number>-<description>`).
- **Responsibilities**:
  - Authors code, modules, test fixtures in isolated worktrees (the repository's own `.opencode/worktrees/<branch-name>`).
  - Authors conventional commits (`feat(scope): Issue-# ...`, `fix(scope): Issue-# ...`).
  - Proactively addresses all critique and requested changes posted by Adversarial Reviewer Agents.
- **Restriction**: A Worker Agent is strictly prohibited from reviewing or approving its own code.

### 2.4 Sub-Agent Worker (`sub-agent-local`)
- **Model**: Local Ornith-1.5-9B (4k-128k dynamic context).
- **Role**: Ultra-fast atomic task runner.
- **Responsibilities**:
  - Executes grep queries, localized regex checks, atomic file edits, and lightweight commands.

### 2.5 Adversarial Reviewer Agent (`reviewer-local`)
- **Model**: Local Ornith-1.5-35B-A3B MoE (256k context, zero CPU offload).
- **Role**: Independent, suspicious code auditor spun up dynamically when changes are staged or proposed.
- **Mindset**: **Highly Suspicious**. Assumes incoming code contains hidden bugs, security leaks, unhandled edge cases, or process safety hazards.
- **Audit Mandate**:
  1. **Secret & Credential Leak Detection**: Scans for any tokens (`HF_TOKEN`, API keys) or hardcoded paths (e.g., custom mount paths, `/home/<user>`). Environment tokens must be loaded via `%h/.config/opencode-backends/env` rather than committed into service definitions.
  2. **Process Safety**: Scans for unsafe `kill`, `pkill`, `killall`, or subagent termination commands that could terminate active `supreme-orchestrator` or `team-orchestrator` sessions/processes or inference backends.
  3. **Backend & Quantization Alignment**: Verifies FlashInfer attention engines, KV cache formats (`fp8_e4m3` vs `nvfp4`), and port routing.
  4. **Mock Illusion Hunting**: Validates that tests reflect true integration behavior and not over-permissive fake mocks.

---

## 3. The Adversarial Quality Loop

```mermaid
sequenceDiagram
    autonumber
    actor Human as Human Merge Manager
    participant Arch as Architect Agent
    participant Worker as Worker Agent
    participant Reviewer as Adversarial Reviewer
    participant GitHub as GitHub PR / Repo

    Note over Human,Arch: Task Assignment & Scoping
    Human->>Arch: Authorize Issue & Plan
    Arch->>Worker: Dispatch Sub-Issue Task
    Worker->>GitHub: Implement, Test & Push Branch / PR
    
    Note over Reviewer,GitHub: Trigger: Worker Push
    Reviewer->>GitHub: Fetch Diff & Audit against rules
    Reviewer->>Reviewer: Hunt for leaks, bugs & mock illusions
    Reviewer->>GitHub: Post Adversarial Critique & Change Requests
    
    loop Feedback & Hardening Loop
        Worker->>GitHub: Address Comments, Refactor & Push Fixes
        Reviewer->>GitHub: Re-audit Diff & Validate Tests
    end
    
    Reviewer->>GitHub: Formal Approval (Gate 1 Passed)
    Arch->>Human: Present Verified PR & Grounded Audit
    Human->>GitHub: Human Sovereign Approval & Merge (Gate 2 Passed)
```

---

## 4. The Two-Key Merge Gate

No Pull Request may be merged without clearing **both** keys:

1. **Key 1: Adversarial Reviewer Approval**
   - All tests pass (`./tests/test_e2e_harness_handoff.sh`).
   - Zero credential or path leaks.
   - All adversarial critique items verified as resolved.

2. **Key 2: Human Operator Sovereign Sign-Off**
   - Explicit approval directive: `Approved :heavy_check_mark:` (or `Approved ✔️`).
   - If changes are still undergoing scrutiny: `Continue Review :eyes:` (or `Continue Review 👀`).
