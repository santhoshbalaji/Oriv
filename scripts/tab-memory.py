#!/usr/bin/env python3
"""Isolated, offscreen tab experiment. Artifacts and generated app stay in build/.

Run: ORIV_BACKGROUND_UI=1 python3 scripts/tab-memory.py --label before
The selected page is offscreen/occluded; WebKit visibility differs from owner UI.
"""
import argparse
import ctypes
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "build/tab-memory"
FIELDS = "user system pkg interrupt pageins wired rss footprint start exit cu cs cpkg cint cpage celapsed dr dw".split()


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(f, ctypes.c_uint64) for f in FIELDS] + [("pad", ctypes.c_uint64 * 128)]


lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
lib.responsibility_get_pid_responsible_for_pid.argtypes = [ctypes.c_int]
lib.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]


def snapshot(main):
    procs = {}
    for line in subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines():
        pid, name = line.strip().split(maxsplit=1)
        pid = int(pid)
        if pid != main and lib.responsibility_get_pid_responsible_for_pid(pid) != main:
            continue
        usage = Usage()
        if lib.proc_pid_rusage(pid, 6, ctypes.byref(usage)) == 0:
            # proc_pid_rusage CPU times are mach ticks, converted using the host timebase.
            procs[pid] = {"name": pathlib.Path(name).name, "cpu_ns": (usage.user + usage.system) * TICK,
                          "footprint": usage.footprint, "start": usage.start}
    return {"t": time.monotonic(), "procs": procs}


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


tb = Timebase()
lib.mach_timebase_info(ctypes.byref(tb))
TICK = tb.numer / tb.denom


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Tab memory fixture</title><p id="tick">0</p><div style="height:6000px">Local fixture</div><script>let n=0;setInterval(()=>document.getElementById("tick").textContent=++n,1000)</script>'
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def build(product):
    package = OUT / "harness"
    sources = package / "Sources/Probe"
    sources.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "scripts/tab-memory-probe.swift", sources / "Probe.swift")
    # Reuse placement/audits, with a stricter activation policy for this standalone
    # measurement app. This does not modify the app/test host's shared source.
    ui = (ROOT / "Apps/macOS/BackgroundUIMode.swift").read_text()
    policy_line = "if NSApplication.shared.activationPolicy() != .accessory { NSApplication.shared.setActivationPolicy(.accessory) }"
    if ui.count(policy_line) != 1:
        raise RuntimeError("Shared background policy changed; verify prohibited activation before rebuilding the probe")
    ui = ui.replace(policy_line, "if NSApplication.shared.activationPolicy() != .prohibited { NSApplication.shared.setActivationPolicy(.prohibited) }")
    (sources / "BackgroundUIMode.swift").write_text(ui)
    (package / "Package.swift").write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "TabMemoryProbe", platforms: [.macOS("26.0")], dependencies: [.package(path: ' + json.dumps(str(ROOT / "Packages/BrowserKit")) + ')], targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "BrowserCore", package: "BrowserKit"), .product(name: "BrowserEngine", package: "BrowserKit")])])\n')
    with (OUT / "build.log").open("w") as log:
        command = ["swift", "build", "-c", "release", "--package-path", str(package)]
        if product:
            command += ["-Xswiftc", "-enable-testing", "-Xswiftc", "-DTAB_RECLAMATION_PRODUCT"]
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    app = OUT / "TabMemoryProbe.app"
    binary = app / "Contents/MacOS/Probe"
    binary.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(package / ".build/release/Probe", binary)
    resources = app / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    for bundle in (package / ".build/release").glob("*.bundle"):
        shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)
    with (app / "Contents/Info.plist").open("wb") as f:
        plistlib.dump({"CFBundleIdentifier": "local.oriv.tab-memory-probe", "CFBundleExecutable": "Probe", "CFBundleName": "TabMemoryProbe", "CFBundlePackageType": "APPL", "LSUIElement": True}, f)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    return app


def run(args):
    if os.environ.get("ORIV_BACKGROUND_UI") != "1" or os.environ.get("ORIV_FOREGROUND_UI") == "1":
        raise SystemExit("Requires ORIV_BACKGROUND_UI=1 and no foreground override")
    OUT.mkdir(parents=True, exist_ok=True)
    app = build(args.product)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = []
    active_folder = None
    try:
        for policy in args.policies:
            folder = OUT / args.label / policy
            folder.mkdir(parents=True, exist_ok=False)
            active_folder = folder
            subprocess.run(["open", "-g", "-j", "-n", "--env", "ORIV_BACKGROUND_UI=1", str(app), "--args", policy, str(folder), f"http://127.0.0.1:{server.server_port}"], check=True)
            for stage in ["1", "10", "20", "closed-1"]:
                deadline = time.monotonic() + 180
                while True:
                    if (folder / "error.txt").exists():
                        raise RuntimeError((folder / "error.txt").read_text())
                    ready = json.loads((folder / "ready.json").read_text()) if (folder / "ready.json").exists() else {}
                    if ready.get("stage") == stage:
                        break
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"Timed out at {policy}/{stage}")
                    time.sleep(.2)
                audit = ready["audit"]
                if any(audit[k] for k in ["frontmostViolations", "activationViolations", "onscreenWindowViolations"]) or not ready["activationProhibited"]:
                    raise RuntimeError(f"Background safety audit failed: {audit}")
                samples = [snapshot(ready["pid"])]
                for _ in range(args.seconds):
                    time.sleep(1)
                    samples.append(snapshot(ready["pid"]))
                # Integrate adjacent intervals so helpers exiting during the run are included up to their final sample.
                cpu = 0
                for a, b in zip(samples, samples[1:]):
                    for pid, p in b["procs"].items():
                        old = a["procs"].get(pid)
                        if old and old["start"] == p["start"]:
                            cpu += max(0, p["cpu_ns"] - old["cpu_ns"])
                row = {"policy": policy, **ready, "seconds": samples[-1]["t"] - samples[0]["t"],
                       "footprint_mb": sum(p["footprint"] for p in samples[-1]["procs"].values()) / 1e6,
                       "cpu_pct": cpu / (samples[-1]["t"] - samples[0]["t"]) / 1e7}
                (folder / f"{stage}.json").write_text(json.dumps({"result": row, "samples": samples}, indent=2))
                results.append(row)
                print(json.dumps(row), flush=True)
                (OUT / args.label / "results.json").write_text(json.dumps(results, indent=2))
                (folder / f"ack-{stage}").touch()
    except BaseException:
        if active_folder is not None:
            (active_folder / "abort").touch()
        raise
    finally:
        server.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--policies", nargs="+", choices=["throttle", "suspend", "discard"], default=["throttle", "suspend", "discard"])
    parser.add_argument("--product", action="store_true", help="Exercise the real reclamation policy with a test-only clock adjustment")
    arguments = parser.parse_args()
    if arguments.seconds <= 0 or pathlib.Path(arguments.label).name != arguments.label or arguments.label in [".", ".."]:
        parser.error("Use a positive duration and a single directory name for --label")
    run(arguments)
