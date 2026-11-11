#!/bin/zsh
# Renders the real Mac views with synthetic data into PNGs (Debug-only snapshot mode) and
# verifies them against the run's manifest. Uses a separate bundle identity and ephemeral
# BROWSER_TESTING state; never touches installed apps or their data.
#
# usage: scripts/capture-mac-visuals.sh [--glass] [--key] [output-directory]
#   --glass    capture loaded-page fixtures. Background mode writes labelled page
#              snapshots and opaque layout fallbacks, skipping compositor/glass.
#              Approved foreground mode uses only this app's validated window IDs.
#   --key      request key-window behaviour without app activation in background mode.
#   --active   legacy alias for --key; activation additionally needs ORIV_FOREGROUND_UI=1.
#   ORIV_BACKGROUND_UI=1 is the default. Foreground UI requires orchestrator approval.
#   ORIV_GLASS_SCENE=sidebar captures the fixed-sidebar acceptance matrix.
#   The default PID-validated PNG bridge captures only the app's own window IDs.
#   ORIV_CAPTURE_RENDERER=inprocess opts into ScreenCaptureKit instead.
#   The output directory must not exist or must be empty. Default: build/visual-runs/<timestamp>-mac
set -euo pipefail
cd "$(dirname "$0")/.."
export ORIV_BACKGROUND_UI="${ORIV_BACKGROUND_UI:-1}"
if [[ "$ORIV_BACKGROUND_UI" != 1 && "${ORIV_FOREGROUND_UI:-}" != 1 ]]; then
  echo "Foreground UI requires ORIV_FOREGROUND_UI=1 and orchestrator approval." >&2; exit 2
fi
GLASS=0
if [[ "${1:-}" == "--glass" ]]; then GLASS=1; shift; fi
ACTIVATE=0
if [[ "${1:-}" == "--active" || "${1:-}" == "--key" ]]; then ACTIVATE=1; shift; fi
if [[ "$GLASS" == 1 && "$ORIV_BACKGROUND_UI" != 1 ]]; then
  swift -e 'import CoreGraphics; import Foundation
    let state = CGSessionCopyCurrentDictionary() as? [String: Any]
    if CGDisplayIsAsleep(CGMainDisplayID()) != 0 || state?["CGSSessionScreenIsLocked"] as? Bool == true {
      fputs("Owned-window capture requires an unlocked, awake Mac display.\n", stderr); exit(2)
    }'
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-build/visual-runs/$STAMP-mac}"
if [[ -e "$OUT" && -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  echo "refusing to write into non-empty $OUT; choose a new directory" >&2; exit 1
fi
RUN_ID="$STAMP-$$-$RANDOM"
DERIVED=build/visual-snapshots-mac
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  PRODUCT_BUNDLE_IDENTIFIER=local.personalbrowser.snapshots ORIV_APP_NAME=Oriv-Snapshots build > "$DERIVED.log" 2>&1 \
  || { tail -20 "$DERIVED.log"; echo "build failed" >&2; exit 1; }
APP="$DERIVED/Build/Products/Debug/Oriv-Snapshots.app"
SRC="$HOME/Library/Containers/local.personalbrowser.snapshots/Data/tmp/OrivVisualSnapshots/$RUN_ID"
cleanup() {
  # A failed capture must not leave this run's isolated app running.
  if [[ "$GLASS" == 1 && -f "$SRC/capture-request.json" ]]; then
    python3 -I - "$SRC/capture-request.json" "$APP" <<'CLEANUP'
import json, os, pathlib, signal, subprocess, sys
try:
    request = json.loads(pathlib.Path(sys.argv[1]).read_text())
    pid = int(request['pid'])
    expected = str(pathlib.Path(sys.argv[2]).resolve() / 'Contents/MacOS/Oriv-Snapshots')
    actual = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
    if actual == expected: os.kill(pid, signal.SIGTERM)
except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
    pass
CLEANUP
  fi
}
trap cleanup EXIT

if [[ "$GLASS" == 1 ]]; then
  /usr/bin/open -g -n -W --env ORIV_BACKGROUND_UI="$ORIV_BACKGROUND_UI" --env ORIV_FOREGROUND_UI="${ORIV_FOREGROUND_UI:-}" --env BROWSER_TESTING=1 --env ORIV_VISUAL_SNAPSHOTS=1 \
    --env ORIV_SNAPSHOT_RUN_ID="$RUN_ID" --env ORIV_SNAPSHOT_ACTIVATE="$ACTIVATE" --env ORIV_CAPTURE_RENDERER="${ORIV_CAPTURE_RENDERER:-}" --env ORIV_SIDEBAR_COLLAPSED="${ORIV_SIDEBAR_COLLAPSED:-}" --env ORIV_GLASS_SCENE="${ORIV_GLASS_SCENE:-all}" --env ORIV_CHROME_TIMING="${ORIV_CHROME_TIMING:-}" --env ORIV_FULLSCREEN_EVIDENCE="${ORIV_FULLSCREEN_EVIDENCE:-}" --env ORIV_SCROLL_EVIDENCE="${ORIV_SCROLL_EVIDENCE:-}" --env ORIV_LIVE_SITES="${ORIV_LIVE_SITES:-}" --env ORIV_LIVE_DARK_INDICES="${ORIV_LIVE_DARK_INDICES:-}" --env ORIV_LIVE_SCROLL_INDICES="${ORIV_LIVE_SCROLL_INDICES:-}" \
    "$APP" > "$DERIVED.run.log" 2>&1 &
else
  ORIV_BACKGROUND_UI="$ORIV_BACKGROUND_UI" ORIV_FOREGROUND_UI="${ORIV_FOREGROUND_UI:-}" BROWSER_TESTING=1 ORIV_VISUAL_SNAPSHOTS=1 ORIV_SNAPSHOT_RUN_ID="$RUN_ID" ORIV_SNAPSHOT_ACTIVATE="$ACTIVATE" \
    "$APP/Contents/MacOS/Oriv-Snapshots" > "$DERIVED.run.log" 2>&1 &
fi
PID=$!
for _ in $(seq 1 "${ORIV_CAPTURE_TICKS:-240}"); do
  kill -0 $PID 2>/dev/null || break
  if [[ "$GLASS" == 1 && -f "$SRC/capture-request.json" ]]; then
    python3 -I - "$SRC" "$APP" <<'CAPTURE'
import json, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1]); request = json.loads((root / 'capture-request.json').read_text())
expected = str(pathlib.Path(sys.argv[2]).resolve() / 'Contents/MacOS/Oriv-Snapshots')
actual = subprocess.check_output(['/bin/ps', '-p', str(int(request['pid'])), '-o', 'comm='], text=True).strip()
if actual != expected: raise SystemExit('refusing another process window: ' + actual)
name = request['name']
if not name.startswith('mac-glass-') or not name.replace('-', '').isalnum(): raise SystemExit('invalid capture name')
destination = root / (name + '-live.png')
if not destination.exists() and not (root / 'capture-error.json').exists():
    temporary = root / (name + '-pending.png')
    for attempt in range(15):
        capture = subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l' + str(int(request['windowID'])), str(temporary)], capture_output=True)
        if capture.returncode == 0:
            temporary.rename(destination)
            break
        time.sleep(0.2)
    else:
        error = {'name': name, 'reason': 'owned-window capture failed: ' + capture.stderr.decode(errors='replace').strip()}
        (root / 'capture-error.json').write_text(json.dumps(error))
CAPTURE
  fi
  sleep 0.5
done
if kill -0 $PID 2>/dev/null; then kill $PID; echo "snapshot run timed out" >&2; exit 1; fi
STATUS=0; wait $PID || STATUS=$?

[[ -f "$SRC/manifest.json" ]] || { cat "$DERIVED.run.log" >&2; echo "no manifest produced (exit $STATUS)" >&2; exit 1; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
cp -p "$SRC"/manifest.json "$OUT"/
for snapshot in "$SRC"/*.png(N); do cp -p "$snapshot" "$OUT"/; done
if [[ "$GLASS" == 1 ]]; then
  for evidence in "$SRC"/*-geometry.json(N) "$SRC"/*-timing.json(N) "$SRC"/*-fullscreen.json(N) "$SRC"/*-scroll.json(N); do cp -p "$evidence" "$OUT"/; done
fi

python3 -I - "$OUT" "$RUN_ID" "$STATUS" "$GLASS" <<'PY'
import datetime, hashlib, json, os, struct, sys
out, run_id, status = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = json.load(open(os.path.join(out, "manifest.json")))
problems = []
if m["runID"] != run_id: problems.append(f"manifest is from run {m['runID']}, expected {run_id} (stale output)")
if status != 0: problems.append(f"snapshot app exited with status {status}")
problems += [f"scene failed: {f}" for f in m["failures"]]
expected = {
    "mac-01-start", "mac-02-start-empty", "mac-03-private-start", "mac-04-compact-sidebar",
    "mac-12-external-private", "mac-13-external-moved-to-personal",
    "mac-06-loaded-https", "mac-07-loaded-http", "mac-08-suggestions-keyboard", "mac-09-suggestions-similar",
    *["mac-10-library-" + pane for pane in ("bookmarks", "history", "other-devices")],
    *["mac-11-settings-" + pane for pane in ("general", "profiles", "continuity", "appearance", "privacy", "passwords", "about")],
}
if sys.argv[4] == "1": expected = {"mac-glass-" + mode for mode in ("light", "light-scrolled", "dark", "dark-scrolled", "theme", "theme-scrolled", "focused", "menu", "private", "reduced", "insecure")}
if sys.argv[4] == "1" and os.environ.get("ORIV_GLASS_SCENE", "all") != "all": expected = {"mac-glass-" + os.environ["ORIV_GLASS_SCENE"]}
if os.environ.get("ORIV_GLASS_SCENE") == "sidebar":
    expected = {"mac-glass-sidebar-" + mode for mode in ("light", "purple", "dark", "collapsed", "fullscreen", "fullscreen-collapsed", "scrolled", "inactive", "minimum", "reduced", "rtl-largest", "covered")}
if os.environ.get("ORIV_LIVE_SITES"):
    expected = {f"mac-glass-site{i+1}" for i, _ in enumerate(os.environ["ORIV_LIVE_SITES"].split(","))}
if m.get("keyWindowsRequested", m["activated"]) and sys.argv[4] != "1": expected.add("mac-05-start-inactive-window")
if os.environ.get("ORIV_BACKGROUND_UI") == "1" and os.environ.get("ORIV_FOREGROUND_UI") != "1":
    audit = m.get("backgroundUI", {})
    if not audit.get("enabled") or not audit.get("accessory") or audit.get("samples", 0) < 1:
        problems.append("background UI policy/audit missing")
    if audit.get("frontmostViolations", 1) != 0 or audit.get("activationViolations", 1) != 0 or m["activated"]:
        problems.append("test app became active/frontmost during background capture")
    if audit.get("onscreenWindowViolations", 1) != 0 or audit.get("windowFrameSamples", 0) < 1:
        problems.append("test-app window overlapped a display or frame audit missing")
    if any(not window.get("outsideAllScreens", False) for window in m.get("windows", [])):
        problems.append("captured window overlaps a display")
expected -= {reason.split(":", 1)[0] for reason in m.get("skipped", []) if reason.startswith("mac-")}
actual = [scene["name"] for scene in m["scenes"]]
if len(actual) != len(expected) or set(actual) != expected:
    problems.append(f"scene inventory mismatch: missing={sorted(expected - set(actual))}, unexpected={sorted(set(actual) - expected)}; expected {len(expected)}, got {len(actual)}")
started = datetime.datetime.fromisoformat(m["startedAt"].replace("Z", "+00:00")).timestamp()
finished = datetime.datetime.fromisoformat(m["finishedAt"].replace("Z", "+00:00")).timestamp()
if finished < started: problems.append("run finished before it started")
listed = set()
for scene in m["scenes"] + m.get("evidence", []):
    path = os.path.join(out, scene["file"]); listed.add(scene["file"])
    if not os.path.exists(path): problems.append(f"missing {scene['file']}"); continue
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != scene["sha256"]: problems.append(f"checksum mismatch {scene['file']}")
    if os.path.getmtime(path) < started: problems.append(f"stale image {scene['file']}")
    if data[:8] != b"\x89PNG\r\n\x1a\n" or tuple(struct.unpack(">II", data[16:24])) != (scene["width"], scene["height"]):
        problems.append(f"invalid PNG dimensions {scene['file']}")
    expected_key = m.get("keyWindowsRequested", m["activated"]) and scene["name"] not in {"mac-05-start-inactive-window", "mac-glass-sidebar-inactive"}
    background = m.get("backgroundUI", {}).get("enabled", False)
    key_mismatch = (scene["keyWindow"] and not expected_key) if background else scene["keyWindow"] != expected_key
    if not scene["file"].endswith("-titlebar.png") and key_mismatch: problems.append(f"window activation mismatch {scene['file']}")
extra = {f for f in os.listdir(out) if f.endswith(".png")} - listed
extra = {f for f in extra if not any(x in f for x in ("-timing-", "-floating.", "-fullscreen.", "-reveal.", "-autohide.", "-returned."))}
extra = {f for f in extra if not (os.environ.get("ORIV_LIVE_SITES") and f.endswith("-strip.png"))}
if extra: problems.append(f"images not in manifest: {sorted(extra)}")
for note in m["limitations"]: print(f"limitation: {note}")
for reason in m.get("skipped", []): print(f"skipped: {reason}")
if problems:
    print("\n".join(problems), file=sys.stderr); sys.exit(1)
print(f"{len(m['scenes'])} compositor scenes, {len(m.get('evidence', []))} evidence images, {len(m.get('skipped', []))} explicit skips verified (run {run_id}, activated={m['activated']})")
PY

{
  echo "{"
  echo "  \"runID\": \"$RUN_ID\","
  echo "  \"gitHead\": \"$(git rev-parse HEAD)\","
  echo "  \"workingTreeDiffSHA256\": \"$( { git diff HEAD; git ls-files --others --exclude-standard -z Apps Packages scripts | xargs -0 shasum -a 256; } | shasum -a 256 | cut -d' ' -f1)\","
  echo "  \"macOS\": \"$(sw_vers -productVersion) ($(sw_vers -buildVersion))\","
  echo "  \"xcode\": \"$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')\""
  echo "}"
} > "$OUT/run.json"
echo "$OUT"
