import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.memory.handoff import TaskHandoff

class TestTaskHandoff(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.handoff_file = Path(self.tmp.name) / "TASK_HANDOFF.md"
        self.handoff = TaskHandoff(handoff_path=self.handoff_file)

    def tearDown(self):
        self.tmp.cleanup()

    def test_handoff_creation(self):
        self.handoff.write_handoff(
            task_title="Test Feature Implementation",
            status="Ready for Human Review",
            affected_files=["src/app.py", "tests/test_app.py"],
            summary="Refactored core handler to be fully async.",
            remaining_todos=["Verify performance under high concurrency"]
        )
        self.assertTrue(self.handoff_file.exists())
        text = self.handoff_file.read_text()
        self.assertIn("Test Feature Implementation", text)
        self.assertIn("src/app.py", text)
        self.assertIn("Verify performance under high concurrency", text)

    def test_discrete_per_task_handoff_files(self):
        handoff_dir = Path(self.tmp.name) / "handoffs"
        th = TaskHandoff(handoff_dir=handoff_dir)

        path1 = th.write_handoff(
            task_id="task-42",
            task_title="Implement Cache",
            status="Completed",
            affected_files=["src/cache.py"],
            summary="Added LRU cache",
            remaining_todos=[]
        )
        path2 = th.write_handoff(
            task_id="task-43",
            task_title="Add Metrics",
            status="In Progress",
            affected_files=["src/metrics.py"],
            summary="Exposed prometheus counter",
            remaining_todos=["Add unit tests"]
        )

        f1 = Path(path1)
        f2 = Path(path2)
        self.assertTrue(f1.exists())
        self.assertTrue(f2.exists())
        self.assertNotEqual(f1, f2)
        self.assertEqual(f1.name, "TASK_HANDOFF_task-42.md")
        self.assertEqual(f2.name, "TASK_HANDOFF_task-43.md")

        text1 = f1.read_text()
        text2 = f2.read_text()
        self.assertIn("Implement Cache", text1)
        self.assertIn("task-42", text1)
        self.assertIn("Add Metrics", text2)
        self.assertIn("task-43", text2)

    def test_slugified_title_without_task_id(self):
        handoff_dir = Path(self.tmp.name) / "handoffs_slug"
        th = TaskHandoff(handoff_dir=handoff_dir)
        path = th.write_handoff(
            task_title="Build CI Pipeline & Tests!",
            status="Ready",
            affected_files=[],
            summary="Configured github actions",
            remaining_todos=[]
        )
        f = Path(path)
        self.assertTrue(f.exists())
        self.assertEqual(f.name, "TASK_HANDOFF_build_ci_pipeline_tests.md")

    def test_list_get_clean_discrete_handoffs(self):
        handoff_dir = Path(self.tmp.name) / "handoffs_mgmt"
        th = TaskHandoff(handoff_dir=handoff_dir)
        th.write_handoff(task_id="t1", task_title="T1", status="done", affected_files=[], summary="s1", remaining_todos=[])
        th.write_handoff(task_id="t2", task_title="T2", status="done", affected_files=[], summary="s2", remaining_todos=[])

        all_handoffs = th.list_handoffs()
        self.assertEqual(len(all_handoffs), 2)

        content_t1 = th.get_handoff("t1")
        self.assertIsNotNone(content_t1)
        self.assertIn("T1", content_t1)

        self.assertTrue(th.clean_handoff("t1"))
        self.assertFalse(th.clean_handoff("t1"))
        self.assertEqual(len(th.list_handoffs()), 1)
        self.assertIsNone(th.get_handoff("t1"))
        self.assertIsNotNone(th.get_handoff("t2"))

if __name__ == "__main__":
    unittest.main()
