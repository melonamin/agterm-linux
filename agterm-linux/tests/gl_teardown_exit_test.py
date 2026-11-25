#!/usr/bin/env python3
import contextlib
import io
import os
import shutil
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
SOURCES = ("agterm-linux/Sources/a.swift", "agtermCore/Sources/b.swift", "linux/patches/c.patch")
ON_TERM = {
    "clean": "trap 'exit 0' TERM",
    "exit7": "trap 'exit 7' TERM",
    # A piped host core collector can hold an aborting process beyond the fixture's one-second bound.
    # Keep the same PID and signal status without generating a core; real app diagnostics are unchanged.
    "abort": ("trap 'exec python3 -c \"import ctypes, os, signal; "
              "assert ctypes.CDLL(None).prctl(4, 0) == 0; os.kill(os.getpid(), signal.SIGABRT)\"' TERM"),
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


class StageSource(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = os.path.join(directory.name, "tree")
        self.stage = os.path.join(directory.name, "stage")
        os.makedirs(os.path.join(self.stage, "share", "agterm"))
        for path in SOURCES:
            self.write(path, "first")
        self.write("README.md", "first")
        self.git("init", "-q")
        self.staged = self.commit("first")

    def write(self, path, text):
        target = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as file:
            file.write(text)

    def git(self, *arguments):
        environment = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
        identity = ("-c", "user.name=test", "-c", "user.email=test@example.invalid")
        result = subprocess.run(["git", "-C", self.root, *identity, *arguments], env=environment, check=True,
                                capture_output=True, text=True)
        return result.stdout.strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, commit=None):
        with open(os.path.join(self.stage, "share", "agterm", "COMMIT"), "w", encoding="utf-8") as file:
            file.write(f"{self.staged if commit is None else commit}\n")
        return in_runner('require_stage_source "$1" "$2"', self.root, self.stage)

    def assert_refused(self, result, reason):
        self.assertEqual(2, result.returncode, result.stderr)
        self.assertIn(reason, result.stderr)

    def test_the_stage_commit_itself_passes(self):
        result = self.check()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f"stage commit {self.staged}", result.stdout)

    def test_a_later_commit_outside_the_sources_passes(self):
        self.write("README.md", "second")
        self.commit("docs")
        self.write("README.md", "uncommitted")
        self.assertEqual(0, self.check().returncode)

    def test_a_committed_source_change_is_refused(self):
        for path in SOURCES:
            with self.subTest(path):
                self.write(path, f"committed {path}")
                self.commit(path)
                self.assert_refused(self.check(), "the tree differs from stage commit")
                self.git("revert", "--no-edit", "HEAD")
                self.assertEqual(0, self.check().returncode)

    def test_an_uncommitted_source_change_is_refused(self):
        for path in SOURCES:
            with self.subTest(path):
                self.write(path, "uncommitted")
                self.assert_refused(self.check(), "the tree differs from stage commit")
                self.git("checkout", "--", path)

    def test_an_untracked_source_is_refused(self):
        self.write("agterm-linux/Sources/new.swift", "untracked")
        self.assert_refused(self.check(), "untracked files")

    def test_a_commit_git_does_not_know_is_refused(self):
        self.assert_refused(self.check("f" * 40), "git cannot resolve stage commit")

    def test_a_hash_that_is_not_a_commit_is_refused(self):
        self.assert_refused(self.check(self.git("rev-parse", "HEAD^{tree}")), "git cannot resolve stage commit")

    def test_a_stage_with_no_commit_is_refused(self):
        self.assert_refused(self.check(""), "the stage names no commit")

    def test_an_unreadable_gitdir_is_refused(self):
        shutil.rmtree(os.path.join(self.root, ".git"))
        with open(os.path.join(self.root, ".git"), "w", encoding="utf-8") as file:
            file.write("gitdir: /nonexistent/worktrees/stage\n")
        self.assert_refused(self.check(), "git cannot resolve stage commit")


class ReapApp(unittest.TestCase):
    def test_the_real_status_comes_back(self):
        for behaviour, expected in (("clean", 0), ("exit7", 7), ("abort", 134), ("default", 143), ("ignore", 137)):
            with self.subTest(behaviour):
                self.assertEqual(expected, reap_status(behaviour))


if __name__ == "__main__":
    unittest.main()
