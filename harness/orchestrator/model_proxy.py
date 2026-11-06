"""Dynamic Model Router & Idle Unloader Proxy for SGLang.

Listens on port 30000. Proxies OpenAI-compatible requests to internal SGLang backend.
When a request asks for a model not currently active, it dynamically switches
the running systemd service unit to match the requested model from models_catalog.json.
Automatically stops the active model service after a configured idle duration to free VRAM.
"""
from __future__ import annotations

import argparse
import asyncio
import http.client
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import logging
from pathlib import Path
import subprocess
import sys
import threading
import time
from typing import Any, Dict, Optional
import urllib.request
import urllib.error

logger = logging.getLogger("model_proxy")

DEFAULT_CATALOG_PATH = Path.home() / ".config/opencode-backends/models_catalog.json"
DEFAULT_IDLE_TIMEOUT_SECS = 900  # 15 minutes


class ModelRouter:
    def __init__(
        self,
        backend_host: str = "127.0.0.1",
        backend_port: int = 30000,
        catalog_path: Path = DEFAULT_CATALOG_PATH,
        idle_timeout_seconds: int = DEFAULT_IDLE_TIMEOUT_SECS,
    ):
        self.backend_host = backend_host
        self.backend_port = backend_port
        self.catalog_path = catalog_path
        self.idle_timeout_seconds = idle_timeout_seconds

        self.active_service: Optional[str] = None
        self.last_activity_time = time.time()
        self.lock = threading.Lock()
        self.catalog: Dict[str, Any] = {}
        self.alias_to_model: Dict[str, str] = {}
        self.model_to_service: Dict[str, str] = {}

    def load_catalog(self) -> None:
        """Load and index models and their aliases from catalog."""
        if not self.catalog_path.exists():
            fallback = Path(__file__).resolve().parents[2] / "config/models/models_catalog.json"
            if fallback.exists():
                self.catalog_path = fallback

        if not self.catalog_path.exists():
            logger.warning("No model catalog found at %s", self.catalog_path)
            return

        with open(self.catalog_path, "r", encoding="utf-8") as f:
            self.catalog = json.load(f)

        self.alias_to_model.clear()
        self.model_to_service.clear()

        for model_key, info in self.catalog.items():
            service_file = info.get("service_file", "")
            svc_name = Path(service_file).name if service_file else f"{model_key}.service"
            self.model_to_service[model_key] = svc_name

            # Map key and all aliases (normalized lowercase, strip local-sglang/ prefix)
            clean_key = model_key.lower().replace("local-sglang/", "")
            self.alias_to_model[clean_key] = model_key
            for alias in info.get("aliases", []):
                clean_alias = str(alias).lower().replace("local-sglang/", "")
                self.alias_to_model[clean_alias] = model_key

    def resolve_model_service(self, requested_model: str) -> Optional[tuple[str, str]]:
        """Resolve a requested model string to (model_key, service_name)."""
        clean = requested_model.lower().strip().replace("local-sglang/", "")
        if clean in self.alias_to_model:
            model_key = self.alias_to_model[clean]
            return model_key, self.model_to_service.get(model_key, f"{model_key}.service")

        # Fallback exact substring match
        for alias, model_key in sorted(self.alias_to_model.items(), key=lambda x: -len(x[0])):
            if alias in clean or clean in alias:
                return model_key, self.model_to_service.get(model_key, f"{model_key}.service")

        return None

    def get_currently_running_service(self) -> Optional[str]:
        """Detect which sglang service unit is currently active via systemctl."""
        try:
            res = subprocess.run(
                ["systemctl", "--user", "list-units", "*sglang*", "*ornith*", "*qwen*", "--state=active", "--no-legend", "--no-pager"],
                capture_output=True,
                text=True,
                check=False,
            )
            for line in res.stdout.strip().splitlines():
                parts = line.split()
                if parts and (".service" in parts[0]):
                    return parts[0]
        except Exception as e:
            logger.error("Failed to list active systemd units: %s", e)
        return None

    def ensure_service_running(self, target_service: str, timeout: float = 60.0) -> bool:
        """Switch or activate target_service if not running, and wait for readiness."""
        with self.lock:
            self.last_activity_time = time.time()
            current = self.get_currently_running_service()
            if current == target_service:
                self.active_service = target_service
                return True

            logger.info("Switching active model service from %s to %s", current, target_service)

            # Stop conflicting sglang services
            services_to_stop = [
                "opencode-sglang-qwen27b.service",
                "opencode-sglang-ornith-35b.service",
                "ornith-30000.service",
                "qwen-3.8-27b-nvfp4-med-ctx.service",
            ]
            for s in services_to_stop:
                if s != target_service:
                    subprocess.run(["systemctl", "--user", "stop", s], check=False, capture_output=True)

            # Start target service
            start_res = subprocess.run(
                ["systemctl", "--user", "start", target_service],
                check=False,
                capture_output=True,
                text=True,
            )
            if start_res.returncode != 0:
                logger.error("Failed to start %s: %s", target_service, start_res.stderr)
                return False

            self.active_service = target_service
            return self.wait_for_backend_ready(timeout=timeout)

    def wait_for_backend_ready(self, timeout: float = 60.0) -> bool:
        """Poll backend /v1/models until ready."""
        url = f"http://{self.backend_host}:{self.backend_port}/v1/models"
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                req = urllib.request.Request(url, headers={"Authorization": "Bearer EMPTY"})
                with urllib.request.urlopen(req, timeout=1.0) as resp:
                    if resp.status == 200:
                        logger.info("Backend %s is ready", url)
                        return True
            except Exception:
                time.sleep(1.0)
        logger.warning("Backend timed out waiting for readiness at %s", url)
        return False

    def check_idle_timeout(self) -> None:
        """Unload service if idle duration exceeds idle_timeout_seconds."""
        if self.idle_timeout_seconds <= 0:
            return

        with self.lock:
            idle_duration = time.time() - self.last_activity_time
            if idle_duration > self.idle_timeout_seconds:
                current = self.get_currently_running_service()
                if current:
                    logger.info(
                        "Idle timeout reached (%ds > %ds). Unloading %s to free GPU VRAM.",
                        int(idle_duration),
                        self.idle_timeout_seconds,
                        current,
                    )
                    subprocess.run(["systemctl", "--user", "stop", current], check=False, capture_output=True)
                    self.active_service = None
                    self.last_activity_time = time.time()


def start_idle_checker(router: ModelRouter, interval: float = 30.0) -> None:
    def _loop():
        while True:
            time.sleep(interval)
            try:
                router.check_idle_timeout()
            except Exception as e:
                logger.error("Error in idle checker loop: %s", e)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()
