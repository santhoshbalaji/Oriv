#!/usr/bin/env python3
"""Summarize a pair of Oriv CloudKit timing JSONL logs."""
import argparse
import json
import math
from pathlib import Path
from statistics import median
from uuid import UUID

TRIALS = 20
PREFIX = "ORIV_SYNC_TIMING "


def read_log(lines, role, run):
    events = {"sent": {}, "received": {}}
    terminal = set()
    for line in lines:
        line = line.strip()
        if PREFIX in line:
            line = line.split(PREFIX, 1)[1]
        elif not line.startswith("{"):
            continue
        row = json.loads(line)
        if row.get("role") != role or UUID(row.get("run", "")) != run:
            raise ValueError(f"{role} log contains another role or run")
        event = row.get("event")
        if event in ("cleaned", "cleanup-failed", "complete"):
            if event in terminal:
                raise ValueError(f"{role} log contains duplicate {event}")
            terminal.add(event)
            continue
        if event not in events:
            raise ValueError(f"{role} log contains an unknown event")
        trial, time = row.get("trial"), row.get("unixSeconds")
        if (type(trial) is not int or not 1 <= trial <= TRIALS or
                type(time) not in (int, float) or not math.isfinite(time) or time <= 0):
            raise ValueError(f"{role} log contains an invalid trial or timestamp")
        if trial in events[event]:
            raise ValueError(f"{role} log contains duplicate {event} for trial {trial}")
        events[event][trial] = time
    expected = set(range(1, TRIALS + 1))
    for event, trials in events.items():
        if trials.keys() != expected:
            raise ValueError(f"{role} log missing {event} trials {sorted(expected - trials.keys())}")
    expected_terminal = {"complete", "cleaned"} if role == "mac" else {"complete"}
    if terminal != expected_terminal:
        raise ValueError(f"{role} log is missing completion or verified cleanup")
    return events


def summarize(sender, receiver):
    delays = sorted((receiver["received"][trial] - timestamp) * 1000
                    for trial, timestamp in sender["sent"].items())
    if delays[0] < 0:
        raise ValueError("negative latency. Verify automatic time and device clock skew.")
    return median(delays), delays[math.ceil(0.95 * len(delays)) - 1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=UUID)
    parser.add_argument("mac_log", type=Path)
    parser.add_argument("iphone_log", type=Path)
    args = parser.parse_args()
    try:
        with args.mac_log.open() as mac_log, args.iphone_log.open() as iphone_log:
            mac = read_log(mac_log, "mac", args.run)
            iphone = read_log(iphone_log, "iphone", args.run)
        summaries = [summarize(mac, iphone), summarize(iphone, mac)]
    except (OSError, ValueError, TypeError, AttributeError) as error:
        parser.exit(1, f"Timing logs could not be summarized: {error}\n")
    for direction, (p50, p95) in zip(("Mac → iPhone", "iPhone → Mac"), summaries):
        print(f"{direction} ({TRIALS} trials): p50 {p50:.1f} ms, p95 {p95:.1f} ms")
    print("Sender clock to receiver's first successful foreground poll (1 s nominal interval).")


if __name__ == "__main__":
    main()
