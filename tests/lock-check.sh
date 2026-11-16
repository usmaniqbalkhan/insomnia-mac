#!/bin/bash
# Scenario 5 on its own: input must never expose the desktop.
# LOCKS THE SCREEN for about 15 seconds; do not unlock while it runs.
# Locks, turns the display off, declares user activity (what a key press or a
# mouse move does), then checks that the session is still locked and takes a
# screenshot of what an onlooker would see.
set -u
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
HELPER="$HOME/Applications/Insomnia.app/Contents/MacOS/Insomnia"
st() { "$HELPER" --state 2>/dev/null | sed -n "s/^$1=//p"; }
insomnia display-off || exit 2
echo "after display-off:        locked=$(st locked) display=$(st display)"
sleep 4
caffeinate -u -t 2 &
sleep 3
L="$(st locked)"; D="$(st display)"
echo "after simulated input:    locked=$L display=$D"
if screencapture -x "$OUT/onlooker-view.png" 2>/dev/null; then echo "screenshot: $OUT/onlooker-view.png"; else echo "screencapture refused to capture while locked"; fi
sleep 1
echo "3 s later:                locked=$(st locked) display=$(st display)"
if [ "$L" = 1 ]; then echo "PASS  the session stayed locked after input (display=$D)"; else echo "FAIL  the session is not locked (did someone unlock it during the test?)"; exit 1; fi
