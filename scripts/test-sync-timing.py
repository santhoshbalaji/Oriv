#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest
from uuid import UUID

spec = importlib.util.spec_from_file_location("sync_timing", Path(__file__).with_name("sync-timing.py"))
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)

RUN = UUID(int=1)


def log(role, prefix=""):
    rows = []
    for trial in range(1, 21):
        base = 1000 + trial * 5
        for event, second in [("sent", base), ("received", base + trial / 100)]:
            rows.append({"run": str(RUN), "role": role, "event": event, "trial": trial, "unixSeconds": second})
    for event in (["cleaned", "complete"] if role == "mac" else ["complete"]):
        rows.append({"run": str(RUN), "role": role, "event": event, "unixSeconds": 1200})
    return [prefix + json.dumps(row) for row in rows]


class SyncTimingTests(unittest.TestCase):
    def test_raw_and_console_logs_with_nearest_rank_p95(self):
        mac = timing.read_log(log("mac", "ORIV_SYNC_TIMING "), "mac", RUN)
        iphone = timing.read_log(log("iphone"), "iphone", RUN)
        for sender, receiver in [(mac, iphone), (iphone, mac)]:
            p50, p95 = timing.summarize(sender, receiver)
            self.assertAlmostEqual(p50, 105)
            self.assertAlmostEqual(p95, 190)

    def test_missing_and_duplicate_trials_fail(self):
        rows = log("mac")
        with self.assertRaisesRegex(ValueError, "missing sent trials"):
            timing.read_log(rows[1:], "mac", RUN)
        with self.assertRaisesRegex(ValueError, "duplicate sent"):
            timing.read_log(rows + rows[:1], "mac", RUN)

    def test_other_run_and_missing_cleanup_fail(self):
        rows = log("mac")
        with self.assertRaisesRegex(ValueError, "another role or run"):
            timing.read_log(rows, "mac", UUID(int=2))
        with self.assertRaisesRegex(ValueError, "verified cleanup"):
            timing.read_log(rows[:-2] + rows[-1:], "mac", RUN)

    def test_negative_clock_difference_fails(self):
        mac = timing.read_log(log("mac"), "mac", RUN)
        iphone = timing.read_log(log("iphone"), "iphone", RUN)
        iphone["received"][1] -= 10
        with self.assertRaisesRegex(ValueError, "negative latency"):
            timing.summarize(mac, iphone)


if __name__ == "__main__":
    unittest.main()
