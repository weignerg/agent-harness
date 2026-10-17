"""Dynamic tool discovery, PEP 723 inline script execution via uv run, and parallel batching."""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

class EphemeralToolRunner:
    """Runs specialized tools in ephemeral sub-environments using `uv run` with PEP 723 metadata."""

    def __init__(self, uv_bin: str = "uv"):
        self.uv_bin = uv_bin

    def run_ephemeral_script(self, script_content: str, input_data: Dict[str, Any], timeout: float = 30.0) -> Dict[str, Any]:
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
            f.write(script_content)
            script_path = f.name

        try:
            cmd = [self.uv_bin, "run", "--no-project", script_path]
            proc = subprocess.run(
                cmd,
                input=json.dumps(input_data),
                capture_output=True,
                text=True,
                timeout=timeout
            )
            if proc.returncode != 0:
                return {
                    "ok": False,
                    "error": f"Tool execution failed (code {proc.returncode}): {proc.stderr.strip()}",
                    "stdout": proc.stdout
                }
            try:
                res = json.loads(proc.stdout)
                return {"ok": True, "result": res}
            except json.JSONDecodeError:
                return {"ok": True, "result": proc.stdout.strip()}
        except Exception as exc:
            return {"ok": False, "error": str(exc)}
        finally:
            if os.path.exists(script_path):
                os.remove(script_path)

class DynamicToolRegistry:
    """Manages core vs dynamic specialized tools and executes parallel batch tool calls."""

    def __init__(self):
        self.core_tools: Dict[str, Callable] = {}
        self.dynamic_tools: Dict[str, Dict[str, Any]] = {}
        self.runner = EphemeralToolRunner()

    def register_core_tool(self, name: str, func: Callable):
        self.core_tools[name] = func

    def register_dynamic_tool(self, name: str, script_template: str, dependencies: Optional[List[str]] = None):
        deps = dependencies or []
        dep_str = ", ".join(f'"{d}"' for d in deps)
        pep723_header = f"""# /// script
# requires-python = ">=3.11"
# dependencies = [{dep_str}]
# ///
"""
        full_script = pep723_header + "\n" + script_template
        self.dynamic_tools[name] = {
            "script": full_script,
            "dependencies": deps
        }

    async def call_tool_async(self, name: str, kwargs: Dict[str, Any]) -> Any:
        if name in self.core_tools:
            func = self.core_tools[name]
            if asyncio.iscoroutinefunction(func):
                return await func(**kwargs)
            else:
                return await asyncio.to_thread(func, **kwargs)
        elif name in self.dynamic_tools:
            tool_spec = self.dynamic_tools[name]
            loop = asyncio.get_running_loop()
            return await loop.run_in_executor(
                None,
                self.runner.run_ephemeral_script,
                tool_spec["script"],
                kwargs
            )
        else:
            raise KeyError(f"Unknown tool: {name}")

    async def batch_call_tools(self, calls: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """Executes a list of tool invocations concurrently. Each item must have 'name' and 'kwargs'."""
        tasks = [self.call_tool_async(call["name"], call.get("kwargs", {})) for call in calls]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        aggregated = []
        for call, res in zip(calls, results):
            if isinstance(res, Exception):
                aggregated.append({
                    "name": call["name"],
                    "ok": False,
                    "error": str(res)
                })
            elif isinstance(res, dict) and "ok" in res:
                aggregated.append({
                    "name": call["name"],
                    **res
                })
            else:
                aggregated.append({
                    "name": call["name"],
                    "ok": True,
                    "result": res
                })
        return aggregated
