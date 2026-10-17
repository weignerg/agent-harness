import json, sys, threading, time, unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.orchestrator import router as R

SEEN = []


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"]))); SEEN.append((self.path, body))
        out = {"choices": [{"message": {"content": 'sure {"agent":"architect","plan":["a","b"]}'}}]}
        data = json.dumps(out).encode(); self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


class RouterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), H); cls.url = f"http://127.0.0.1:{cls.srv.server_address[1]}/v1"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls): cls.srv.shutdown()

    def test_tier0_override_no_llm(self):
        called = []
        r = R.CascadeRouter(llm=lambda t: called.append(t))
        t = time.perf_counter(); route = r.route("@reviewer please look at this"); ms = (time.perf_counter() - t) * 1000
        self.assertEqual((route.tier, route.target), (0, "reviewer")); self.assertFalse(called); self.assertLess(ms, 5)

    def test_tier1_rule_no_llm(self):
        called = []
        route = R.CascadeRouter(llm=lambda t: called.append(t)).route("run the unit tests now")
        self.assertEqual((route.tier, route.kind), (1, "tool")); self.assertFalse(called)

    def test_tier2_semantic(self):
        route = R.CascadeRouter(llm=lambda t: self.fail("LLM must not be called")).route("security audit for vulnerability and leak in this diff")
        self.assertEqual((route.tier, route.target), (2, "reviewer"))

    def test_tier3_dispatch_to_endpoint_with_fast_profile(self):
        SEEN.clear()
        route = R.CascadeRouter(base_url=self.url).route("zzz qqq xxx")
        self.assertEqual((route.tier, route.target, route.plan), (3, "architect", ("a", "b")))
        path, body = SEEN[0]; self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(body["max_tokens"], 256); self.assertEqual(body["temperature"], 0.0)
        self.assertEqual(body["model"], "ornith-1.5-35b")

    def test_tier3_bad_json_defaults_to_worker(self):
        class Bad(H):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"])); d = json.dumps({"choices": [{"message": {"content": "no json"}}]}).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
        s = HTTPServer(("127.0.0.1", 0), Bad); threading.Thread(target=s.serve_forever, daemon=True).start()
        r = R.tier3("hi", f"http://127.0.0.1:{s.server_address[1]}/v1"); s.shutdown()
        self.assertEqual((r.target, r.plan), ("worker", ()))

    def test_tier_priority_override_beats_rule(self):
        self.assertEqual(R.CascadeRouter(llm=lambda t: None).route("@worker run tests").tier, 0)

    def test_canonical_prefix_is_byte_stable_and_append_only(self):
        tools_a = [{"name": "b", "x": 1, "a": 2}, {"name": "a", "p": {"z": 1, "y": 2}}]
        tools_b = [{"a": 2, "x": 1, "name": "b"}, {"p": {"y": 2, "z": 1}, "name": "a"}]
        h1 = [{"role": "user", "content": "hi  \n"}]
        p1 = R.canonical_prefix("sys \n", tools_a, h1)
        self.assertEqual(p1, R.canonical_prefix("sys", tools_b, h1))
        h2 = h1 + [{"role": "assistant", "content": "yo"}]
        p2 = R.canonical_prefix("sys", tools_a, h2)
        self.assertTrue(p2.startswith(p1)); self.assertEqual(R.build_messages("sys", tools_a, h1, "q")[0]["content"], p1)

    def test_profiles_differ(self):
        self.assertLess(R.FAST_PROFILE["max_tokens"], R.FULL_PROFILE["max_tokens"])


if __name__ == "__main__":
    unittest.main()
