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
        self.assertEqual(res[0], "sglang-ornith-1.5-35b")
        self.assertEqual(res[1], "sglang-ornith-1.5-35b.service")
        self.assertEqual(self.router.resolve_served_model_name("ornith-1.5-35b"), "ornith-1.5-35b")

    def test_resolve_ornith_9b(self):
        res = self.router.resolve_model_service("ornith-1.5-9b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "sglang-ornith-1.5-9b")
        self.assertEqual(res[1], "sglang-ornith-1.5-9b.service")
        self.assertEqual(self.router.resolve_served_model_name("ornith-1.5-9b"), "ornith-1.5-9b")

    def test_resolve_qwen_27b_and_aliases(self):
        for alias in ("qwen-3.8-27b", "qwen-3.8-nvfp4", "qwen3.8", "qwen3.8-27b", "qwen-3.8-q6", "local-sglang/qwen3.8"):
            res = self.router.resolve_model_service(alias)
            self.assertIsNotNone(res, f"Failed to resolve {alias}")
            self.assertEqual(res[0], "sglang-qwen3.8-27b")
            self.assertEqual(res[1], "sglang-qwen3.8-27b.service")
            self.assertEqual(self.router.resolve_served_model_name(alias), "qwen3.8-27b")

    def test_resolve_with_provider_prefix(self):
        res = self.router.resolve_model_service("local-sglang/ornith-1.5-35b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "sglang-ornith-1.5-35b")

        res_ornith_prov = self.router.resolve_model_service("ornith-local/ornith-1.5-35b")
        self.assertIsNotNone(res_ornith_prov)
        self.assertEqual(res_ornith_prov[0], "sglang-ornith-1.5-35b")

    def test_resolve_rejects_substring_false_positives(self):
        for bad in (
            "huggingface/Qwen/Qwen3.8-2.4T-A95B",
            "qwen-3.8-flash-next",
            "1.5",
            "unknown-model-xyz",
            "anthropic/claude-3-7-sonnet",
        ):
            self.assertIsNone(self.router.resolve_model_service(bad), f"Expected None for {bad}")


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
        with patch.object(self.router, "get_currently_running_service", return_value="sglang-qwen3.8-27b.service"):
            url = f"http://127.0.0.1:{self.proxy_port}/health"
            with urllib.request.urlopen(url, timeout=2.0) as resp:
                self.assertEqual(resp.status, 200)
                data = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(data["status"], "ok")
                self.assertEqual(data["active_service"], "sglang-qwen3.8-27b.service")

    def test_v1_models_endpoint_returns_canonical_catalog_models_only(self):
        url = f"http://127.0.0.1:{self.proxy_port}/v1/models"
        with urllib.request.urlopen(url, timeout=2.0) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode("utf-8"))
            self.assertEqual(data["object"], "list")
            model_ids = {m["id"] for m in data["data"]}
            self.assertEqual(model_ids, {"qwen3.8-27b", "ornith-1.5-35b", "ornith-1.5-9b"})
            self.assertNotIn("qwen-3.8-nvfp4", model_ids)
            self.assertNotIn("qwen3.8", model_ids)

    def test_wait_for_backend_ready_verifies_expected_served_model(self):
        self.assertTrue(self.router.wait_for_backend_ready(timeout=1.5, expected_served_model="qwen3.8-27b"))
        self.assertFalse(self.router.wait_for_backend_ready(timeout=0.7, expected_served_model="ornith-1.5-35b"))

    def test_chat_completions_rejects_unknown_model_with_404(self):
        import urllib.error

        for bad_model in ("unknown-model-xyz", "1.5", "local-sglang/qwen-3.8-flash-next"):
            _MockBackendHandler.last_request_body = None
            url = f"http://127.0.0.1:{self.proxy_port}/v1/chat/completions"
            payload = {
                "model": bad_model,
                "messages": [{"role": "user", "content": "Hello"}],
            }
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req, timeout=3.0)
            self.assertEqual(ctx.exception.code, 404)
            err_body = json.loads(ctx.exception.read().decode("utf-8"))
            self.assertEqual(err_body["error"]["code"], "model_not_found")
            self.assertIn("ornith-1.5-35b", err_body["error"]["message"])
            self.assertIsNone(_MockBackendHandler.last_request_body)

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

            mock_ensure.assert_called_once_with("sglang-qwen3.8-27b.service", timeout=5.0)
            self.assertIsNotNone(_MockBackendHandler.last_request_body)
            self.assertEqual(_MockBackendHandler.last_request_body["model"], "qwen3.8-27b")
            self.assertEqual(resp_data["model"], "qwen3.8-27b")

    def test_send_json_handles_client_disconnect(self):
        from unittest.mock import MagicMock
        from harness.orchestrator.model_proxy import ModelProxyRequestHandler

        for exc in (BrokenPipeError("client disconnected"), ConnectionResetError("connection reset")):
            handler = ModelProxyRequestHandler.__new__(ModelProxyRequestHandler)
            handler.send_response = MagicMock()
            handler.send_header = MagicMock()
            handler.end_headers = MagicMock()
            handler.wfile = MagicMock()
            handler.wfile.write.side_effect = exc

            handler._send_json(200, {"status": "ok"})
            handler.wfile.write.assert_called_once()

    def test_concurrent_cross_model_request_waits_for_in_flight_completion(self):
        import time

        events = []
        entered_35b = threading.Event()
        allow_35b_finish = threading.Event()

        def fake_ensure(target_service, timeout=180.0):
            events.append(("ensure", target_service))
            return True

        orig_forward = None
        from harness.orchestrator.model_proxy import ModelProxyRequestHandler
        orig_forward = ModelProxyRequestHandler._forward_request

        def slow_forward(handler, method, body=None):
            if body and b"ornith-1.5-35b" in body:
                events.append(("forward_start", "35b"))
                entered_35b.set()
                allow_35b_finish.wait(timeout=3.0)
                events.append(("forward_end", "35b"))
            elif body and b"ornith-1.5-9b" in body:
                events.append(("forward_start", "9b"))
            return orig_forward(handler, method, body=body)

        def post_model(model_name, results):
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.proxy_port}/v1/chat/completions",
                data=json.dumps({"model": model_name, "messages": [{"role": "user", "content": "hi"}]}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                results.append(resp.status)

        with patch.object(self.router, "ensure_service_running", side_effect=fake_ensure), \
             patch.object(ModelProxyRequestHandler, "_forward_request", autospec=True, side_effect=slow_forward):
            res_35b = []
            res_9b = []
            t1 = threading.Thread(target=post_model, args=("local-sglang/ornith-1.5-35b", res_35b))
            t1.start()
            self.assertTrue(entered_35b.wait(timeout=2.0))

            t2 = threading.Thread(target=post_model, args=("local-sglang/ornith-1.5-9b", res_9b))
            t2.start()
            time.sleep(0.15)
            # 9b switch MUST NOT happen while 35b is still in-flight
            self.assertNotIn(("ensure", "sglang-ornith-1.5-9b.service"), events)

            allow_35b_finish.set()
            t1.join(timeout=3.0)
            t2.join(timeout=3.0)

        self.assertEqual(res_35b, [200])
        self.assertEqual(res_9b, [200])
        self.assertLess(
            events.index(("forward_end", "35b")),
            events.index(("ensure", "sglang-ornith-1.5-9b.service")),
        )

    def test_idle_timeout_skipped_while_request_in_flight(self):
        import time

        self.router.idle_timeout_seconds = 1
        self.router.last_activity_time = time.time() - 10
        with patch.object(self.router, "ensure_service_running", return_value=True), \
             patch("harness.orchestrator.model_proxy.subprocess.run") as mock_sub:
            self.assertTrue(self.router.acquire_for_request("sglang-ornith-1.5-35b.service", timeout=1.0))
            try:
                self.router.last_activity_time = time.time() - 10
                self.router.check_idle_timeout()
                mock_sub.assert_not_called()
            finally:
                self.router.release_request()


if __name__ == "__main__":
    unittest.main()
