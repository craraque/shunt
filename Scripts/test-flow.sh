#!/bin/bash
# Enables Shunt, runs ShuntTest (which should egress via upstream provider),
# then tears down the VPN config entirely. Total time ~5-10s.
# Non-Shunt apps may briefly see VPN-on during this window.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
TEST_APP="$BUILD_DIR/ShuntTest.app"

if [[ ! -d "$TEST_APP" ]]; then
    echo "ERROR: $TEST_APP not found — run ./Scripts/build.sh notarize first"
    exit 1
fi

echo "▸ Baseline — direct egress"
BASELINE=$(curl -s --max-time 5 https://ifconfig.me || echo "curl-failed")
echo "  host direct → $BASELINE"
echo

echo "▸ Launching Shunt (auto-activate + auto-enable)"
pkill -f "MacOS/Shunt" 2>/dev/null || true
sleep 0.3
/Applications/Shunt.app/Contents/MacOS/Shunt --auto-activate --auto-enable > /dev/null 2>&1 &
SHUNT_PID=$!
sleep 3

echo "▸ Running ShuntTest (claimed: com.craraque.shunt.test → ifconfig.me/io/ipinfo)"
"$TEST_APP/Contents/MacOS/ShuntTest"
echo

echo "▸ Tearing down: kill Shunt + remove VPN config"
kill "$SHUNT_PID" 2>/dev/null || true
sleep 0.5
# Remove the config via a lightweight in-process call
# (the main Shunt app, if invoked with --remove-config, handles this; for now we trust
# the next test invocation to rewrite the same config).
echo "  (NOTE: VPN config remains registered but tunnel is stopped and provider exits shortly)"
echo "  For full cleanup, manually remove 'Shunt' in System Settings → VPN"
echo

echo "▸ Verify baseline unaffected after test"
AFTER=$(curl -s --max-time 5 https://ifconfig.me || echo "curl-failed")
echo "  host direct → $AFTER"
if [[ "$BASELINE" != "$AFTER" ]]; then
    echo "  ⚠️  baseline changed!"
fi
