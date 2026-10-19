"""Configuration synchronization and runtime integration for multi-runtime agent harness.

Ensures deterministic, schema-accurate configuration for:
- OpenCode (~/.config/opencode/opencode.json)
- Claude Code (~/.claude.json and ~/.claude/settings.json)
- Google Antigravity (~/.gemini/GEMINI.md, ~/.gemini/config/mcp_config.json, settings.json)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Union


def atomic_write_json(path: Path, data: Any, indent: int = 2) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=indent)
            f.write("\n")
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass


def sync_gemini_md(
    gemini_md_path: Union[str, Path],
    charter_path: Optional[Union[str, Path]] = None,
    rules_dir: Optional[Union[str, Path]] = None,
    template_path: Optional[Union[str, Path]] = None,
) -> None:
    """Inject compact AGY-specific system configuration and global charter link into GEMINI.md.

    Prevents 24KB truncation and context duplication by linking modular rules into
    ~/.gemini/config/rules/ and ~/.gemini/antigravity-cli/rules/ rather than inlining them directly into GEMINI.md.
    """
    gem_p = Path(gemini_md_path).expanduser().resolve()

    template_text = ""
    if template_path:
        t_path = Path(template_path).expanduser().resolve()
        if t_path.is_file():
            template_text = t_path.read_text(encoding="utf-8").strip()

    if not template_text and charter_path:
        charter_p = Path(charter_path).expanduser().resolve()
        repo_root = charter_p.parent.parent
        t_path = repo_root / "templates" / "agy" / "GEMINI.md"
        if t_path.is_file():
            template_text = t_path.read_text(encoding="utf-8").strip()

    if not template_text:
        default_tpl = Path(__file__).resolve().parent.parent.parent / "templates" / "agy" / "GEMINI.md"
        if default_tpl.is_file():
            template_text = default_tpl.read_text(encoding="utf-8").strip()

    if not template_text:
        template_text = (
            "# Antigravity (AGY) AI Agent System Charter & Instructions\n\n"
            "You are an autonomous AI software engineer operating inside the **Antigravity (`agy`) Agent Harness**, "
            "powered by official **Google Gemini 3.8** models across High, Medium, and Low reasoning effort tiers "
            "and the two-tier agent team hierarchy.\n\n"
            "<!-- HARDWARE_ARCHITECTURE_START -->\n"
            "- **Host OS**: Linux (CachyOS / Linux workstation)\n"
            "- **Local Inference Engine**: Local SGLang Engine on `http://127.0.0.1:30000/v1`\n"
            "- **Primary & Orchestration Tier (Gemini 3.8 High)**: `gemini-3.8-flash-high` (`model: pro`)\n"
            "- **Implementation & Verification Tier (Gemini 3.8 Medium)**: `gemini-3.8-flash-medium` (`model: flash`)\n"
            "- **Fast Atomic Leaf Tier (Gemini 3.8 Low)**: `gemini-3.8-flash-low` (`model: flash_lite`)\n"
            "<!-- HARDWARE_ARCHITECTURE_END -->\n\n"
            "@[global-agents-charter](~/.gemini/AGENTS.md)\n\n"
            "## 🛡️ Operational Rules\n"
            "Modular rules with `trigger: always_on` are loaded from `~/.gemini/config/rules/*.md` "
            "and `~/.gemini/antigravity-cli/rules/*.md`."
        )

    charter_import = "@[global-agents-charter](~/.gemini/AGENTS.md)"
    if charter_import not in template_text:
        template_text = f"{template_text}\n\n{charter_import}"

    begin_marker = "<!-- BEGIN AGENT-HARNESS -->"
    end_marker = "<!-- END AGENT-HARNESS -->"

    block_lines = [
        begin_marker,
        "<!-- Auto-managed by agent-harness. Do not edit content inside this block directly. -->",
        "",
        template_text,
        "",
        end_marker,
    ]
    managed_block = "\n".join(block_lines)

    existing_content = ""
    if gem_p.is_file():
        existing_content = gem_p.read_text(encoding="utf-8")

    pattern = re.compile(
        rf"{re.escape(begin_marker)}.*?{re.escape(end_marker)}",
        re.DOTALL,
    )

    if pattern.search(existing_content):
        updated_content = pattern.sub(lambda _: managed_block, existing_content)
    else:
        if existing_content.strip():
            updated_content = f"{existing_content.rstrip()}\n\n{managed_block}\n"
        else:
            updated_content = f"{managed_block}\n"

    gem_p.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = gem_p.with_name(f"{gem_p.name}.tmp.{os.getpid()}")
    try:
        tmp_path.write_text(updated_content, encoding="utf-8")
        os.replace(tmp_path, gem_p)
    finally:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass


def sync_opencode_json(
    opencode_json_path: Union[str, Path],
    repo_dir: Union[str, Path],
    py_bin: Union[str, Path],
    orch_dir: Union[str, Path],
    opencode_dir: Union[str, Path],
    vault_path: Optional[Union[str, Path]] = None,
) -> Dict[str, Any]:
    """Configure ~/.config/opencode/opencode.json with exact schema and zero double-ingestion."""
    op_path = Path(opencode_json_path).expanduser().resolve()
    repo_p = Path(repo_dir).expanduser().resolve()
    py_p = Path(os.path.abspath(os.path.expanduser(str(py_bin))))
    orch_p = Path(orch_dir).expanduser().resolve()
    oc_p = Path(opencode_dir).expanduser().resolve()
    v_p = Path(vault_path).expanduser().resolve() if vault_path else (Path.home() / "Vaults" / "home").resolve()

    data: Dict[str, Any] = {}
    if op_path.is_file():
        try:
            with open(op_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {}

    if not isinstance(data, dict):
        data = {}

    # 1. Instructions: strictly rule globs only (AGENTS.md is auto-discovered natively by OpenCode)
    data["instructions"] = [f"{oc_p}/rules/*.md"]
    data["default_agent"] = "supreme-orchestrator"

    # 2. System agent routing (compaction, summary, title) to avoid subagent collisions
    agent_routing = data.setdefault("agent", {})
    agent_routing["compaction"] = {"model": "ornith-local/ornith-1.5-9b"}
    agent_routing["summary"] = {"model": "ornith-local/ornith-1.5-9b"}
    agent_routing["title"] = {"model": "ornith-local/ornith-1.5-9b"}

    # 3. Exact OpenCode MCP schema: "mcp", "type": "local", "command": [list], "environment": {dict}
    mcp = data.setdefault("mcp", {})
    mcp["vault-memory"] = {
        "type": "local",
        "command": [
            str(py_p),
            "-m",
            "harness.mcp.vault_server",
        ],
        "environment": {
            "PYTHONPATH": str(repo_p),
            "ORCHESTRATION_ROOT": str(orch_p),
            "OBSIDIAN_VAULT_PATH": str(v_p),
            "TOKENIZERS_PARALLELISM": "false",
            "TQDM_DISABLE": "1",
        },
        "enabled": True,
    }
    mcp["worktree-manager"] = {
        "type": "local",
        "command": [
            str(py_p),
            "-m",
            "harness.mcp.worktree_server",
        ],
        "environment": {
            "PYTHONPATH": str(repo_p),
            "ORCHESTRATION_ROOT": str(orch_p),
        },
        "enabled": True,
    }

    atomic_write_json(op_path, data)
    return data


def sync_claude_json(
    claude_json_path: Union[str, Path],
    repo_dir: Union[str, Path],
    py_bin: Union[str, Path],
    orch_dir: Union[str, Path],
    vault_path: Optional[Union[str, Path]] = None,
) -> Dict[str, Any]:
    """Configure ~/.claude.json with exact mcpServers schema without destroying other keys."""
    cl_path = Path(claude_json_path).expanduser().resolve()
    repo_p = Path(repo_dir).expanduser().resolve()
    py_p = Path(os.path.abspath(os.path.expanduser(str(py_bin))))
    orch_p = Path(orch_dir).expanduser().resolve()
    v_p = Path(vault_path).expanduser().resolve() if vault_path else (Path.home() / "Vaults" / "home").resolve()

    data: Dict[str, Any] = {}
    if cl_path.is_file():
        try:
            with open(cl_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {}

    if not isinstance(data, dict):
        data = {}

    mcp_servers = data.setdefault("mcpServers", {})
    mcp_servers["vault-memory"] = {
        "command": str(py_p),
        "args": [
            "-m",
            "harness.mcp.vault_server",
        ],
        "env": {
            "PYTHONPATH": str(repo_p),
            "ORCHESTRATION_ROOT": str(orch_p),
            "OBSIDIAN_VAULT_PATH": str(v_p),
            "TOKENIZERS_PARALLELISM": "false",
            "TQDM_DISABLE": "1",
        },
    }
    mcp_servers["worktree-manager"] = {
        "command": str(py_p),
        "args": [
            "-m",
            "harness.mcp.worktree_server",
        ],
        "env": {
            "PYTHONPATH": str(repo_p),
            "ORCHESTRATION_ROOT": str(orch_p),
        },
    }

    atomic_write_json(cl_path, data)
    return data


def sync_agy_mcp_config(
    mcp_config_path: Union[str, Path],
    repo_dir: Union[str, Path],
    py_bin: Union[str, Path],
    orch_dir: Union[str, Path],
    vault_path: Optional[Union[str, Path]] = None,
) -> Dict[str, Any]:
    """Configure ~/.gemini/config/mcp_config.json and ~/.gemini/antigravity/mcp_config.json with exact mcpServers schema."""
    mcp_path = Path(mcp_config_path).expanduser().resolve()
    repo_p = Path(repo_dir).expanduser().resolve()
    py_p = Path(os.path.abspath(os.path.expanduser(str(py_bin))))
    orch_p = Path(orch_dir).expanduser().resolve()
    v_p = Path(vault_path).expanduser().resolve() if vault_path else (Path.home() / "Vaults" / "home").resolve()

    def _update_file(target: Path) -> Dict[str, Any]:
        data: Dict[str, Any] = {}
        if target.is_file():
            try:
                with open(target, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                data = {}

        if not isinstance(data, dict):
            data = {}

        mcp_servers = data.setdefault("mcpServers", {})
        mcp_servers["vault-memory"] = {
            "command": str(py_p),
            "args": [
                "-m",
                "harness.mcp.vault_server",
            ],
            "env": {
                "PYTHONPATH": str(repo_p),
                "ORCHESTRATION_ROOT": str(orch_p),
                "OBSIDIAN_VAULT_PATH": str(v_p),
                "TOKENIZERS_PARALLELISM": "false",
                "TQDM_DISABLE": "1",
            },
        }
        mcp_servers["worktree-manager"] = {
            "command": str(py_p),
            "args": [
                "-m",
                "harness.mcp.worktree_server",
            ],
            "env": {
                "PYTHONPATH": str(repo_p),
                "ORCHESTRATION_ROOT": str(orch_p),
            },
        }

        atomic_write_json(target, data)
        return data

    res = _update_file(mcp_path)

    # Sync twin path between ~/.gemini/config and ~/.gemini/antigravity
    twin_path: Optional[Path] = None
    if mcp_path.parent.name == "config" and mcp_path.parent.parent.name == ".gemini":
        twin_path = mcp_path.parent.parent / "antigravity" / mcp_path.name
    elif mcp_path.parent.name == "antigravity" and mcp_path.parent.parent.name == ".gemini":
        twin_path = mcp_path.parent.parent / "config" / mcp_path.name

    if twin_path is not None:
        _update_file(twin_path)

    return res


def sync_agy_settings(
    settings_path: Union[str, Path],
    repo_dir: Union[str, Path],
    orch_dir: Union[str, Path],
) -> Dict[str, Any]:
    """Ensure trustedWorkspaces in ~/.gemini/antigravity-cli/settings.json and ~/.gemini/settings.json includes repo and orch."""
    st_path = Path(settings_path).expanduser().resolve()
    repo_p = str(Path(repo_dir).expanduser().resolve())
    orch_p = str(Path(orch_dir).expanduser().resolve())

    def _update_settings(target: Path) -> Dict[str, Any]:
        data: Dict[str, Any] = {}
        if target.is_file():
            try:
                with open(target, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                data = {}

        if not isinstance(data, dict):
            data = {}

        workspaces = data.setdefault("trustedWorkspaces", [])
        if isinstance(workspaces, list):
            if repo_p not in workspaces:
                workspaces.append(repo_p)
            if orch_p not in workspaces:
                workspaces.append(orch_p)

        atomic_write_json(target, data)
        return data

    res = _update_settings(st_path)

    # Sync twin path between ~/.gemini/antigravity-cli/settings.json and ~/.gemini/settings.json
    twin_settings: Optional[Path] = None
    if st_path.parent.name == "antigravity-cli" and st_path.parent.parent.name == ".gemini":
        twin_settings = st_path.parent.parent / "settings.json"
    elif st_path.name == "settings.json" and st_path.parent.name == ".gemini":
        twin_settings = st_path.parent / "antigravity-cli" / "settings.json"

    if twin_settings is not None:
        _update_settings(twin_settings)

    return res


def main() -> None:
    parser = argparse.ArgumentParser(description="Multi-Runtime Config Sync CLI")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # sync-gemini
    p_gem = subparsers.add_parser("sync-gemini", help="Inject charter & rules into GEMINI.md")
    p_gem.add_argument("--gemini-md", required=True, help="Path to GEMINI.md")
    p_gem.add_argument("--charter", default=None, help="Path to CHARTER.md")
    p_gem.add_argument("--rules-dir", default=None, help="Path to rules/ directory")
    p_gem.add_argument("--template", default=None, help="Path to template GEMINI.md")

    # sync-opencode
    p_oc = subparsers.add_parser("sync-opencode", help="Update opencode.json")
    p_oc.add_argument("--opencode-json", required=True, help="Path to opencode.json")
    p_oc.add_argument("--repo-dir", required=True, help="Harness repo directory")
    p_oc.add_argument("--py-bin", required=True, help="Python binary path")
    p_oc.add_argument("--orch-dir", required=True, help="Orchestration directory")
    p_oc.add_argument("--opencode-dir", required=True, help="OpenCode home/target directory")
    p_oc.add_argument("--vault-path", default=None, help="Obsidian vault path")

    # sync-claude
    p_cl = subparsers.add_parser("sync-claude", help="Update ~/.claude.json mcpServers")
    p_cl.add_argument("--claude-json", required=True, help="Path to ~/.claude.json")
    p_cl.add_argument("--repo-dir", required=True, help="Harness repo directory")
    p_cl.add_argument("--py-bin", required=True, help="Python binary path")
    p_cl.add_argument("--orch-dir", required=True, help="Orchestration directory")
    p_cl.add_argument("--vault-path", default=None, help="Obsidian vault path")

    # sync-agy-mcp
    p_agy_mcp = subparsers.add_parser("sync-agy-mcp", help="Update mcp_config.json")
    p_agy_mcp.add_argument("--mcp-config", required=True, help="Path to mcp_config.json")
    p_agy_mcp.add_argument("--repo-dir", required=True, help="Harness repo directory")
    p_agy_mcp.add_argument("--py-bin", required=True, help="Python binary path")
    p_agy_mcp.add_argument("--orch-dir", required=True, help="Orchestration directory")
    p_agy_mcp.add_argument("--vault-path", default=None, help="Obsidian vault path")

    # sync-agy-settings
    p_agy_st = subparsers.add_parser("sync-agy-settings", help="Update AGY settings.json")
    p_agy_st.add_argument("--settings-path", required=True, help="Path to settings.json")
    p_agy_st.add_argument("--repo-dir", required=True, help="Harness repo directory")
    p_agy_st.add_argument("--orch-dir", required=True, help="Orchestration directory")

    args = parser.parse_args()

    if args.subcommand == "sync-gemini":
        sync_gemini_md(args.gemini_md, args.charter, args.rules_dir, args.template)
        print(f"  ✅ Synced GEMINI.md managed block -> {args.gemini_md}")
    elif args.subcommand == "sync-opencode":
        sync_opencode_json(
            args.opencode_json,
            args.repo_dir,
            args.py_bin,
            args.orch_dir,
            args.opencode_dir,
            args.vault_path,
        )
        print(f"  ✅ Configured OpenCode JSON -> {args.opencode_json}")
    elif args.subcommand == "sync-claude":
        sync_claude_json(
            args.claude_json,
            args.repo_dir,
            args.py_bin,
            args.orch_dir,
            args.vault_path,
        )
        print(f"  ✅ Configured Claude JSON -> {args.claude_json}")
    elif args.subcommand == "sync-agy-mcp":
        sync_agy_mcp_config(
            args.mcp_config,
            args.repo_dir,
            args.py_bin,
            args.orch_dir,
            args.vault_path,
        )
        print(f"  ✅ Configured AGY MCP config -> {args.mcp_config}")
    elif args.subcommand == "sync-agy-settings":
        sync_agy_settings(
            args.settings_path,
            args.repo_dir,
            args.orch_dir,
        )
        print(f"  ✅ Updated AGY settings -> {args.settings_path}")


if __name__ == "__main__":
    main()
