"""Deterministic Subagent Frontmatter Compiler for Multi-Runtime Agent Harness.

Compiles canonical markdown agent definitions from core/agents/*.md using metadata
from core/manifest.json into runtime-specific formats for OpenCode, Claude Code, and AGY.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List, Optional


import os


def extract_body(agent_file: Path) -> str:
    """Extract markdown prompt body, stripping any pre-existing frontmatter."""
    content = agent_file.read_text(encoding="utf-8")
    if content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            return parts[2].lstrip()
    return content.lstrip()


def compile_opencode_frontmatter(
    role_name: str,
    meta: Dict[str, Any],
    tier_models: Optional[Dict[str, Any]] = None,
    primary_model: Optional[str] = None,
) -> str:
    tier_models = tier_models or {}
    tier = meta.get("tier", "workhorse")
    if tier in ("heavy", "workhorse") and primary_model:
        model = primary_model
    else:
        model = tier_models.get(tier, {}).get("opencode", "ornith-local/ornith-1.5-35b")
    mode = meta.get("mode", "subagent")
    desc = meta.get("description", "").replace('"', '\\"')
    tools = meta.get("tools", {})
    readonly = meta.get("readonly", False)
    allowed_subagents = meta.get("allowed_subagents") or []

    tools_yaml = []
    for k, v in tools.items():
        tools_yaml.append(f"    {k}: {'true' if v else 'false'}")
    tools_block = "\n".join(tools_yaml)

    lines = [
        "---",
        f'description: "{desc}"',
        f"mode: {mode}",
        f"model: {model}",
        "tools:",
        tools_block,
        "permission:",
        f"  edit: {'deny' if readonly else 'allow'}",
        f"  write: {'deny' if readonly else 'allow'}",
        "  bash:",
    ]

    bash_perms = {
        "*": "allow",
        "kill *": "deny",
        "pkill *": "deny",
        "killall *": "deny",
        "systemctl stop *": "deny",
        "systemctl --user stop *": "deny",
        "claude stop *": "deny",
        "claude kill *": "deny",
        "git push*": "ask",
        "git merge*": "ask",
        "gh pr create*": "ask",
        "gh pr merge*": "ask",
        "gh pr review*": "ask",
        "gh pr comment*": "ask",
        "gh issue create*": "ask",
        "gh issue close*": "ask",
        "gh issue comment*": "ask",
        "gh workflow run*": "ask",
    }

    if role_name in ("supreme-orchestrator", "architect", "reviewer", "scout"):
        bash_perms.update({
            "git commit*": "deny",
            "git merge*": "deny",
            "git rebase*": "deny",
            "git reset*": "deny",
            "git checkout*": "deny",
        })
    elif role_name == "team-orchestrator":
        bash_perms.update({
            "git commit*": "deny",
            "git merge*": "deny",
        })

    for cmd, action in bash_perms.items():
        lines.append(f'    "{cmd}": {action}')

    if not allowed_subagents:
        lines.append("  task: deny")
    else:
        lines.append("  task:")
        lines.append('    "*": deny')
        for sub in allowed_subagents:
            lines.append(f'    "{sub}": allow')

    if tools.get("question"):
        lines.append("  question: allow")
    lines.append("---")
    return "\n".join(lines)


_build_opencode_frontmatter = compile_opencode_frontmatter


def compile_claude_frontmatter(role_name: str, meta: Dict[str, Any], tier_models: Dict[str, Any]) -> str:
    tier = meta.get("tier", "workhorse")
    model = tier_models.get(tier, {}).get("claude", "sonnet")
    desc = meta.get("description", "").replace('"', '\\"')
    claude_tools = meta.get("claude_tools", "Read, Grep, Glob, Bash")

    tools_list = [t.strip() for t in claude_tools.split(",") if t.strip()]
    if role_name in ("scout", "grunt", "compaction", "summary"):
        tools_list = [t for t in tools_list if t != "Task"]
    elif role_name in ("supreme-orchestrator", "team-orchestrator", "architect", "worker", "tester", "reviewer"):
        if "Task" not in tools_list:
            tools_list.append("Task")
    claude_tools = ", ".join(tools_list)

    lines = [
        "---",
        f"name: {role_name}",
        f'description: "{desc}"',
        f"model: {model}",
        f"tools: {claude_tools}",
        "---",
    ]
    return "\n".join(lines)


def compile_agy_frontmatter(role_name: str, meta: Dict[str, Any], tier_models: Dict[str, Any]) -> str:
    tier = meta.get("tier", "workhorse")
    model = tier_models.get(tier, {}).get("agy", "flash")
    agy_id = tier_models.get(tier, {}).get("agy_model_id", "gemini-3.8-flash-medium")
    desc = meta.get("description", "").replace('"', '\\"')
    is_primary = (meta.get("mode") == "primary")
    readonly = meta.get("readonly", False)
    agy_tools = list(meta.get("agy_tools", ["read_file", "view_file", "grep_search", "find_by_name", "run_command", "send_message"]))

    # Enforce deterministic invariant filtering:
    # 1. Read-only roles must not have mutating tools
    mutating_tools = {"edit_file", "write_file", "replace_file_content", "write_to_file"}
    if readonly:
        agy_tools = [t for t in agy_tools if t not in mutating_tools]

    # 2. Leaf and utility roles must not have subagent-spawning tools, and must have send_message
    leaf_utility_roles = ("scout", "grunt", "compaction", "summary")
    spawning_tools = {"invoke_subagent", "manage_subagents"}
    if role_name in leaf_utility_roles:
        agy_tools = [t for t in agy_tools if t not in spawning_tools]
        if "send_message" not in agy_tools:
            agy_tools.append("send_message")

    tools_yaml = "\n".join(f"  - {t}" for t in agy_tools)

    lines = [
        "---",
        f"name: {role_name}",
        f"model: {model}",
        f'description: "{desc} Powered by Google Gemini 3.8 ({agy_id})."',
        "tools:",
        tools_yaml,
        f"mainAgent: {'true' if is_primary else 'false'}",
        f"subagent: {'false' if is_primary else 'true'}",
        "commandExecutionPolicy: auto",
        "---",
    ]
    return "\n".join(lines)


def compile_agents(
    core_dir: Path,
    target_runtime: str,
    output_dir: Path,
    model_profile: Optional[str] = None,
    primary_model: Optional[str] = None,
) -> List[Path]:
    manifest_path = core_dir / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Manifest not found at {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    tier_models = manifest.get("model_tiers", {})
    roles = manifest.get("roles", {})
    profiles = manifest.get("model_profiles", {})

    effective_model = primary_model or os.environ.get("SGLANG_PRIMARY_MODEL")
    effective_profile = model_profile or os.environ.get("SGLANG_MODEL_PROFILE") or os.environ.get("MODEL_PROFILE")

    if not effective_model and effective_profile:
        if effective_profile in profiles:
            effective_model = profiles[effective_profile].get("workhorse")
        elif effective_profile in ("qwen3.8-27b", "27b-nvfp4", "27b-q6"):
            effective_model = "local-sglang/qwen3.8-27b"
        elif effective_profile in ("ornith-1.5-35b", "ornith-35b"):
            effective_model = "ornith-local/ornith-1.5-35b"

    if not effective_model:
        default_prof_name = manifest.get("default_model_profile", "ornith-1.5-35b")
        if default_prof_name in profiles:
            effective_model = profiles[default_prof_name].get("workhorse")
        if not effective_model:
            effective_model = tier_models.get("workhorse", {}).get("opencode", "ornith-local/ornith-1.5-35b")

    output_dir.mkdir(parents=True, exist_ok=True)
    generated: List[Path] = []

    for role_name, meta in roles.items():
        if target_runtime == "opencode" and meta.get("opencode_skip"):
            continue

        src_file = core_dir / "agents" / f"{role_name}.md"
        if not src_file.is_file():
            continue

        body = extract_body(src_file)

        if target_runtime == "opencode":
            fm = compile_opencode_frontmatter(role_name, meta, tier_models, primary_model=effective_model)
        elif target_runtime == "claude":
            fm = compile_claude_frontmatter(role_name, meta, tier_models)
        elif target_runtime in ("agy", "gemini", "antigravity"):
            fm = compile_agy_frontmatter(role_name, meta, tier_models)
        else:
            raise ValueError(f"Unknown runtime: {target_runtime}")

        dest_file = output_dir / f"{role_name}.md"
        dest_file.write_text(f"{fm}\n\n{body}\n", encoding="utf-8")
        generated.append(dest_file)

    return generated


def main():
    parser = argparse.ArgumentParser(description="Deterministic Agent Frontmatter Compiler")
    parser.add_argument("--core-dir", default=None, help="Path to core/ directory")
    parser.add_argument("--runtime", required=True, choices=["opencode", "claude", "agy", "gemini", "antigravity"], help="Target runtime")
    parser.add_argument("--output-dir", required=True, help="Destination directory for compiled agents")
    parser.add_argument("--model-profile", default=None, help="Model profile override (e.g. qwen3.8-27b, ornith-1.5-35b)")
    parser.add_argument("--primary-model", default=None, help="Primary model override (e.g. local-sglang/qwen3.8-27b)")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent.parent
    core_dir = Path(args.core_dir).resolve() if args.core_dir else (repo_root / "core")
    output_dir = Path(args.output_dir).resolve()

    res = compile_agents(
        core_dir=core_dir,
        target_runtime=args.runtime,
        output_dir=output_dir,
        model_profile=args.model_profile,
        primary_model=args.primary_model,
    )
    print(f"Compiled {len(res)} agents for {args.runtime} -> {output_dir}")


if __name__ == "__main__":
    main()
