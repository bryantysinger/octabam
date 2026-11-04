"""check_shards serialises `git worktree add` and `remove` (a CI run failed with status 128
when the shards, refhash's trees and reach's overlap tree overlapped)."""
import pathlib
import subprocess
import sys
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/verify"))
import check_shards  # noqa: E402


class WorktreeLock(unittest.TestCase):
    def test_threads_do_not_overlap(self):
        active, worst, errors = [0], [0], []
        guard = threading.Lock()

        def work():
            try:
                with check_shards._worktree_lock():
                    with guard:
                        active[0] += 1
                        worst[0] = max(worst[0], active[0])
                    time.sleep(0.05)
                    with guard:
                        active[0] -= 1
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)

        ts = [threading.Thread(target=work) for _ in range(6)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(errors, [])
        self.assertEqual(worst[0], 1)

    def test_another_process_waits(self):
        code = ("import sys, time; sys.path.insert(0, %r); import check_shards\n"
                "with check_shards._worktree_lock():\n    print('held', flush=True); time.sleep(1.0)\n"
                % str(ROOT / "tools/verify"))
        child = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True)
        self.assertEqual(child.stdout.readline().strip(), "held")
        t0 = time.time()
        with check_shards._worktree_lock():
            waited = time.time() - t0
        child.wait()
        self.assertGreater(waited, 0.5)

    def test_a_failing_git_says_why(self):
        import contextlib
        import io
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(subprocess.CalledProcessError):
                check_shards.git("rev-parse", "--verify", "no-such-ref-for-the-test")
        self.assertIn("check_shards: git rev-parse --verify no-such-ref-for-the-test failed (128)", err.getvalue())


if __name__ == "__main__":
    unittest.main()
