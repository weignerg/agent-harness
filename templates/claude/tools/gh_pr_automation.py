"""GitHub Draft PR automation, comment responder, consolidated review formatting, and CI failure log analyzer."""
from __future__ import annotations

import json
import re
import subprocess
from typing import Any, Dict, List, Optional


class GitHubPRAutomation:
    def __init__(self, gh_bin: str = "gh"):
        self.gh_bin = gh_bin

    def create_draft_pr(self, title: str, body: str, base: str = "develop") -> str:
        cmd = [self.gh_bin, "pr", "create", "--draft", "--base", base, "--title", title, "--body", body]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return proc.stdout.strip()

    def parse_ci_log_failures(self, log_text: str) -> List[Dict[str, str]]:
        failures = []
        pattern = re.compile(r"(FAIL|ERROR):\s+(test_[a-zA-Z0-9_]+)\s+\((.*?)\)")
        for match in pattern.finditer(log_text):
            failures.append({
                "type": match.group(1),
                "test": match.group(2),
                "module": match.group(3)
            })
        return failures

    def reply_to_comment(self, pr_number: int, comment_body: str) -> bool:
        cmd = [self.gh_bin, "pr", "comment", str(pr_number), "--body", comment_body]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        return proc.returncode == 0

    def format_consolidated_response(
        self,
        round_label: str,
        commit_sha: str,
        findings: List[Dict[str, Any]],
        pr_overview_url: str = ""
    ) -> str:
        """Generate a structured multi-round consolidated response comment."""
        lines = [
            f"**{round_label} — addressed in commit `{commit_sha[:7]}`**\n"
        ]
        severity_order = ["BLOCKER", "MUST_FIX", "WARNING", "BEST_PRACTICE"]
        severity_icons = {
            "BLOCKER": "🔴",
            "MUST_FIX": "🟠",
            "WARNING": "🟡",
            "BEST_PRACTICE": "🟢"
        }

        for sev in severity_order:
            sev_items = [f for f in findings if f.get("severity") == sev or (sev == "BLOCKER" and f.get("blocking"))]
            if sev_items:
                icon = severity_icons.get(sev, "⚪")
                lines.append(f"**{icon} {sev}**")
                for item in sev_items:
                    cid = item.get("comment_id", "")
                    link = f"{pr_overview_url}?commentId={cid}" if (pr_overview_url and cid) else ""
                    summary = item.get("summary") or item.get("message") or "addressed"
                    bullet = f"- {icon} {sev}: [{summary}]({link})" if link else f"- {icon} {sev}: {summary}"
                    lines.append(bullet)
                    if item.get("details"):
                        lines.append(f"  - {item['details']}")
                lines.append("")
        return "\n".join(lines).strip()
