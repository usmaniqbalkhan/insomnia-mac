#!/bin/bash
# Test of the one-button timed mode: `insomnia keep <duration>`.
#
# WARNING: LOCKS THE SCREEN for the duration (default 2 minutes).
#
# Three workloads are started as ordinary processes (not through insomnia),
# the way a pipeline runs its own steps:
#   render   CPU work that appends a line every second (stands in for ffmpeg)
#   api      an HTTPS request every 5 s (stands in for API calls and uploads)
#   browser  Playwright connectOverCDP against a throwaway Chrome window
# Then `insomnia keep` locks the screen. The test checks that all three keep
# their pace behind the lock, that the Mac stays awake, and that normal power
# settings are back by themselves when the time is up.
#
# usage: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core tests/keep-test.sh [results-dir] [duration, default 2m]
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
DUR="${2:-2m}"
HELPER="$HOME/Applications/Insomnia.app/Contents/MacOS/Insomnia"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT=9397; PASS=0; FAIL=0

PW="${PLAYWRIGHT_CORE:-}"
for cand in "$HERE/../node_modules/playwright-core" "$HOME/Desktop/Claude/gemini-browsers/node_modules/playwright-core"; do
  [ -n "$PW" ] && break
  [ -d "$cand" ] && PW="$cand"
done
[ -n "$PW" ] || { echo "playwright-core not found; set PLAYWRIGHT_CORE"; exit 2; }
export PLAYWRIGHT_CORE="$PW"

check() { if [ "$1" = 0 ]; then PASS=$(( PASS + 1 )); echo "  PASS  $2"; else FAIL=$(( FAIL + 1 )); echo "  FAIL  $2"; fi; }
st()    { "$HELPER" --state 2>/dev/null | sed -n "s/^$1=//p"; }
bit()   { pmset -g | awk '$1=="SleepDisabled"{print $2; f=1} END{if(!f)print 0}'; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
ours()  { ps -axo command= | grep -c '[c]affeinate -i -m -s -w'; }

cleanup() {
  for p in "${RENDER:-}" "${API:-}" "${JOB:-}" "${CH:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  sleep 1; [ -n "${PROF:-}" ] && rm -rf "$PROF"
}
trap cleanup EXIT

START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Timed keep-running test ($DUR), $START_TS, results in $OUT"
insomnia restore >/dev/null 2>&1
PRE_BIT="$(bit)"
echo "before: SleepDisabled=$PRE_BIT, $(pmset -g batt | grep -o '[0-9]*%; [a-z ]*' | head -1)"

# ---- workloads, started the ordinary way ----
( while :; do i=0; while [ $i -lt 20000 ]; do i=$(( i + 1 )); done; date +%s >> "$OUT/render.log"; sleep 0.8; done ) &
RENDER=$!
( while :; do c="$(curl -s -o /dev/null -m 8 -w '%{http_code}' https://www.googleapis.com/discovery/v1/apis 2>/dev/null)"; echo "$(date +%s) ${c:-000}" >> "$OUT/api.log"; sleep 5; done ) &
API=$!
PROF="$(mktemp -d)"
"$CHROME" --user-data-dir="$PROF" --remote-debugging-port=$PORT --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
CH=$!
for i in $(seq 1 40); do curl -s -m 2 "http://127.0.0.1:$PORT/json/version" >/dev/null && break; sleep 0.5; done
node "$HERE/automation-job.js" $PORT 900 "$OUT/browser.jsonl" >/dev/null 2>&1 &
JOB=$!

sleep 20
R0="$(lines "$OUT/render.log")"; B0="$(lines "$OUT/browser.jsonl")"; A0="$(lines "$OUT/api.log")"
T_BASE=20

# ---- the one button ----
insomnia keep "$DUR" > "$OUT/keep.txt" 2>&1
RC=$?
T_START="$(date +%s)"
cat "$OUT/keep.txt"
check $RC "'insomnia keep $DUR' started (exit $RC)"
[ "$(st locked)" = 1 ]; check $? "screen is locked"
[ "$(st display)" = off ]; check $? "display is off"
[ "$(bit)" = 1 ] && [ "$(ours)" -ge 1 ]; check $? "sleep is disabled and the keep-awake assertion is held"
UNTIL="$(sed -n 's/^until=//p' "$APP_SUPPORT/secure")"
R1="$(lines "$OUT/render.log")"; B1="$(lines "$OUT/browser.jsonl")"; A1="$(lines "$OUT/api.log")"

LOCKED_ALL=1; AWAKE_ALL=1
while [ -f "$APP_SUPPORT/secure" ]; do
  sleep 5
  [ -f "$APP_SUPPORT/secure" ] || break
  [ "$(st locked)" = 1 ] || LOCKED_ALL=0
  [ "$(bit)" = 1 ] || AWAKE_ALL=0
  [ $(( $(date +%s) - T_START )) -gt 1800 ] && break
done
T_END="$(date +%s)"
R2="$(lines "$OUT/render.log")"; B2="$(lines "$OUT/browser.jsonl")"; A2="$(lines "$OUT/api.log")"
sleep 4
LOCKED_S=$(( T_END - T_START ))

rate() { echo "scale=2; ($2 - $1) * 60 / $3" | bc; }
echo
echo "pace per minute            before the lock    locked, display off"
echo "  render steps             $(rate 0 "$R0" $T_BASE)              $(rate "$R1" "$R2" $LOCKED_S)"
echo "  browser cycles           $(rate 0 "$B0" $T_BASE)              $(rate "$B1" "$B2" $LOCKED_S)"
echo "  API calls                $(rate 0 "$A0" $T_BASE)              $(rate "$A1" "$A2" $LOCKED_S)"
API_OK="$(awk -v s="$T_START" -v e="$T_END" '$1>=s && $1<=e && $2==200' "$OUT/api.log" | wc -l | tr -d ' ')"
API_ALL="$(awk -v s="$T_START" -v e="$T_END" '$1>=s && $1<=e' "$OUT/api.log" | wc -l | tr -d ' ')"
BR_OK="$(node -e 'const r=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(x=>x.t>=process.argv[2]*1000&&x.t<=process.argv[3]*1000);console.log(r.filter(x=>x.ok).length+"/"+r.length)' "$OUT/browser.jsonl" "$T_START" "$T_END")"
echo

keeps() { [ "$(echo "($2 - $1) * 60 / $3 >= 0.8 * $4 * 60 / $T_BASE" | bc)" = 1 ]; }
keeps "$R1" "$R2" "$LOCKED_S" "$R0"; check $? "render work kept its pace behind the lock"
keeps "$B1" "$B2" "$LOCKED_S" "$B0"; check $? "browser automation kept its pace behind the lock ($BR_OK cycles ok)"
[ "$API_ALL" -gt 0 ] && [ "$API_OK" = "$API_ALL" ]; check $? "API calls kept succeeding behind the lock ($API_OK/$API_ALL returned 200)"
[ "$LOCKED_ALL" = 1 ]; check $? "the screen stayed locked the whole time"
[ "$AWAKE_ALL" = 1 ]; check $? "sleep stayed disabled the whole time"
SLEEPS="$(pmset -g log 2>/dev/null | grep -E 'Entering Sleep' | awk -v s="$START_TS" '($1" "$2) >= s' | wc -l | tr -d ' ')"
[ "$SLEEPS" = 0 ]; check $? "the Mac never slept ($SLEEPS sleep entries in the power log)"
OFFBY=$(( T_END - UNTIL )); [ "$OFFBY" -ge -2 ] && [ "$OFFBY" -le 25 ]; check $? "it ended by itself at the chosen time (${OFFBY}s after it)"
[ "$(bit)" = 0 ] && [ "$(ours)" = 0 ] && [ ! -f "$APP_SUPPORT/session" ]; check $? "normal power settings are back: SleepDisabled=$(bit), no Insomnia assertion, no session"
kill -0 "$RENDER" 2>/dev/null && kill -0 "$API" 2>/dev/null && kill -0 "$JOB" 2>/dev/null && kill -0 "$CH" 2>/dev/null; check $? "ending the mode did not stop any of the workloads or Chrome"
echo
echo "activity log (what the window shows):"
awk -v s="$START_TS" '($1" "$2) >= s' "$HOME/Library/Logs/Insomnia/activity.log" | sed 's/^/  /'
echo
echo "RESULT: $PASS passed, $FAIL failed. The screen is still locked: unlock with your password."
[ "$FAIL" = 0 ]
