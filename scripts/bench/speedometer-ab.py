#!/usr/bin/env python3
"""Oriv-Bench launcher and loopback server for a pinned Speedometer build."""
import argparse
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build/bench"
PIN = "1386415be8fef2f6b6bbdbe1828872471c5d802a"
SHA256 = "cfefa818d7789ed2f2b9f3f1bf608cc35e4e8241489eef47049296ce92791313"
SCRIPT_SWITCHES = ("edit-tracker", "tab-audio", "display-capture", "link-menu", "page-colour", "tab-paint")
SWITCHES = ("cosmetics", "content-blocker", *SCRIPT_SWITCHES, "tab-kvo", "snapshot", "history")
VARIANTS = {"baseline": (), **{name: (name,) for name in SWITCHES}, "all-off": SWITCHES}


class FixtureHandler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".mjs": "text/javascript"}

    def log_message(self, *_):
        pass


def speedometer_directory():
    source = BUILD / f"Speedometer-{PIN}"
    if (source / "index.html").is_file() and (source / "LICENSE").is_file():
        return source

    with tempfile.TemporaryDirectory(dir=BUILD) as staging:
        archive = Path(staging) / "speedometer.tar.gz"
        subprocess.run(
            ["curl", "-fLsS", "--retry", "3", "-o", str(archive),
             f"https://codeload.github.com/WebKit/Speedometer/tar.gz/{PIN}"], check=True,
        )
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
            raise RuntimeError("Speedometer archive checksum changed")
        subprocess.run(["tar", "-xf", str(archive), "-C", staging], check=True)
        (Path(staging) / source.name).rename(source)
    return source


def run_variant(executable, out, url, variant, index, timeout, smoke):
    disabled = VARIANTS[variant]
    env = {
        "ORIV_BACKGROUND_UI": "1" if smoke else "0",
        "ORIV_FOREGROUND_UI": "0",
        "ORIV_BENCH_URL": url,
        "ORIV_BENCH_DISABLE": ",".join(disabled),
        "ORIV_BENCH_SMOKE": "1" if smoke else "0",
    }
    log = out / f"{index:02d}-{variant}.log"
    launch = ["/usr/bin/open", "-n", "-W"]
    if smoke:
        launch.append("-g")
    launch += ["--stdout", str(log), "--stderr", str(log)]
    for name, value in env.items():
        launch += ["--env", f"{name}={value}"]
    launch += ["-a", str(executable.parents[2])]
    try:
        status = subprocess.run(launch, timeout=timeout, check=False)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        # Launch Services owns the app process. Stop only the instance that
        # identified itself in this run's unique log.
        if log.is_file():
            for line in log.read_text(errors="replace").splitlines():
                if line.startswith("ORIV_BENCH_PID "):
                    pid = json.loads(line.partition(" ")[2])["pid"]
                    command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                                             capture_output=True, text=True, check=False)
                    if command.stdout.strip() == str(executable):
                        try:
                            os.kill(pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    break
        raise
    if status.returncode:
        raise RuntimeError(f"Oriv-Bench exited {status.returncode}. See {log}")
    lines = log.read_text(errors="replace").splitlines()
    messages = [line.partition(" ")[2] for line in lines if line.startswith("ORIV_BENCH_RESULT ")]
    if len(messages) != 1:
        error = next((line for line in lines if line.startswith("ORIV_BENCH_ERROR ")), "Missing result")
        raise RuntimeError(f"{error}. See {log}")
    row = json.loads(messages[0])
    expected = (set(SCRIPT_SWITCHES) - set(disabled)) | {"result-reader"}
    if row["disabled"] != sorted(disabled) or {script["name"] for script in row["scripts"]} != expected:
        raise RuntimeError(f"Wrong script inventory for {variant}. See {log}")
    components = row["content_rule_components"]
    if ("content-blocker" in disabled) != (not components):
        raise RuntimeError(f"Wrong content-blocker state for {variant}. See {log}")
    if "content-blocker" not in disabled and ("cosmetics" not in disabled) != any(
        name.startswith("cosmetics") for name in components
    ):
        raise RuntimeError(f"Wrong cosmetic rule state for {variant}. See {log}")
    if smoke:
        audit = row["background_ui"]
        if not (audit["enabled"] and audit["accessory"] and audit["windowFrameSamples"] > 0) or any(
            audit[key] for key in ("frontmostViolations", "activationViolations", "onscreenWindowViolations")
        ):
            raise RuntimeError(f"Offscreen UI audit failed. See {log}")
        if row["score"] != 42.25 or row["suites"] != {"Fixture": 12}:
            raise RuntimeError(f"Fake benchmark result differs from fixture. See {log}")
    return {**row, "variant": variant, "run_index": index, "smoke": smoke}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--foreground", action="store_true", help="Run Speedometer in a visible Oriv-Bench window")
    mode.add_argument("--smoke", action="store_true", help="Test the harness offscreen with a tiny local fixture")
    parser.add_argument("--runs", type=int, help="Runs per variant (default 3, smoke 1)")
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=list(VARIANTS))
    parser.add_argument("--timeout", type=int, default=600, help="Maximum seconds per process")
    parser.add_argument("--output", type=Path, help="New output directory (default build/bench/run-*)")
    parser.add_argument("--skip-build", action="store_true", help="Use the previously built Oriv-Bench.app")
    args = parser.parse_args()
    runs = args.runs if args.runs is not None else (1 if args.smoke else 3)
    if runs < 1 or args.timeout < 1 or len(set(args.variants)) != len(args.variants):
        parser.error("Use positive runs/timeout and unique variants")
    if not args.smoke and os.environ.get("ORIV_BACKGROUND_UI") == "1":
        parser.error("This environment requires background UI. Use --smoke.")
    BUILD.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        subprocess.run([str(ROOT / "scripts/bench/build-bench.sh")], check=True)
    bundle = BUILD / "derived/Build/Products/Release/Oriv-Bench.app/Contents"
    with (bundle / "Info.plist").open("rb") as metadata:
        if plistlib.load(metadata)["CFBundleIdentifier"] != "local.personalbrowser.bench":
            raise RuntimeError("Incorrect benchmark bundle identity")
    executable = bundle / "MacOS/Oriv-Bench"

    if args.output is None:
        out = Path(tempfile.mkdtemp(prefix="run-", dir=BUILD))
    else:
        out = args.output.resolve()
        out.mkdir(parents=True, exist_ok=False)

    directory = Path(__file__).parent if args.smoke else speedometer_directory()
    path = "/fake-speedometer.html" if args.smoke else "/index.html"
    handler = partial(FixtureHandler, directory=directory)
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server, (out / "results.jsonl").open("w") as results:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        url = f"http://127.0.0.1:{server.server_port}{path}"
        print(f"Results: {results.name}", flush=True)
        try:
            for index in range(1, runs + 1):
                for variant in args.variants:
                    print(f"{index}/{runs} {variant}", flush=True)
                    row = run_variant(executable, out, url, variant, index, args.timeout, args.smoke)
                    if not args.smoke:
                        row["speedometer_revision"] = PIN
                    print(json.dumps(row, allow_nan=False), file=results, flush=True)
        finally:
            server.shutdown()
            worker.join()


if __name__ == "__main__":
    main()
