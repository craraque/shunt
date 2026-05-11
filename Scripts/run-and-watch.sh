#!/bin/bash
# Launch Shunt, capture logs for a fixed window, then kill it.
# Usage: ./Scripts/run-and-watch.sh [seconds]  (default 10)

set -euo pipefail

DURATION="${1:-10}"

pkill -f "MacOS/Shunt" 2>/dev/null || true
sleep 0.5

LOG_FILE="/tmp/shunt-$(date +%s).log"
log stream --predicate 'subsystem BEGINSWITH "com.craraque.shunt" OR eventMessage CONTAINS "com.craraque.shunt" OR (process == "sysextd" AND eventMessage CONTAINS "shunt") OR (process == "amfid" AND eventMessage CONTAINS "Shunt")' --info --debug > "$LOG_FILE" &
STREAM_PID=$!

/Applications/Shunt.app/Contents/MacOS/Shunt --auto-activate &
SHUNT_PID=$!

sleep "$DURATION"

kill "$SHUNT_PID" 2>/dev/null || true
sleep 0.5
kill "$STREAM_PID" 2>/dev/null || true
wait 2>/dev/null || true

echo "=== CAPTURED LOGS ($LOG_FILE) ==="
cat "$LOG_FILE"
