#!/bin/bash
# Sourced by the Mac and iPhone quality checks after changing to the repo root.
fixture_pids=()

stop_browser_fixtures() {
  local pid
  for pid in "${fixture_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

start_browser_fixtures() {
  local output="$1" port log pid deadline
  swift scripts/generate-media-fixtures.swift build/media-fixtures > "$output/media.log" 2>&1
  for port in 8768 18768; do
    log="$output/fixture-$port.log"
    python3 scripts/qa-server.py --port "$port" > "$log" 2>&1 &
    pid=$!
    fixture_pids+=("$pid")
    deadline=$((SECONDS + 60))
    until grep -q 'Browser QA fixture at' "$log"; do
      if ! kill -0 "$pid" 2>/dev/null || (( SECONDS >= deadline )); then
        cat "$log" >&2
        echo "The local browser fixture did not start on port $port." >&2
        return 1
      fi
      sleep 0.1
    done
  done
}
