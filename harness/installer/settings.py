"""JSON configuration merge engine for multi-runtime harness distribution."""
from __future__ import annotations

import argparse
import copy
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, Union

from harness.runtime.claude_adapter import deep_merge


def merge_json_settings(base_settings: Dict[str, Any], *override_settings: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively merge base settings with one or more override dictionaries."""
    merged = copy.deepcopy(base_settings)
    for override in override_settings:
        merged = deep_merge(merged, override)
    return merged


def merge_claude_settings_file(
    user_settings_path: Union[str, Path],
    template_settings_path: Union[str, Path],
    output_path: Union[str, Path],
) -> Dict[str, Any]:
    """Merge Claude Code user settings with harness template settings.

    Harness template settings provide defaults (e.g. teammateMode, experimental env flags),
    while the user's existing settings override defaults to preserve custom configuration.
    """
    tmpl_p = Path(template_settings_path).resolve()
    user_p = Path(user_settings_path).resolve()
    out_p = Path(output_path).resolve()

    tmpl_data: Dict[str, Any] = {}
    if tmpl_p.is_file():
        try:
            with open(tmpl_p, "r", encoding="utf-8") as f:
                tmpl_data = json.load(f)
        except Exception:
            tmpl_data = {}

    user_data: Dict[str, Any] = {}
    if user_p.is_file():
        try:
            with open(user_p, "r", encoding="utf-8") as f:
                user_data = json.load(f)
        except Exception:
            user_data = {}

    # Merge: template defaults as base, user settings as override (preserving user custom config)
    merged = merge_json_settings(tmpl_data, user_data)

    out_p.parent.mkdir(parents=True, exist_ok=True)
    tmp_out = out_p.with_name(f"{out_p.name}.tmp.{os.getpid()}")
    try:
        with open(tmp_out, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=2)
            f.write("\n")
        os.replace(tmp_out, out_p)
    finally:
        if tmp_out.exists():
            try:
                tmp_out.unlink()
            except OSError:
                pass

    return merged


def _run_cli() -> None:
    parser = argparse.ArgumentParser(description="Settings Merge CLI")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    claude_p = subparsers.add_parser("merge-claude", help="Merge Claude Code settings")
    claude_p.add_argument("--user-settings", required=True, help="Path to existing user settings.json")
    claude_p.add_argument("--template-settings", required=True, help="Path to template core.json")
    claude_p.add_argument("--output", required=True, help="Destination settings.json path")

    args = parser.parse_args()
    if args.subcommand == "merge-claude":
        res = merge_claude_settings_file(
            user_settings_path=args.user_settings,
            template_settings_path=args.template_settings,
            output_path=args.output,
        )
        print(f"  ✅ Merged Claude settings written to {args.output}")
        sys.exit(0)


if __name__ == "__main__":
    _run_cli()
