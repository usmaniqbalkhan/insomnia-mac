// A stand-in for a real bulk runner (gemini-browsers/run.js): it attaches to an
// already open, headed Chrome with Playwright connectOverCDP and repeats the
// same kinds of steps: goto, find the app frame, fill, click, poll with
// evaluate, download the results through fetch inside the page, one real
// network navigation, and a screenshot. One JSON line per cycle goes to <out>.
//
// usage: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core \
//        node automation-job.js <cdp-port> <seconds> <out.jsonl> [last-screenshot.png]
const fs = require('fs'), path = require('path');
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const [port, seconds, out, shotPath] = process.argv.slice(2);
const TOOL = 'file://' + path.join(__dirname, 'pages', 'tool.html');
const PROMPTS = 6;

const timed = async fn => { const t = Date.now(); try { return { v: await fn(), ms: Date.now() - t }; } catch (e) { return { err: String(e.message || e).split('\n')[0].slice(0, 140), ms: Date.now() - t }; } };

(async () => {
  let browser;
  for (let i = 0; i < 5 && !browser; i++) {
    try { browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`); }
    catch (e) { if (i === 4) throw e; await new Promise(r => setTimeout(r, 1500)); }
  }
  const ctx = browser.contexts()[0];
  const page = ctx.pages()[0] || await ctx.newPage();
  const end = Date.now() + seconds * 1000;
  for (let i = 1; Date.now() < end; i++) {
    const rec = { i, t: Date.now(), port: +port };
    const cycle = Date.now();
    const nav = await timed(() => page.goto(TOOL + '?c=' + i, { waitUntil: 'domcontentloaded', timeout: 30000 }));
    rec.gotoMs = nav.ms; if (nav.err) rec.gotoErr = nav.err;
    let frame = null;
    for (let k = 0; k < 20 && !frame; k++) {
      for (const fr of page.frames()) { try { if (await fr.$('#prompts')) { frame = fr; break; } } catch {} }
      if (!frame) await page.waitForTimeout(250);
    }
    if (frame) {
      const list = Array.from({ length: PROMPTS }, (_, k) => `cycle ${i} prompt ${k + 1}`);
      const fill = await timed(() => frame.fill('#prompts', list.join('\n'), { timeout: 15000 }));
      rec.fillMs = fill.ms; if (fill.err) rec.fillErr = fill.err;
      const click = await timed(() => frame.click('#generate-btn', { timeout: 15000 }));
      rec.clickMs = click.ms; if (click.err) rec.clickErr = click.err;
      const gen = await timed(async () => {
        for (let k = 0; k < 60; k++) {
          const n = await frame.evaluate(() => document.querySelectorAll('#out img').length);
          if (n >= 6) return n;
          await new Promise(r => setTimeout(r, 500));
        }
        throw new Error('images did not appear in 30 s');
      });
      rec.genMs = gen.ms; if (gen.err) rec.genErr = gen.err;
      const dl = await timed(() => frame.evaluate(async () => {
        let bytes = 0;
        for (const img of document.querySelectorAll('#out img')) { const r = await fetch(img.src); bytes += (await r.arrayBuffer()).byteLength; }
        return bytes;
      }));
      rec.downloadBytes = dl.v || 0; if (dl.err) rec.downloadErr = dl.err;
      const st = await timed(() => frame.evaluate(() => ({ vis: document.visibilityState, ticks: window.__ticks, raf: window.__raf })));
      if (st.v) Object.assign(rec, st.v);
    } else {
      rec.frameErr = 'app frame not found';
    }
    const shot = await timed(() => page.screenshot({ timeout: 15000, ...(shotPath ? { path: shotPath } : {}) }));
    rec.shotMs = shot.ms; if (shot.err) rec.shotErr = shot.err; else rec.shotBytes = shot.v.length;
    if (i % 4 === 0) {
      const net = await timed(async () => {
        await page.goto('https://example.com/', { waitUntil: 'domcontentloaded', timeout: 30000 });
        return page.evaluate(() => document.title);
      });
      rec.netMs = net.ms; if (net.err) rec.netErr = net.err; else rec.netTitle = net.v;
    }
    rec.cycleMs = Date.now() - cycle;
    rec.ok = !Object.keys(rec).some(k => k.endsWith('Err')) && rec.downloadBytes > 0;
    fs.appendFileSync(out, JSON.stringify(rec) + '\n');
    await new Promise(r => setTimeout(r, 1000));
  }
  await browser.close().catch(() => {});   // disconnects only; the browser stays open
  process.exit(0);
})().catch(e => { console.error('automation-job failed:', e.message); process.exit(1); });
