from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
import urllib.request

from harness.orchestrator.model_proxy import ModelProxyServer, ModelRouter

REPO_CATALOG = Path(__file__).resolve().parents[1] / "config/models/models_catalog.json"


class _MockBackendHandler(BaseHTTPRequestHandler):
    last_request_body = None
    last_request_path = None

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/v1/models":
            body = json.dumps({"object": "list", "data": [{"id": "qwen3.8-27b", "object": "model"}]}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        _MockBackendHandler.last_request_path = self.path
        _MockBackendHandler.last_request_body = json.loads(raw.decode("utf-8"))

        resp_payload = {
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "model": _MockBackendHandler.last_request_body.get("model"),
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": "ok"},
                    "finish_reason": "stop",
                }
            ],
        }
        body = json.dumps(resp_payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class TestModelRouter(unittest.TestCase):
    def setUp(self):
        self.router = ModelRouter(catalog_path=REPO_CATALOG)
        self.router.load_catalog()

    def test_catalog_loaded(self):
        self.assertGreater(len(self.router.catalog), 0)

    def test_resolve_ornith_35b(self):
        res = self.router.resolve_model_service("ornith-1.5-35b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "opencode-sglang-ornith-35b")
        self.assertEqual(res[1], "opencode-sglang-ornith-35b.service")
        self.assertEqual(self.router.resolve_served_model_name("ornith-1.5-35b"), "ornith-1.5-35b")

    def test_resolve_ornith_9b(self):
        res = self.router.resolve_model_service("ornith-1.5-9b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "ornith-1.5-9b-nvfp4-low-ctx")
        self.assertEqual(res[1], "ornith-1.5-9b-nvfp4-low-ctx.service")

    def test_resolve_qwen_27b_and_aliases(self):
        for alias in ("qwen-3.8-27b", "qwen-3.8-nvfp4", "qwen3.8", "qwen3.8-27b", "qwen-3.8-q6", "local-sglang/qwen3.8"):
            res = self.router.resolve_model_service(alias)
            self.assertIsNotNone(res, f"Failed to resolve {alias}")
            self.assertEqual(res[0], "qwen-3.8-27b-nvfp4-med-ctx")
            self.assertEqual(res[1], "opencode-sglang-qwen27b.service")
            self.assertEqual(self.router.resolve_served_model_name(alias), "qwen3.8-27b")

    def test_resolve_with_provider_prefix(self):
        res = self.router.resolve_model_service("local-sglang/ornith-1.5-35b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "opencode-sglang-ornith-35b")

        res_ornith_prov = self.router.resolve_model_service("ornith-local/ornith-1.5-35b")
        self.assertIsNotNone(res_ornith_prov)
        self.assertEqual(res_ornith_prov[0], "opencode-sglang-ornith-35b")


class TestModelProxyServer(unittest.TestCase):
    def setUp(self):
        _MockBackendHandler.last_request_body = None
        _MockBackendHandler.last_request_path = None

        self.backend_server = HTTPServer(("127.0.0.1", 0), _MockBackendHandler)
        self.backend_port = self.backend_server.server_address[1]
        self.backend_thread = threading.Thread(target=self.backend_server.serve_forever, daemon=True)
        self.backend_thread.start()

        self.router = ModelRouter(
            backend_host="127.0.0.1",
            backend_port=self.backend_port,
            catalog_path=REPO_CATALOG,
            idle_timeout_seconds=900,
        )
        self.router.load_catalog()

        self.proxy_server = ModelProxyServer(("127.0.0.1", 0), self.router, switch_timeout=5.0)
        self.proxy_port = self.proxy_server.server_address[1]
        self.proxy_thread = threading.Thread(target=self.proxy_server.serve_forever, daemon=True)
        self.proxy_thread.start()

    def tearDown(self):
        self.proxy_server.shutdown()
        self.proxy_server.server_close()
        self.backend_server.shutdown()
        self.backend_server.server_close()

    def test_health_endpoint(self):
        with patch.object(self.router, "get_currently_running_service", return_value="opencode-sglang-qwen27b.service"):
            url = f"http://127.0.0.1:{self.proxy_port}/health"
            with urllib.request.urlopen(url, timeout=2.0) as resp:
                self.assertEqual(resp.status, 200)
                data = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(data["status"], "ok")
                self.assertEqual(data["active_service"], "opencode-sglang-qwen27b.service")

    def test_v1_models_endpoint_includes_catalog_aliases(self):
        url = f"http://127.0.0.1:{self.proxy_port}/v1/models"
        with urllib.request.urlopen(url, timeout=2.0) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode("utf-8"))
            self.assertEqual(data["object"], "list")
            model_ids = {m["id"] for m in data["data"]}
            self.assertIn("qwen3.8-27b", model_ids)
            self.assertIn("qwen-3.8-nvfp4", model_ids)
            self.assertIn("qwen3.8", model_ids)
            self.assertIn("ornith-1.5-35b", model_ids)

    def test_chat_completions_switches_service_and_rewrites_model_name(self):
        with patch.object(self.router, "ensure_service_running", return_value=True) as mock_ensure:
            url = f"http://127.0.0.1:{self.proxy_port}/v1/chat/completions"
            payload = {
                "model": "local-sglang/qwen-3.8-nvfp4",
                "messages": [{"role": "user", "content": "Hello"}],
            }
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                self.assertEqual(resp.status, 200)
                resp_data = json.loads(resp.read().decode("utf-8"))

            mock_ensure.assert_called_once_with("opencode-sglang-qwen27b.service", timeout=5.0)
            self.assertIsNotNone(_MockBackendHandler.last_request_body)
            self.assertEqual(_MockBackendHandler.last_request_body["model"], "qwen3.8-27b")
            self.assertEqual(resp_data["model"], "qwen3.8-27b")


if __name__ == "__main__":
    unittest.main()
