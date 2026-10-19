"""Deterministic Subagent Frontmatter Compiler for Multi-Runtime Agent Harness.

Compiles canonical markdown agent definitions from core/agents/*.md using metadata
from core/manifest.json into runtime-specific formats for OpenCode, Claude Code, and AGY.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List, Optional


def extract_body(agent_file: Path) -> str:
    """Extract markdown prompt body, stripping any pre-existing frontmatter."""
    content = agent_file.read_text(encoding="utf-8")
    if content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            return parts[2].lstrip()
    return content.lstrip()


def compile_opencode_frontmatter(role_name: str, meta: Dict[str, Any], tier_models: Dict[str, Any]) -> str:
    tier = meta.get("tier", "workhorse")
    model = tier_models.get(tier, {}).get("opencode", "ornith-local/ornith-1.5-35b")
    mode = meta.get("mode", "subagent")
    desc = meta.get("description", "").replace('"', '\\"')
    tools = meta.get("tools", {})
    readonly = meta.get("readonly", False)

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
        '    "*": allow',
        '    "gh pr merge*": ask',
        '    "git push --force*": ask',
        '    "git push * --force*": ask',
        "  task: allow",
    ]
    if tools.get("question"):
        lines.append("  question: allow")
    lines.append("---")
    return "\n".join(lines)


def compile_claude_frontmatter(role_name: str, meta: Dict[str, Any], tier_models: Dict[str, Any]) -> str:
    tier = meta.get("tier", "workhorse")
    model = tier_models.get(tier, {}).get("claude", "sonnet")
    desc = meta.get("description", "").replace('"', '\\"')
    claude_tools = meta.get("claude_tools", "Read, Grep, Glob, Bash")

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
    agy_tools = meta.get("agy_tools", ["view_file", "run_command"])

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
) -> List[Path]:
    manifest_path = core_dir / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Manifest not found at {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    tier_models = manifest.get("model_tiers", {})
    roles = manifest.get("roles", {})

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
            fm = compile_opencode_frontmatter(role_name, meta, tier_models)
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
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent.parent
    core_dir = Path(args.core_dir).resolve() if args.core_dir else (repo_root / "core")
    output_dir = Path(args.output_dir).resolve()

    res = compile_agents(core_dir=core_dir, target_runtime=args.runtime, output_dir=output_dir)
    print(f"Compiled {len(res)} agents for {args.runtime} -> {output_dir}")


if __name__ == "__main__":
    main()
