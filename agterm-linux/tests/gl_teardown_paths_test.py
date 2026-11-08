#!/usr/bin/env python3
import contextlib
import io
import os
import sys
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gl_teardown_paths  # noqa: E402
from gl_teardown_paths import ControlError, Paths  # noqa: E402


class StubLog:
    counts = {"DRAW_END": 0}

    def refresh(self):
        pass

    def wait_count(self, kind, above, message):
        pass


class StubPaths(Paths):
    """`session_selected` with the app gone: only its control reads are real to the probe."""

    def __init__(self, read, reads_before_close):
        self.log = StubLog()
        self.read = read
        self.reads_left = threading.Semaphore(0)
        self.reads_before_close = reads_before_close

    def new_session(self, name):
        return "session"

    def request(self, cmd, target=None, **args):
        if cmd == "window.list":
            try:
                return self.read()
            finally:
                self.reads_left.release()
        return {}

    def closing(self, path, action):
        for _ in range(self.reads_before_close):
            self.reads_left.acquire(timeout=1)
        action()


def fails_at_once(error):
    def read():
        raise error
    return read


class BusyCloseProbe(unittest.TestCase):
    def session_selected(self, read, reads_before_close=1):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            StubPaths(read, reads_before_close).session_selected()
        return output.getvalue()

    def test_a_read_timeout_fails_the_scenario(self):
        with self.assertRaisesRegex(AssertionError, "TimeoutError"):
            self.session_selected(fails_at_once(TimeoutError("timed out")))

    def test_a_refused_read_fails_the_scenario(self):
        with self.assertRaisesRegex(AssertionError, "the control socket closed"):
            self.session_selected(fails_at_once(ControlError("window.list: the control socket closed")))

    def test_a_read_failing_after_a_good_one_fails_the_scenario(self):
        replies = iter([{}])

        def read():
            return next(replies)

        with self.assertRaisesRegex(AssertionError, "StopIteration"):
            self.session_selected(read, reads_before_close=2)

    def test_a_read_that_never_returns_fails_the_scenario(self):
        released = threading.Event()
        self.addCleanup(released.set)
        with mock.patch.object(gl_teardown_paths, "WAIT_SECONDS", 0.2):
            with self.assertRaisesRegex(AssertionError, "still running"):
                self.session_selected(released.wait)

    def test_a_probe_with_no_completed_read_fails(self):
        probe = gl_teardown_paths.ControlProbe(lambda: None)
        probe.done.set()
        probe.start()
        with self.assertRaisesRegex(AssertionError, "no control read completed"):
            probe.finish()

    def test_a_slow_read_fails_the_limit(self):
        with mock.patch.object(gl_teardown_paths, "READ_LIMIT_SECONDS", 0.01):
            with self.assertRaisesRegex(AssertionError, "a control read took"):
                self.session_selected(lambda: time.sleep(0.05))

    def test_working_reads_report_a_nonzero_worst(self):
        report = self.session_selected(lambda: time.sleep(0.005))
        self.assertRegex(report, r"OK: worst control read around the busy close [1-9]\d* ms")


if __name__ == "__main__":
    unittest.main()
