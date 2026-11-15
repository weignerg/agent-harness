"""Dynamic Model Router & Idle Unloader Proxy for SGLang.

Listens on a configurable proxy port (default 30000). Proxies OpenAI-compatible requests to internal SGLang backend (default 30001).
When a request asks for a model not currently active, it dynamically switches
the running systemd service unit to match the requested model from models_catalog.json,
rewrites the requested model name to the backend's served_model_name, and forwards the request.
Automatically stops the active model service after a configured idle duration to free VRAM.
"""
from __future__ import annotations

import argparse
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
import json
import logging
from pathlib import Path
import subprocess
import sys
import threading
import time
from typing import Any, Dict, List, Optional
import urllib.error
import urllib.request

logger = logging.getLogger("model_proxy")

DEFAULT_CATALOG_PATH = Path.home() / ".config/opencode-backends/models_catalog.json"
DEFAULT_IDLE_TIMEOUT_SECS = 900  # 15 minutes

DEFAULT_SERVED_NAMES: Dict[str, str] = {
    "sglang-qwen3.8-27b.service": "qwen3.8-27b",
    "sglang-ornith-1.5-35b.service": "ornith-1.5-35b",
    "sglang-ornith-1.5-9b.service": "ornith-1.5-9b",
    "opencode-sglang-qwen27b.service": "qwen3.8-27b",
    "opencode-sglang-ornith-35b.service": "ornith-1.5-35b",
    "ornith-30000.service": "ornith-1.5-35b",
    "ornith-1.5-9b-nvfp4-low-ctx.service": "ornith-1.5-9b",
}


class ModelRouter:
    def __init__(
        self,
        backend_host: str = "127.0.0.1",
        backend_port: int = 30001,
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
        self.model_to_served_name: Dict[str, str] = {}
        self.service_to_served_name: Dict[str, str] = dict(DEFAULT_SERVED_NAMES)

    def load_catalog(self) -> None:
        """Load and index models and their aliases from catalog."""
        fallback = Path(__file__).resolve().parents[2] / "config/models/models_catalog.json"
        if not self.catalog_path.exists() and fallback.exists():
            self.catalog_path = fallback

        if not self.catalog_path.exists():
            logger.warning("No model catalog found at %s", self.catalog_path)
            return

        with open(self.catalog_path, "r", encoding="utf-8") as f:
            self.catalog = json.load(f)

        # If a repo fallback catalog exists and has newer alias definitions (e.g. qwen3.8),
        # merge missing aliases / served_model_name / service_file updates cleanly.
        if fallback.exists() and fallback.resolve() != self.catalog_path.resolve():
            try:
                with open(fallback, "r", encoding="utf-8") as fb_f:
                    repo_cat = json.load(fb_f)
                legacy_key_map = {
                    "qwen-3.8-27b-nvfp4-med-ctx": "sglang-qwen3.8-27b",
                    "opencode-sglang-ornith-35b": "sglang-ornith-1.5-35b",
                    "ornith-1.5-9b-nvfp4-low-ctx": "sglang-ornith-1.5-9b",
                }
                for old_k, new_k in legacy_key_map.items():
                    if old_k in self.catalog and new_k in repo_cat and new_k not in self.catalog:
                        self.catalog[new_k] = self.catalog.pop(old_k)
                for mk, repo_info in repo_cat.items():
                    if mk not in self.catalog:
                        self.catalog[mk] = repo_info
                    else:
                        existing = self.catalog[mk]
                        merged_aliases = list(existing.get("aliases", []))
                        for a in repo_info.get("aliases", []):
                            if a not in merged_aliases:
                                merged_aliases.append(a)
                        existing["aliases"] = merged_aliases
                        if "served_model_name" in repo_info and "served_model_name" not in existing:
                            existing["served_model_name"] = repo_info["served_model_name"]
                        if "service_file" in repo_info:
                            existing["service_file"] = repo_info["service_file"]
            except Exception as e:
                logger.debug("Fallback catalog merge skipped: %s", e)

        self.alias_to_model.clear()
        self.model_to_service.clear()
        self.model_to_served_name.clear()
        self.service_to_served_name = dict(DEFAULT_SERVED_NAMES)

        for model_key, info in self.catalog.items():
            service_file = info.get("service_file", "")
            svc_name = Path(service_file).name if service_file else f"{model_key}.service"
            self.model_to_service[model_key] = svc_name

            served_name = info.get("served_model_name") or DEFAULT_SERVED_NAMES.get(svc_name) or info.get("name", model_key)
            self.model_to_served_name[model_key] = served_name
            self.service_to_served_name[svc_name] = served_name

            # Map key and all aliases (normalized lowercase, strip provider prefix)
            clean_key = self._normalize_model_id(model_key)
            self.alias_to_model[clean_key] = model_key
            for alias in info.get("aliases", []):
                clean_alias = self._normalize_model_id(str(alias))
                # Preserve first registration for shared aliases unless not yet registered
                if clean_alias not in self.alias_to_model or model_key in ("sglang-ornith-1.5-9b", "ornith-1.5-9b-nvfp4-low-ctx"):
                    self.alias_to_model[clean_alias] = model_key

    @staticmethod
    def _normalize_model_id(raw: str) -> str:
        clean = raw.lower().strip()
        for prefix in ("local-sglang/", "ornith-local/"):
            if clean.startswith(prefix):
                clean = clean[len(prefix):]
        return clean

    def resolve_model_service(self, requested_model: str) -> Optional[tuple[str, str]]:
        """Resolve a requested model string to (model_key, service_name)."""
        if not self.alias_to_model:
            self.load_catalog()

        clean = self._normalize_model_id(requested_model)
        if clean in self.alias_to_model:
            model_key = self.alias_to_model[clean]
            return model_key, self.model_to_service.get(model_key, f"{model_key}.service")

        # Fallback exact substring match
        for alias, model_key in sorted(self.alias_to_model.items(), key=lambda x: -len(x[0])):
            if alias in clean or clean in alias:
                return model_key, self.model_to_service.get(model_key, f"{model_key}.service")

        return None

    def resolve_served_model_name(
        self,
        requested_model: str,
        model_key: Optional[str] = None,
        service_name: Optional[str] = None,
    ) -> str:
        """Resolve the backend --served-model-name for a requested model or service."""
        if not self.alias_to_model:
            self.load_catalog()

        if model_key is None or service_name is None:
            resolved = self.resolve_model_service(requested_model)
            if resolved:
                model_key, service_name = resolved

        if service_name and service_name in self.service_to_served_name:
            return self.service_to_served_name[service_name]
        if model_key and model_key in self.model_to_served_name:
            return self.model_to_served_name[model_key]
        return self._normalize_model_id(requested_model)

    def get_catalog_models_payload(self) -> Dict[str, Any]:
        """Build an OpenAI-compatible /v1/models list covering catalog models and primary aliases."""
        if not self.catalog:
            self.load_catalog()

        seen_ids: set[str] = set()
        data: List[Dict[str, Any]] = []

        def _add_model(m_id: str, root_key: str) -> None:
            if not m_id or m_id in seen_ids:
                return
            seen_ids.add(m_id)
            data.append(
                {
                    "id": m_id,
                    "object": "model",
                    "created": 1700000000,
                    "owned_by": "local-sglang",
                    "root": root_key,
                }
            )

        for model_key, info in self.catalog.items():
            served = self.model_to_served_name.get(model_key, model_key)
            _add_model(served, model_key)
            _add_model(model_key, model_key)
            for alias in info.get("aliases", []):
                _add_model(str(alias), model_key)

        return {"object": "list", "data": data}

    def get_currently_running_service(self) -> Optional[str]:
        """Detect which sglang service unit is currently active via systemctl."""
        try:
            res = subprocess.run(
                [
                    "systemctl",
                    "--user",
                    "list-units",
                    "*sglang*",
                    "*ornith*",
                    "*qwen*",
                    "--state=active",
                    "--no-legend",
                    "--no-pager",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            for line in res.stdout.strip().splitlines():
                parts = line.split()
                if parts and (".service" in parts[0]) and ("model-proxy" not in parts[0]):
                    return parts[0]
        except Exception as e:
            logger.error("Failed to list active systemd units: %s", e)
        return None

    def ensure_service_running(self, target_service: str, timeout: float = 180.0) -> bool:
        """Switch or activate target_service if not running, and wait for readiness."""
        with self.lock:
            self.last_activity_time = time.time()
            current = self.get_currently_running_service()
            expected_served = self.service_to_served_name.get(target_service)
            if current == target_service:
                self.active_service = target_service
                return self.wait_for_backend_ready(timeout=timeout, expected_served_model=expected_served)

            logger.info("Switching active model service from %s to %s", current, target_service)

            # Stop conflicting sglang services
            services_to_stop = [
                "sglang-qwen3.8-27b.service",
                "sglang-ornith-1.5-35b.service",
                "sglang-ornith-1.5-9b.service",
                "opencode-sglang-qwen27b.service",
                "opencode-sglang-ornith-35b.service",
                "ornith-30000.service",
                "ornith-1.5-9b-nvfp4-low-ctx.service",
            ]
            if current and current not in services_to_stop:
                services_to_stop.append(current)

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
            return self.wait_for_backend_ready(timeout=timeout, expected_served_model=expected_served)

    def wait_for_backend_ready(self, timeout: float = 60.0, expected_served_model: Optional[str] = None) -> bool:
        """Poll backend /v1/models until ready and (if specified) serving expected_served_model."""
        url = f"http://{self.backend_host}:{self.backend_port}/v1/models"
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                req = urllib.request.Request(url, headers={"Authorization": "Bearer EMPTY"})
                with urllib.request.urlopen(req, timeout=1.0) as resp:
                    if resp.status == 200:
                        raw = resp.read().decode("utf-8", errors="ignore")
                        if expected_served_model:
                            try:
                                payload = json.loads(raw)
                                model_ids = {
                                    str(m.get("id", ""))
                                    for m in payload.get("data", [])
                                    if isinstance(m, dict)
                                }
                                if expected_served_model not in model_ids and expected_served_model not in raw:
                                    time.sleep(0.5)
                                    continue
                            except Exception:
                                if expected_served_model not in raw:
                                    time.sleep(0.5)
                                    continue
                        logger.info("Backend %s is ready", url)
                        return True
            except Exception:
                time.sleep(0.5)
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


class ModelProxyServer(ThreadingHTTPServer):
    """Threaded HTTP server carrying a ModelRouter instance."""

    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], router: ModelRouter, switch_timeout: float = 180.0):
        self.router = router
        self.switch_timeout = switch_timeout
        super().__init__(server_address, ModelProxyRequestHandler)


class ModelProxyRequestHandler(BaseHTTPRequestHandler):
    """HTTP reverse proxy handler that switches SGLang systemd services on demand."""

    protocol_version = "HTTP/1.1"

    @property
    def router(self) -> ModelRouter:
        return self.server.router  # type: ignore[attr-defined]

    @property
    def switch_timeout(self) -> float:
        return getattr(self.server, "switch_timeout", 180.0)

    def log_message(self, format: str, *args: Any) -> None:
        logger.debug("%s - %s", self.address_string(), format % args)

    def _send_json(self, status_code: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        try:
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        if self.path == "/health" or self.path.startswith("/health?"):
            active = self.router.active_service or self.router.get_currently_running_service()
            self._send_json(
                200,
                {
                    "status": "ok",
                    "active_service": active,
                    "backend": f"{self.router.backend_host}:{self.router.backend_port}",
                },
            )
            return

        if self.path == "/v1/models" or self.path.startswith("/v1/models?"):
            # Try querying active backend first; merge with catalog models so clients see all selectable aliases
            catalog_payload = self.router.get_catalog_models_payload()
            try:
                url = f"http://{self.router.backend_host}:{self.router.backend_port}/v1/models"
                req = urllib.request.Request(url, headers={"Authorization": "Bearer EMPTY"})
                with urllib.request.urlopen(req, timeout=1.5) as resp:
                    if resp.status == 200:
                        backend_data = json.loads(resp.read().decode("utf-8"))
                        existing_ids = {m.get("id") for m in backend_data.get("data", []) if isinstance(m, dict)}
                        for cat_m in catalog_payload.get("data", []):
                            if cat_m["id"] not in existing_ids:
                                backend_data.setdefault("data", []).append(cat_m)
                        self._send_json(200, backend_data)
                        return
            except Exception:
                pass

            self._send_json(200, catalog_payload)
            return

        self._forward_request("GET")

    def do_POST(self) -> None:
        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length) if content_length > 0 else b""

        if self.path.startswith("/v1/chat/completions") or self.path.startswith("/v1/completions"):
            if raw_body:
                try:
                    body_json = json.loads(raw_body.decode("utf-8"))
                except Exception:
                    body_json = None

                if isinstance(body_json, dict) and "model" in body_json:
                    requested_model = str(body_json["model"])
                    resolved = self.router.resolve_model_service(requested_model)
                    if resolved:
                        model_key, target_service = resolved
                        ok = self.router.ensure_service_running(target_service, timeout=self.switch_timeout)
                        if not ok:
                            self._send_json(
                                503,
                                {
                                    "error": {
                                        "message": f"Failed to activate backend service {target_service} for model '{requested_model}'",
                                        "type": "service_unavailable",
                                    }
                                },
                            )
                            return

                        served_name = self.router.resolve_served_model_name(
                            requested_model,
                            model_key=model_key,
                            service_name=target_service,
                        )
                        body_json["model"] = served_name
                        raw_body = json.dumps(body_json).encode("utf-8")

        self.router.last_activity_time = time.time()
        self._forward_request("POST", body=raw_body)

    def _forward_request(self, method: str, body: Optional[bytes] = None) -> None:
        conn = http.client.HTTPConnection(self.router.backend_host, self.router.backend_port, timeout=600)
        try:
            forward_headers: Dict[str, str] = {}
            for k, v in self.headers.items():
                if k.lower() in ("host", "content-length", "transfer-encoding", "connection"):
                    continue
                forward_headers[k] = v
            forward_headers["Host"] = f"{self.router.backend_host}:{self.router.backend_port}"
            if body is not None:
                forward_headers["Content-Length"] = str(len(body))

            conn.request(method, self.path, body=body, headers=forward_headers)
            resp = conn.getresponse()

            self.send_response(resp.status, resp.reason)
            is_chunked = False
            for hk, hv in resp.getheaders():
                if hk.lower() == "transfer-encoding" and "chunked" in hv.lower():
                    is_chunked = True
                if hk.lower() in ("connection", "transfer-encoding"):
                    continue
                self.send_header(hk, hv)
            self.send_header("Connection", "close")
            self.end_headers()

            if is_chunked or "text/event-stream" in (resp.getheader("Content-Type") or "").lower():
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    self.router.last_activity_time = time.time()
            else:
                data = resp.read()
                if data:
                    self.wfile.write(data)
                    self.wfile.flush()
        except Exception as e:
            logger.error("Error forwarding %s %s to backend: %s", method, self.path, e)
            try:
                self._send_json(
                    502,
                    {
                        "error": {
                            "message": f"Backend connection error: {e}",
                            "type": "bad_gateway",
                        }
                    },
                )
            except Exception:
                pass
        finally:
            conn.close()


def start_idle_checker(router: ModelRouter, interval: float = 30.0) -> threading.Thread:
    def _loop() -> None:
        while True:
            time.sleep(interval)
            try:
                router.check_idle_timeout()
            except Exception as e:
                logger.error("Error in idle checker loop: %s", e)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()
    return t


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Dynamic Model Router & Idle Unloader Proxy for SGLang")
    parser.add_argument("--listen-host", default="127.0.0.1", help="Host interface to bind proxy server")
    parser.add_argument("--listen-port", type=int, default=30000, help="Port to bind proxy server")
    parser.add_argument("--backend-host", default="127.0.0.1", help="Internal SGLang backend host")
    parser.add_argument("--backend-port", type=int, default=30001, help="Internal SGLang backend port")
    parser.add_argument(
        "--catalog-path",
        type=Path,
        default=DEFAULT_CATALOG_PATH,
        help="Path to models_catalog.json",
    )
    parser.add_argument(
        "--idle-timeout",
        type=int,
        default=DEFAULT_IDLE_TIMEOUT_SECS,
        help="Idle timeout in seconds before stopping active SGLang service (0 to disable)",
    )
    parser.add_argument(
        "--switch-timeout",
        type=float,
        default=180.0,
        help="Max seconds to wait for target SGLang service readiness on model switch",
    )
    parser.add_argument("--log-level", default="INFO", help="Logging verbosity level")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    router = ModelRouter(
        backend_host=args.backend_host,
        backend_port=args.backend_port,
        catalog_path=args.catalog_path,
        idle_timeout_seconds=args.idle_timeout,
    )
    router.load_catalog()
    start_idle_checker(router)

    server = ModelProxyServer((args.listen_host, args.listen_port), router, switch_timeout=args.switch_timeout)
    logger.info(
        "ModelRouter proxy listening on http://%s:%d -> backend http://%s:%d (idle_timeout=%ds)",
        args.listen_host,
        args.listen_port,
        args.backend_host,
        args.backend_port,
        args.idle_timeout,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down ModelRouter proxy server")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
