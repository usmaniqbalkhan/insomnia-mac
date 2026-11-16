#!/bin/bash
# Lid-closed test: does everything keep running exactly as with the lid open?
#
# Start it, then CLOSE THE LID for a few minutes and open it again. It needs
# the keep-awake session (`insomnia on`) and turns it on if it is off.
# While the lid is closed it measures, every 5 seconds:
#   - two headed Chrome windows driven by Playwright connectOverCDP
#     (A: plain launcher flags, B: anti-throttling flags)
#   - ping to the router and to 1.1.1.1, and an HTTPS request to api.anthropic.com
#   - sleep bit, lock, display, Wi-Fi link, battery, thermal limit
# It ends 20 s after the lid is opened again (or after 10 minutes closed).
#
# usage: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core tests/lid-closed-test.sh [results-dir]
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
HELPER="$HOME/Applications/Insomnia.app/Contents/MacOS/Insomnia"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT_A=9395; PORT_B=9396
WAIT_FOR_CLOSE="${WAIT_FOR_CLOSE:-480}"; MAX_CLOSED="${MAX_CLOSED:-600}"

PW="${PLAYWRIGHT_CORE:-}"
for cand in "$HERE/../node_modules/playwright-core" "$HOME/Desktop/Claude/gemini-browsers/node_modules/playwright-core"; do
  [ -n "$PW" ] && break
  [ -d "$cand" ] && PW="$cand"
done
[ -n "$PW" ] || { echo "playwright-core not found; set PLAYWRIGHT_CORE"; exit 2; }
export PLAYWRIGHT_CORE="$PW"

st()    { "$HELPER" --state 2>/dev/null | sed -n "s/^$1=//p"; }
bit()   { pmset -g | awk '$1=="SleepDisabled"{print $2; f=1} END{if(!f)print 0}'; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"

sample() {
  local gw inet https therm batt
  if ping -c 1 -W 1500 -q "$GW" >/dev/null 2>&1; then gw=ok; else gw=FAIL; fi
  if ping -c 1 -W 1500 -q 1.1.1.1 >/dev/null 2>&1; then inet=ok; else inet=FAIL; fi
  https="$(curl -s -o /dev/null -m 6 -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null)"; [ -n "$https" ] && [ "$https" != 000 ] || https=FAIL
  therm="$(pmset -g therm | awk -F= '/CPU_Speed_Limit/{gsub(/[ \t]/,"",$2); print $2}')"
  batt="$(pmset -g batt | grep -o '[0-9]*%; [a-z]*' | head -1 | tr -d ' ')"
  echo "$(date +%s) $(date +%H:%M:%S) lid=$(st lid) locked=$(st locked) display=$(st display) sleepdisabled=$(bit) router=$gw internet=$inet https=$https wifi=$(ifconfig en0 | awk '/status:/{print $2}') ip=$(ipconfig getifaddr en0 2>/dev/null || echo none) therm=${therm:-100} batt=$batt cyclesA=$(lines "$OUT/a.jsonl") cyclesB=$(lines "$OUT/b.jsonl")" >> "$OUT/samples.log"
}

cleanup() {
  [ -n "${JA:-}" ] && kill "$JA" 2>/dev/null
  [ -n "${JB:-}" ] && kill "$JB" 2>/dev/null
  [ -n "${CH_A:-}" ] && kill "$CH_A" 2>/dev/null
  [ -n "${CH_B:-}" ] && kill "$CH_B" 2>/dev/null
  sleep 1
  [ -n "${PROF_A:-}" ] && rm -rf "$PROF_A"
  [ -n "${PROF_B:-}" ] && rm -rf "$PROF_B"
}
trap cleanup EXIT

: > "$OUT/samples.log"
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Lid-closed test, $START_TS, results in $OUT"
if [ ! -f "$APP_SUPPORT/session" ]; then
  insomnia on || { echo "could not turn the keep-awake session on"; exit 2; }
fi
echo "keep-awake session: on (SleepDisabled=$(bit)), lock on lid close: $(defaults read com.usman.insomnia lockOnLidClose 2>/dev/null || echo 1)"

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
node "$HERE/automation-job.js" $PORT_A 1500 "$OUT/a.jsonl" "$OUT/a-last.png" >/dev/null 2>&1 &
JA=$!
node "$HERE/automation-job.js" $PORT_B 1500 "$OUT/b.jsonl" "$OUT/b-last.png" >/dev/null 2>&1 &
JB=$!

echo "$(date +%H:%M:%S) READY: close the lid now, leave it closed for a few minutes, then open it."
T0="$(date +%s)"; T_CLOSE=0; T_OPEN=0
while :; do
  sample
  now="$(date +%s)"; lid="$(st lid)"
  if [ "$T_CLOSE" = 0 ]; then
    if [ "$lid" = closed ]; then T_CLOSE="$now"; echo "$(date +%H:%M:%S) lid closed"; fi
    if [ "$T_CLOSE" = 0 ] && [ $(( now - T0 )) -ge "$WAIT_FOR_CLOSE" ]; then echo "the lid was not closed within ${WAIT_FOR_CLOSE}s; stopping"; break; fi
  elif [ "$T_OPEN" = 0 ]; then
    if [ "$lid" = open ]; then T_OPEN="$now"; echo "$(date +%H:%M:%S) lid opened after $(( T_OPEN - T_CLOSE ))s"; fi
    if [ "$T_OPEN" = 0 ] && [ $(( now - T_CLOSE )) -ge "$MAX_CLOSED" ]; then T_OPEN="$now"; echo "$(date +%H:%M:%S) ${MAX_CLOSED}s closed; ending the measurement"; break; fi
  else
    [ $(( now - T_OPEN )) -ge 20 ] && break
  fi
  sleep 5
done
END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
[ "$T_CLOSE" = 0 ] && exit 3

node - "$OUT" "$T_CLOSE" "$T_OPEN" <<'JS'
const fs = require('fs'), [dir, tc, to] = process.argv.slice(2).map((v, i) => i ? +v : v);
const med = a => { if (!a.length) return '-'; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
const samples = fs.readFileSync(dir + '/samples.log', 'utf8').trim().split('\n').map(l => { const o = { t: +l.split(' ')[0] }; for (const kv of l.split(' ').slice(2)) { const i = kv.indexOf('='); o[kv.slice(0, i)] = kv.slice(i + 1); } return o; });
const closed = samples.filter(s => s.lid === 'closed');
const count = (k, v) => closed.filter(s => s[k] === v).length;
console.log(`\nLid closed for ${to - tc} s, ${closed.length} samples while closed`);
console.log(`  sleep disabled the whole time: ${closed.every(s => s.sleepdisabled === '1') ? 'yes' : 'NO'}`);
console.log(`  screen locked while closed:    ${count('locked', '1')}/${closed.length} samples`);
console.log(`  Wi-Fi link active:             ${count('wifi', 'active')}/${closed.length}`);
console.log(`  router ping ok:                ${count('router', 'ok')}/${closed.length}`);
console.log(`  internet ping ok (1.1.1.1):    ${count('internet', 'ok')}/${closed.length}`);
console.log(`  HTTPS to api.anthropic.com ok: ${closed.filter(s => s.https !== 'FAIL').length}/${closed.length}`);
console.log(`  IP addresses seen:             ${[...new Set(closed.map(s => s.ip))].join(', ')}`);
console.log(`  lowest CPU speed limit:        ${Math.min(...closed.map(s => +s.therm))}%   battery: ${closed[0].batt} -> ${closed[closed.length - 1].batt}`);
console.log('\nChrome automation (goto, fill, click, 6 images, download, screenshot; every 4th cycle also loads example.com)');
for (const [name, file] of [['A plain flags    ', 'a.jsonl'], ['B anti-throttling', 'b.jsonl']]) {
  let rows = [];
  try { rows = fs.readFileSync(dir + '/' + file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); } catch {}
  for (const [phase, sel] of [['lid open  ', r => r.t < tc * 1000], ['lid closed', r => r.t >= tc * 1000 && r.t < to * 1000], ['reopened  ', r => r.t >= to * 1000]]) {
    const p = rows.filter(sel), ok = p.filter(r => r.ok), net = p.filter(r => 'netMs' in r), errs = {};
    for (const r of p) for (const k of Object.keys(r)) if (k.endsWith('Err')) errs[k + ': ' + r[k]] = (errs[k + ': ' + r[k]] || 0) + 1;
    const secs = p.length ? (p[p.length - 1].t - p[0].t) / 1000 : 0;
    console.log(`  ${name} | ${phase} | cycles ${String(p.length).padStart(3)} ok ${String(ok.length).padStart(3)} | ${secs ? (p.length / secs * 60).toFixed(1) : '-'} cycles/min | median cycle ${med(p.map(r => r.cycleMs))} ms, click ${med(p.map(r => r.clickMs || 0))} ms, screenshot ${med(p.map(r => r.shotMs || 0))} ms | network ${net.filter(r => r.netTitle).length}/${net.length} | visibility ${[...new Set(p.map(r => r.vis))].join(',')} | rAF/cycle ${med(p.map(r => r.raf || 0))}`);
    for (const [e, n] of Object.entries(errs)) console.log(`        ${n}x ${e}`);
  }
}
JS
echo
echo "sleep entries in the power log during the test: $(pmset -g log 2>/dev/null | grep -E 'Entering Sleep' | awk -v s="$START_TS" '($1" "$2) >= s' | wc -l | tr -d ' ')"
echo "Wi-Fi guard log during the test:"; grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' "$HOME/Library/Logs/Insomnia/netguard.log" | awk -v s="$START_TS" '($1" "$2) >= s' | sed 's/^/  /'
echo "lid events:"; awk -v s="$START_TS" '($1" "$2) >= s' "$HOME/Library/Logs/Insomnia/insomnia.log" | grep -E "lid|lock" | sed 's/^/  /'
# ps, not pgrep: pgrep leaves out its own ancestors, and Claude may be the one running this test.
echo "Claude app running: $(ps -axo command= | grep -q '[C]laude.app/Contents/MacOS/Claude' && echo yes || echo no)"
echo "finished $END_TS"
