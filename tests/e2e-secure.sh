#!/bin/bash
# End-to-end test of Secure Background Mode.
#
# WARNING: this LOCKS THE SCREEN and turns the display off for about three
# minutes. You unlock with your password afterwards, as usual.
#
# It opens two throwaway Chrome windows (temporary profiles, CDP ports 9391 and
# 9392; your own Chrome and profiles are not touched), drives both with
# Playwright connectOverCDP the way a bulk runner does, and checks:
#   1. automation with the display on            6. several jobs at once
#   2. turning the mode on mid-run               7. auto-release when jobs finish
#   3. automation with the display off           8. battery and thermal readings
#   4. the Mac stays awake                       9. job failure + monitor crash
#   5. waking the display shows only the lock   10. hardware check (doctor)
#
# usage: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core tests/e2e-secure.sh [results-dir]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
HELPER="$HOME/Applications/Insomnia.app/Contents/MacOS/Insomnia"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT_A=9391; PORT_B=9392
JOB_SECONDS="${JOB_SECONDS:-170}"
PASS=0; FAIL=0

PW="${PLAYWRIGHT_CORE:-}"
for cand in "$HERE/../node_modules/playwright-core" "$HOME/Desktop/Claude/gemini-browsers/node_modules/playwright-core"; do
  [ -n "$PW" ] && break
  [ -d "$cand" ] && PW="$cand"
done
[ -n "$PW" ] || { echo "playwright-core not found; set PLAYWRIGHT_CORE"; exit 2; }
export PLAYWRIGHT_CORE="$PW"

say()   { echo "$*" | tee -a "$OUT/report.txt"; }
check() { if [ "$1" = 0 ]; then PASS=$(( PASS + 1 )); say "  PASS  $2"; else FAIL=$(( FAIL + 1 )); say "  FAIL  $2"; fi; }
st()    { "$HELPER" --state 2>/dev/null | sed -n "s/^$1=//p"; }
bit()   { pmset -g | awk '$1=="SleepDisabled"{print $2; f=1} END{if(!f)print 0}'; }
jobst() { sed -n "s/^$2=//p" "$APP_SUPPORT/jobs/$1.job" 2>/dev/null | head -1; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

sample() {
  local caf asr batt therm load
  caf="$(sed -n 's/^caffeinate_pid=//p' "$APP_SUPPORT/secure.run" 2>/dev/null)"
  if [ -n "$caf" ] && ps -p "$caf" >/dev/null 2>&1; then caf=alive; else caf=none; fi
  asr="$(pmset -g assertions | grep -c 'caffeinate command-line tool')"
  batt="$(pmset -g batt | grep -o '[0-9]*%' | head -1)"
  therm="$(pmset -g therm | awk -F= '/CPU_Speed_Limit/{gsub(/[ \t]/,"",$2); print $2}')"
  load="$(sysctl -n vm.loadavg | awk '{print $2}')"
  echo "$(date +%H:%M:%S) $1 locked=$(st locked) display=$(st display) lid=$(st lid) sleepdisabled=$(bit) caffeinate=$caf assertions=$asr batt=$batt therm=${therm:-100} load=$load cyclesA=$(lines "$OUT/a.jsonl") cyclesB=$(lines "$OUT/b.jsonl")" >> "$OUT/samples.log"
}

cleanup() {
  [ -n "${CH_A:-}" ] && kill "$CH_A" 2>/dev/null
  [ -n "${CH_B:-}" ] && kill "$CH_B" 2>/dev/null
  sleep 1
  [ -n "${PROF_A:-}" ] && rm -rf "$PROF_A"
  [ -n "${PROF_B:-}" ] && rm -rf "$PROF_B"
}
trap cleanup EXIT

: > "$OUT/report.txt"; : > "$OUT/samples.log"
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
say "Secure Background Mode end-to-end test, $START_TS"
say "results: $OUT"

# ---- preflight ----
if [ -f "$APP_SUPPORT/secure" ]; then insomnia secure off >/dev/null 2>&1; sleep 2; fi
insomnia jobs clear >/dev/null 2>&1
PRE_BIT="$(bit)"; PRE_SESSION=0; [ -f "$APP_SUPPORT/session" ] && PRE_SESSION=1
say "before: SleepDisabled=$PRE_BIT, keep-awake session=$PRE_SESSION, battery $(pmset -g batt | grep -o '[0-9]*%; [a-z ]*' | head -1)"
insomnia doctor > "$OUT/doctor.txt" 2>&1
check $? "10. hardware and macOS compatibility check (insomnia doctor)"

# ---- two throwaway browsers, opened the way open-batch.js opens them ----
PROF_A="$(mktemp -d)"; PROF_B="$(mktemp -d)"
"$CHROME" --user-data-dir="$PROF_A" --remote-debugging-port=$PORT_A --no-first-run --no-default-browser-check \
  --window-position=40,60 --window-size=640,640 about:blank >/dev/null 2>&1 &
CH_A=$!
"$CHROME" --user-data-dir="$PROF_B" --remote-debugging-port=$PORT_B --no-first-run --no-default-browser-check \
  --window-position=720,60 --window-size=640,640 \
  --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling \
  about:blank >/dev/null 2>&1 &
CH_B=$!
for i in $(seq 1 40); do
  curl -s -m 2 "http://127.0.0.1:$PORT_A/json/version" >/dev/null && curl -s -m 2 "http://127.0.0.1:$PORT_B/json/version" >/dev/null && break
  sleep 0.5
done
curl -s -m 2 "http://127.0.0.1:$PORT_B/json/version" >/dev/null || { say "test browsers did not start"; exit 2; }

# ---- four concurrent jobs ----
JA="$(insomnia run --detach --name "automation A (plain launcher flags)" -- node "$HERE/automation-job.js" $PORT_A "$JOB_SECONDS" "$OUT/a.jsonl" "$OUT/a-last.png")"
JB="$(insomnia run --detach --name "automation B (anti-throttling flags)" -- node "$HERE/automation-job.js" $PORT_B "$JOB_SECONDS" "$OUT/b.jsonl" "$OUT/b-last.png")"
JS="$(insomnia run --detach --name "plain job (sleep 70)" -- sleep 70)"
JF="$(insomnia run --detach --name "failing job (exit 3 after 45 s)" -- bash -c 'sleep 45; echo "simulated automation error" >&2; exit 3')"
say "jobs: A=$JA B=$JB sleeper=$JS failer=$JF"

# ---- phase 1: display on ----
for i in 1 2 3 4 5; do sleep 5; sample display-on; done
BASE_A="$(lines "$OUT/a.jsonl")"; BASE_B="$(lines "$OUT/b.jsonl")"
[ "$BASE_A" -ge 2 ] && [ "$BASE_B" -ge 2 ]
check $? "1. automation runs with the display on ($BASE_A and $BASE_B cycles in 25 s)"
insomnia secure status > "$OUT/status-before-lock.txt" 2>&1

# ---- phase 2: turn the mode on mid-run ----
insomnia secure on --grace 20 > "$OUT/secure-on.txt" 2>&1
RC=$?
T_LOCKED="$(date +%s)"
cat "$OUT/secure-on.txt" >> "$OUT/report.txt"
check $RC "2. Secure Background Mode turned on during a running automation (exit $RC)"
[ "$(st locked)" = 1 ]; check $? "   screen is locked"
[ "$(st display)" = off ]; check $? "   display is off"
sample just-locked

DID_WAKE=0; DID_CRASH=0; UNLOCKED_SEEN=0; AWAKE_FAIL=0
while :; do
  sleep 5
  sample locked
  el=$(( $(date +%s) - T_LOCKED ))
  [ "$(st locked)" = 1 ] || UNLOCKED_SEEN=1
  if [ -f "$APP_SUPPORT/secure" ] && [ "$(bit)" != 1 ]; then AWAKE_FAIL=1; fi

  if [ "$DID_WAKE" = 0 ] && [ "$el" -ge 30 ]; then
    DID_WAKE=1
    caffeinate -u -t 2 &            # declares user activity, as a key press or mouse move does
    sleep 3
    W_LOCK="$(st locked)"; W_DISP="$(st display)"
    screencapture -x "$OUT/after-wake.png" 2>/dev/null
    sample after-simulated-input
    insomnia display-off > "$OUT/display-off.txt" 2>&1
    W_OFF="$(st display)"
  fi

  if [ "$DID_CRASH" = 0 ] && [ "$el" -ge 60 ]; then
    DID_CRASH=1
    MP="$(sed -n 's/^monitor_pid=//p' "$APP_SUPPORT/secure.run" 2>/dev/null)"
    kill -9 "$MP" 2>/dev/null
    T0="$(date +%s)"; RECOVER=-1
    for i in $(seq 1 60); do
      sleep 0.5
      NP="$(sed -n 's/^monitor_pid=//p' "$APP_SUPPORT/secure.run" 2>/dev/null)"
      NC="$(sed -n 's/^caffeinate_pid=//p' "$APP_SUPPORT/secure.run" 2>/dev/null)"
      if [ -n "$NP" ] && [ "$NP" != "$MP" ] && ps -p "$NP" >/dev/null 2>&1 && [ -n "$NC" ] && ps -p "$NC" >/dev/null 2>&1; then
        RECOVER=$(( $(date +%s) - T0 )); break
      fi
    done
    sample after-monitor-crash
  fi

  if [ "$(jobst "$JA" status)" != running ] && [ "$(jobst "$JB" status)" != running ]; then break; fi
  [ "$el" -ge $(( JOB_SECONDS + 90 )) ] && break
done
T_JOBS_DONE="$(date +%s)"

# ---- phase 3: auto-release ----
RELEASED=-1
for i in $(seq 1 90); do
  if [ ! -f "$APP_SUPPORT/secure" ]; then RELEASED=$(( $(date +%s) - T_JOBS_DONE )); break; fi
  sleep 1
done
sleep 3
sample after-release
insomnia secure status > "$OUT/status-after.txt" 2>&1
insomnia jobs > "$OUT/jobs-after.txt" 2>&1
END_TS="$(date '+%Y-%m-%d %H:%M:%S')"

# ---- results ----
node - "$OUT" "$T_LOCKED" >> "$OUT/report.txt" <<'EOF'
const fs = require('fs'), [dir, tLocked] = process.argv.slice(2);
const med = a => { if (!a.length) return '-'; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
console.log('\nAutomation cycles (each: goto, fill, click, 6 images, download, screenshot; every 4th also loads example.com)');
for (const [name, file] of [['A plain flags', 'a.jsonl'], ['B anti-throttle', 'b.jsonl']]) {
  let rows = [];
  try { rows = fs.readFileSync(dir + '/' + file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); } catch {}
  for (const [phase, sel] of [['display on ', r => r.t < tLocked * 1000], ['locked, off', r => r.t >= tLocked * 1000]]) {
    const p = rows.filter(sel), ok = p.filter(r => r.ok);
    const errs = {};
    for (const r of p) for (const k of Object.keys(r)) if (k.endsWith('Err')) errs[k + ': ' + r[k]] = (errs[k + ': ' + r[k]] || 0) + 1;
    const net = p.filter(r => 'netMs' in r);
    console.log(`  ${name} | ${phase} | cycles ${String(p.length).padStart(3)} ok ${String(ok.length).padStart(3)} | median cycle ${med(p.map(r => r.cycleMs))} ms, click ${med(p.map(r => r.clickMs || 0))} ms, images ${med(p.map(r => r.genMs || 0))} ms, screenshot ${med(p.map(r => r.shotMs || 0))} ms | network ${net.filter(r => r.netTitle).length}/${net.length} | visibility ${[...new Set(p.map(r => r.vis))].join(',')} | rAF/cycle ${med(p.map(r => r.raf || 0))}`);
    for (const [e, n] of Object.entries(errs)) console.log(`      ${n}x ${e}`);
  }
}
EOF
cat "$OUT/report.txt" | sed -n '/Automation cycles/,$p'

okA="$(node -e 'const r=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(r=>r.t>=process.argv[2]*1000);console.log(r.length&&r.every(x=>x.ok)?r.length:0)' "$OUT/a.jsonl" "$T_LOCKED" 2>/dev/null || echo 0)"
okB="$(node -e 'const r=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(r=>r.t>=process.argv[2]*1000);console.log(r.length&&r.every(x=>x.ok)?r.length:0)' "$OUT/b.jsonl" "$T_LOCKED" 2>/dev/null || echo 0)"
[ "${okA:-0}" -gt 0 ]; check $? "3. automation A (plain flags) kept working locked with the display off (${okA:-0} cycles, all ok)"
[ "${okB:-0}" -gt 0 ]; check $? "3. automation B (anti-throttling flags) kept working locked with the display off (${okB:-0} cycles, all ok)"

SLEEPS="$(pmset -g log 2>/dev/null | grep -E 'Entering Sleep' | awk -v s="$START_TS" '($1" "$2) >= s' | wc -l | tr -d ' ')"
[ "$SLEEPS" = 0 ] && [ "$AWAKE_FAIL" = 0 ]; check $? "4. the Mac stayed awake ($SLEEPS sleep entries in the power log, sleep kept disabled)"
[ "${W_LOCK:-0}" = 1 ] && [ "$UNLOCKED_SEEN" = 0 ]; check $? "5. after simulated input the session stayed locked (display=${W_DISP:-?}; after 'display-off' display=${W_OFF:-?}). A fail here also happens if someone really unlocks during the test."
[ "$(jobst "$JA" status)" = completed ] && [ "$(jobst "$JB" status)" = completed ] && [ "$(jobst "$JS" status)" = completed ]
check $? "6. concurrent jobs tracked to completion (A=$(jobst "$JA" status), B=$(jobst "$JB" status), sleeper=$(jobst "$JS" status))"
[ "$RELEASED" -ge 0 ] && [ "$(bit)" = "$PRE_BIT" ] && ! pgrep -f "caffeinate -i -m -s -w" >/dev/null
check $? "7. auto-release ${RELEASED}s after the last job (grace 20 s): assertion gone, SleepDisabled back to $PRE_BIT"
THERM_MIN="$(sed -n 's/.*therm=\([0-9]*\).*/\1/p' "$OUT/samples.log" | sort -n | head -1)"
LOAD_MAX="$(sed -n 's/.*load=\([0-9.]*\).*/\1/p' "$OUT/samples.log" | sort -n | tail -1)"
B0="$(sed -n '1s/.*batt=\([0-9]*\)%.*/\1/p' "$OUT/samples.log")"; B1="$(sed -n '$s/.*batt=\([0-9]*\)%.*/\1/p' "$OUT/samples.log")"
[ "${THERM_MIN:-100}" -ge 80 ]; check $? "8. thermal: lowest CPU speed limit ${THERM_MIN:-?}%, peak load $LOAD_MAX, battery ${B0:-?}% -> ${B1:-?}%"
[ "$(jobst "$JF" status)" = failed ] && [ "$(jobst "$JF" exit)" = 3 ]; check $? "9. failing job recorded as failed with exit code $(jobst "$JF" exit)"
[ "${RECOVER:--1}" -ge 0 ]; check $? "9. monitor killed with SIGKILL came back with a new sleep assertion in ${RECOVER:-?}s"

say ""
say "jobs:"; cat "$OUT/jobs-after.txt" | tee -a "$OUT/report.txt"
say ""
say "session log:"; awk -v s="$START_TS" '($1" "$2) >= s' "$HOME/Library/Logs/Insomnia/secure.log" | tee -a "$OUT/report.txt"
say ""
say "RESULT: $PASS passed, $FAIL failed ($START_TS to $END_TS). The screen is still locked: unlock with your password."
[ "$FAIL" = 0 ]
