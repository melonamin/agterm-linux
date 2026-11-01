#!/usr/bin/env python3
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import types
import unittest

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TESTS)
from gl_teardown_analyze import analyze  # noqa: E402
from gl_teardown_analyze_test import clean_log  # noqa: E402
from gl_teardown_paths import judge_run, require_clean_exit  # noqa: E402

RUNNER = os.path.join(TESTS, "gl_teardown_headless.sh")
ON_TERM = {
    "clean": "trap 'exit 0' TERM",
    "exit7": "trap 'exit 7' TERM",
    "abort": "trap 'trap - ABRT; kill -ABRT $$' TERM",
    "default": ":",
    "ignore": "trap '' TERM",
}


def in_runner(script, *arguments):
    """Runs `script` with the runner's own functions, sourced, on a stand-in with no app and no display."""
    return subprocess.run(["bash", "-c", f"source {RUNNER}; set +e; BOUND_SECONDS=1; {script}", "_", *arguments],
                          capture_output=True, text=True, timeout=30)


def reap_status(behaviour):
    with tempfile.TemporaryDirectory() as directory:
        ready = os.path.join(directory, "ready")
        child = f"{ON_TERM[behaviour]}; : > {ready}; while :; do sleep 0.02; done"
        script = (f"sh -c \"$1\" & pid=$!; until [ -e {ready} ]; do sleep 0.01; done; reap_app $pid; echo status=$?")
        result = in_runner(script, child)
    return int(result.stdout.rsplit("status=", 1)[1])


class CompleteTrace(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = directory.name
        self.log = os.path.join(self.directory, "trace.log")
        self.stderr = os.path.join(self.directory, "stderr.log")
        with open(self.log, "w", encoding="utf-8") as file:
            file.write("\n".join(clean_log()) + "\n")
        with open(self.stderr, "w", encoding="utf-8"):
            pass

    def test_the_trace_alone_is_clean(self):
        self.assertEqual(0, analyze(clean_log(), [])[0])

    def judge(self, returncode):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            judge_run(types.SimpleNamespace(returncode=returncode), [self.log, "--app-stderr", self.stderr])
        return output.getvalue()

    def test_a_zero_exit_passes(self):
        self.assertIn("app exit status 0", self.judge(0))

    def test_a_nonzero_exit_fails_beside_a_complete_trace(self):
        with self.assertRaisesRegex(AssertionError, "the app exited 1"):
            self.judge(1)

    def test_a_signal_exit_fails_beside_a_complete_trace(self):
        for returncode in (-6, -9, -15):
            with self.subTest(returncode), self.assertRaisesRegex(AssertionError, f"the app exited {returncode}"):
                self.judge(returncode)

    def test_require_clean_exit_stands_alone(self):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(AssertionError):
            require_clean_exit(types.SimpleNamespace(returncode=3))

    def runner_judge(self, app_status):
        return in_runner('judge_run "$1" "$2" "$3" "$4"; echo verdict=$?', self.log, self.stderr, self.directory, app_status)

    def test_the_runner_passes_a_clean_exit(self):
        self.assertIn("verdict=0", self.runner_judge("0").stdout)

    def test_the_runner_rejects_a_bad_exit_beside_a_complete_trace(self):
        for status in ("7", "134", "143"):
            with self.subTest(status):
                result = self.runner_judge(status)
                self.assertIn("verdict=1", result.stdout)
                self.assertIn(f"the app exited {status}", result.stderr)


class ReapApp(unittest.TestCase):
    def test_the_real_status_comes_back(self):
        for behaviour, expected in (("clean", 0), ("exit7", 7), ("abort", 134), ("default", 143), ("ignore", 137)):
            with self.subTest(behaviour):
                self.assertEqual(expected, reap_status(behaviour))


if __name__ == "__main__":
    unittest.main()
