#!/bin/zsh
# Renders the real Mac views with synthetic data into PNGs (Debug-only snapshot mode) and
# verifies them against the run's manifest. Uses a separate bundle identity and ephemeral
# BROWSER_TESTING state; never touches installed apps or their data.
#
# usage: scripts/capture-mac-visuals.sh [--active] [output-directory]
#   --active   make the snapshot app frontmost so windows render in their active (key) state.
#              This briefly takes keyboard focus from the frontmost app.
#   The output directory must not exist or must be empty. Default: build/visual-runs/<timestamp>-mac
set -euo pipefail
cd "$(dirname "$0")/.."
ACTIVATE=0
if [[ "${1:-}" == "--active" ]]; then ACTIVATE=1; shift; fi
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

BROWSER_TESTING=1 ORIV_VISUAL_SNAPSHOTS=1 ORIV_SNAPSHOT_RUN_ID="$RUN_ID" ORIV_SNAPSHOT_ACTIVATE="$ACTIVATE" \
  "$APP/Contents/MacOS/Oriv-Snapshots" > "$DERIVED.run.log" 2>&1 &
PID=$!
for _ in {1..240}; do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
if kill -0 $PID 2>/dev/null; then kill $PID; echo "snapshot run timed out" >&2; exit 1; fi
STATUS=0; wait $PID || STATUS=$?

[[ -f "$SRC/manifest.json" ]] || { cat "$DERIVED.run.log" >&2; echo "no manifest produced (exit $STATUS)" >&2; exit 1; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
cp -p "$SRC"/manifest.json "$SRC"/*.png "$OUT"/ 2>/dev/null || true

python3 -I - "$OUT" "$RUN_ID" "$STATUS" <<'PY'
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
if m["activated"]: expected.add("mac-05-start-inactive-window")
actual = [scene["name"] for scene in m["scenes"]]
if len(actual) != len(expected) or set(actual) != expected:
    problems.append(f"scene inventory mismatch: missing={sorted(expected - set(actual))}, unexpected={sorted(set(actual) - expected)}; expected {len(expected)}, got {len(actual)}")
started = datetime.datetime.fromisoformat(m["startedAt"].replace("Z", "+00:00")).timestamp()
finished = datetime.datetime.fromisoformat(m["finishedAt"].replace("Z", "+00:00")).timestamp()
if finished < started: problems.append("run finished before it started")
listed = set()
for scene in m["scenes"]:
    path = os.path.join(out, scene["file"]); listed.add(scene["file"])
    if not os.path.exists(path): problems.append(f"missing {scene['file']}"); continue
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != scene["sha256"]: problems.append(f"checksum mismatch {scene['file']}")
    if os.path.getmtime(path) < started: problems.append(f"stale image {scene['file']}")
    if data[:8] != b"\x89PNG\r\n\x1a\n" or tuple(struct.unpack(">II", data[16:24])) != (scene["width"], scene["height"]):
        problems.append(f"invalid PNG dimensions {scene['file']}")
    expected_key = m["activated"] and scene["name"] != "mac-05-start-inactive-window"
    if scene["keyWindow"] != expected_key: problems.append(f"window activation mismatch {scene['file']}")
extra = {f for f in os.listdir(out) if f.endswith(".png")} - listed
if extra: problems.append(f"images not in manifest: {sorted(extra)}")
for note in m["limitations"]: print(f"limitation: {note}")
if problems:
    print("\n".join(problems), file=sys.stderr); sys.exit(1)
print(f"{len(m['scenes'])} scenes verified (run {run_id}, activated={m['activated']})")
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
