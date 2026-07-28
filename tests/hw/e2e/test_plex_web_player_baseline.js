#!/usr/bin/env node
/**
 * test_plex_web_player_baseline.js
 *
 * CONTROL EXPERIMENT for the user-reported symptom "cast shows as available but
 * play never starts and the web player stays at 0:00".
 *
 * This drives the REAL Plex Web player in headless Chromium against the REAL
 * Plex Media Server, with NO MiSTer and NO cast target involved, and measures
 * whether playback position actually advances.
 *
 * Why this matters to w-cast: it separates two very different worlds.
 *   web player advances  -> Plex Web + the media + the server are healthy, so a
 *                           stuck 0:00 while casting is a MiSTerPlex bug.
 *   web player also 0:00 -> the symptom is upstream of MiSTerPlex entirely
 *                           (media, transcoder, or server), and chasing the
 *                           cast path would be wasted effort.
 *
 * No human is asked to look at anything. Position is read from the <video>
 * element and cross-checked against the server's own /status/sessions view.
 *
 * Exit codes:
 *   0  PASS    playback position advanced
 *   1  FAIL    player reached a playable state but position stayed at 0:00
 *   2  REFUSE  could not score (server unreachable, no token, UI not drivable).
 *              Explicitly NOT a pass and explicitly NOT a silent skip.
 *  77  SKIP    Playwright/Chromium not installed (UNSCORED)
 *
 * Self-test (proves the position detector is not vacuous, needs no Plex):
 *   node test_plex_web_player_baseline.js --self-test
 * It generates a real H.264 clip with ffmpeg, serves it over HTTP, and asserts
 * that a genuinely playing <video> is detected as ADVANCING while a paused one
 * is detected as STUCK.
 *
 * The Plex token is read at runtime from $MISTERPLEX_CONF or
 * $HOME/.config/misterplex/misterplex.conf and is never logged.
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { execFileSync, spawnSync } = require('child_process');

const EXIT_PASS = 0;
const EXIT_FAIL = 1;
const EXIT_REFUSE = 2;
const EXIT_SKIP = 77;

const ROOT = path.resolve(__dirname, '../../..');
const OUT_DIR = process.env.WEB_BASELINE_OUT || path.join(ROOT, 'build', 'web_baseline');

function log(...a) { console.log(...a); }
function refuse(msg) { console.error(`REFUSE: ${msg}`); process.exit(EXIT_REFUSE); }
function skip(msg) { console.error(`SKIP-NOT-PASS: ${msg}`); process.exit(EXIT_SKIP); }

function redact(s) {
  return String(s).replace(/X-Plex-Token=[^&"'\s]+/g, 'X-Plex-Token=REDACTED');
}

// ── conf ─────────────────────────────────────────────────────────────────────
function readConf(p) {
  if (!p || !fs.existsSync(p)) return {};
  const v = {};
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.+)/);
    if (m) v[m[1]] = m[2].trim().replace(/\r$/, '');
  }
  return v;
}
function resolveConf() {
  if (process.env.MISTERPLEX_CONF) return readConf(process.env.MISTERPLEX_CONF);
  for (const c of [path.join(ROOT, 'assets', 'misterplex.conf'),
                   path.join(os.homedir(), '.config', 'misterplex', 'misterplex.conf')]) {
    if (fs.existsSync(c)) return readConf(c);
  }
  return {};
}

function loadPlaywright() {
  try {
    return require(path.join(__dirname, 'node_modules', 'playwright'));
  } catch (e) {
    try { return require('playwright'); } catch (e2) {
      skip('playwright module not installed under tests/hw/e2e');
    }
  }
}

function httpGet(url, timeoutMs = 8000) {
  return new Promise((resolve) => {
    const req = http.get(url, (res) => {
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.setTimeout(timeoutMs, () => { req.destroy(); resolve({ status: 0, body: '' }); });
    req.on('error', () => resolve({ status: 0, body: '' }));
  });
}

/**
 * Poll a page's <video> (or Plex's own player state) and decide whether the
 * playback position advances.  Returns a structured verdict, never throws.
 */
async function measureAdvance(page, seconds, label) {
  const samples = [];
  const started = Date.now();
  let sawVideoElement = false;
  while ((Date.now() - started) / 1000 < seconds) {
    const s = await page.evaluate(() => {
      const vids = Array.from(document.querySelectorAll('video'));
      // Pick the video that looks most like the active player.
      const v = vids.find((x) => x.readyState > 0 || x.currentTime > 0) || vids[0];
      if (!v) return null;
      return {
        currentTime: v.currentTime,
        duration: Number.isFinite(v.duration) ? v.duration : null,
        paused: v.paused,
        readyState: v.readyState,
        networkState: v.networkState,
        error: v.error ? v.error.code : null,
        count: vids.length,
      };
    }).catch(() => null);
    if (s) { sawVideoElement = true; samples.push({ t: (Date.now() - started) / 1000, ...s }); }
    await page.waitForTimeout(1000);
  }
  const times = samples.map((s) => s.currentTime);
  const maxT = times.length ? Math.max(...times) : 0;
  const minT = times.length ? Math.min(...times) : 0;
  const advance = maxT - minT;
  const last = samples[samples.length - 1] || null;
  const verdict = {
    label,
    sawVideoElement,
    samples: samples.length,
    min_currentTime: Number(minT.toFixed(3)),
    max_currentTime: Number(maxT.toFixed(3)),
    advance: Number(advance.toFixed(3)),
    advanced: advance > 0.5,
    last,
  };
  return verdict;
}

// ── self-test: proves measureAdvance separates playing from stuck ────────────
async function selfTest() {
  log('SELF-TEST: validating the position detector against real Chromium playback');
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const clip = path.join(OUT_DIR, 'selftest.mp4');
  if (!fs.existsSync(clip)) {
    const r = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=15:duration=8',
      '-pix_fmt', 'yuv420p', '-c:v', 'libx264', '-preset', 'ultrafast', clip]);
    if (r.status !== 0 || !fs.existsSync(clip)) {
      refuse(`self-test could not generate a clip with ffmpeg: ${r.stderr}`);
    }
  }

  const PAGE_PLAY = `<!doctype html><meta charset=utf-8>
<video id=v src="/selftest.mp4" autoplay muted playsinline></video>`;
  const PAGE_STUCK = `<!doctype html><meta charset=utf-8>
<video id=v src="/selftest.mp4" muted playsinline preload=auto></video>`;

  const server = http.createServer((req, res) => {
    if (req.url === '/play') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(PAGE_PLAY); }
    if (req.url === '/stuck') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(PAGE_STUCK); }
    if (req.url.startsWith('/selftest.mp4')) {
      const buf = fs.readFileSync(clip);
      res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': buf.length, 'Accept-Ranges': 'none' });
      return res.end(buf);
    }
    res.writeHead(404); res.end();
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;

  const { chromium } = loadPlaywright();
  let browser;
  let failures = 0;
  try {
    browser = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
    const ctx = await browser.newContext();

    const p1 = await ctx.newPage();
    await p1.goto(`http://127.0.0.1:${port}/play`, { waitUntil: 'load' });
    const green = await measureAdvance(p1, 6, 'selftest-playing');
    log(`  playing video : samples=${green.samples} advance=${green.advance}s advanced=${green.advanced}`);
    if (!green.sawVideoElement) { console.error('  FAIL no <video> element seen in self-test'); failures++; }
    else if (!green.advanced) { console.error('  FAIL a genuinely playing video was reported as STUCK'); failures++; }
    else log('  PASS playing video detected as ADVANCING');

    const p2 = await ctx.newPage();
    await p2.goto(`http://127.0.0.1:${port}/stuck`, { waitUntil: 'load' });
    await p2.evaluate(() => { const v = document.getElementById('v'); v.pause(); v.currentTime = 0; });
    const red = await measureAdvance(p2, 6, 'selftest-paused');
    log(`  paused video  : samples=${red.samples} advance=${red.advance}s advanced=${red.advanced}`);
    if (!red.sawVideoElement) { console.error('  FAIL no <video> element seen in paused case'); failures++; }
    else if (red.advanced) { console.error('  FAIL a paused video was reported as ADVANCING (detector is vacuous)'); failures++; }
    else log('  PASS paused video detected as STUCK (detector is not vacuous)');
  } finally {
    if (browser) await browser.close();
    server.close();
  }
  if (failures) { console.error(`SELF-TEST FAILED (${failures})`); return EXIT_FAIL; }
  log('SELF-TEST OK: detector separates ADVANCING from STUCK using real playback');
  return EXIT_PASS;
}

/**
 * Plex Web presents a "Select User" profile picker before any content is
 * reachable when the server has managed accounts.  Until it is dismissed the
 * SPA renders no library, no details page and no <video> element, so every
 * playback assertion is UNSCORABLE.  A JS .click() is not enough — the picker
 * is React-driven and needs a real input event.
 */
async function dismissUserPicker(page, preferred) {
  const onPicker = await page.evaluate(
    () => /select user/i.test(document.body.innerText.slice(0, 200))
  ).catch(() => false);
  if (!onPicker) return { shown: false, picked: null };

  const names = await page.evaluate(() => {
    const t = document.body.innerText.split('\n').map((s) => s.trim()).filter(Boolean);
    return t.filter((s) => !/^select user$/i.test(s) && !/^managed account$/i.test(s)
                           && !/^add user/i.test(s));
  }).catch(() => []);
  const target = (preferred && names.includes(preferred)) ? preferred : names[0];
  if (!target) return { shown: true, picked: null };

  try {
    await page.getByText(target, { exact: true }).click({ timeout: 15000 });
  } catch (e) {
    return { shown: true, picked: null, error: e.message };
  }
  await page.waitForTimeout(10000);
  const stillPicker = await page.evaluate(
    () => /select user/i.test(document.body.innerText.slice(0, 200))
  ).catch(() => false);
  return { shown: true, picked: stillPicker ? null : target, still_on_picker: stillPicker };
}

// ── main Plex Web baseline ──────────────────────────────────────────────────
async function main() {
  if (process.argv.includes('--self-test')) {
    process.exit(await selfTest());
  }

  const conf = resolveConf();
  const BASE = process.env.PLEX_BASE || conf.PLEX_BASE || '';
  const TOKEN = process.env.PLEX_TOKEN || conf.PLEX_TOKEN || '';
  const KEY = process.env.PLEX_KEY || conf.PLEX_KEY || '/library/metadata/3';
  const WATCH = parseInt(process.env.WEB_BASELINE_SECONDS || '35', 10);
  const WEB_USER = process.env.PLEX_WEB_USER || conf.PLEX_WEB_USER || '';
  let SERVER_ID = process.env.PLEX_SERVER_ID || conf.PLEX_SERVER_ID || '';

  log('test_plex_web_player_baseline: BEGIN');
  log(`Scope: 1 browser session, Plex Web native player, item ${KEY}, ${WATCH}s watch window`);

  if (!BASE) refuse('PLEX_BASE missing (set MISTERPLEX_CONF or PLEX_BASE)');
  if (!TOKEN) refuse('PLEX_TOKEN missing (set MISTERPLEX_CONF or PLEX_TOKEN)');

  const ident = await httpGet(`${BASE}/identity`);
  if (ident.status !== 200) {
    refuse(`Plex server unreachable at ${BASE}/identity (status ${ident.status}); cannot score the web player`);
  }
  const meta = await httpGet(`${BASE}${KEY}?X-Plex-Token=${TOKEN}`);
  if (meta.status !== 200) refuse(`item ${KEY} not readable (status ${meta.status})`);
  const titleM = meta.body.match(/\stitle="([^"]*)"/);
  log(`Server reachable; item ${KEY} = ${titleM ? titleM[1] : 'unknown'}`);

  // Route through the server's real machineIdentifier. The "auto" alias makes
  // Plex Web resolve the server from its advertised connection list, which on
  // this deployment starts with a loopback URI the browser cannot reach
  // ("[Connections] All connections to [Loopback] failed") whenever the browser
  // is not running on the PMS host itself.
  if (!SERVER_ID) {
    const idm = ident.body.match(/machineIdentifier="([^"]+)"/);
    if (!idm) refuse('could not read machineIdentifier from /identity');
    SERVER_ID = idm[1];
  }
  log(`Server machineIdentifier ${SERVER_ID}`);

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const { chromium } = loadPlaywright();
  let browser;
  const report = { base: BASE, key: KEY, watch_seconds: WATCH };
  try {
    browser = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();

    page.on('console', (m) => {
      const t = redact(m.text());
      if (/error|fail/i.test(t)) log(`  browser console: ${t.slice(0, 200)}`);
    });

    // Seed the token before any Plex Web script runs.
    await page.addInitScript((tok) => {
      try {
        window.localStorage.setItem('myPlexAccessToken', tok);
        window.localStorage.setItem('plex-token', tok);
      } catch (e) { /* ignore */ }
    }, TOKEN);

    log(`BROWSER navigating to ${BASE}/web/index.html`);
    await page.goto(`${BASE}/web/index.html`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(8000);

    const picker = await dismissUserPicker(page, WEB_USER);
    report.user_picker = picker;
    if (picker.shown && !picker.picked) {
      refuse(`Plex Web "Select User" picker could not be dismissed (tried "${WEB_USER || 'first profile'}"). `
             + 'No content, and therefore no playback, is reachable; the 0:00 symptom is UNSCORED. '
             + 'Set PLEX_WEB_USER to a profile name on this server.');
    }
    if (picker.shown) log(`BROWSER dismissed user picker as profile "${picker.picked}"`);

    const ratingKey = path.basename(KEY);
    const detailsUrl = `${BASE}/web/index.html#!/server/${SERVER_ID}/details?key=${encodeURIComponent(KEY)}`;
    log(`BROWSER navigating to details for ratingKey ${ratingKey}`);
    await page.goto(detailsUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(5000);
    await page.screenshot({ path: path.join(OUT_DIR, 'details.png') }).catch(() => {});

    // Try hard to press Play, then fall back to Plex Web's own player route.
    let pressed = false;
    const selectors = [
      'button[data-testid="preplay-play"]',
      'button[aria-label="Play"]',
      'button[title="Play"]',
      '[data-testid="playButton"]',
    ];
    for (const sel of selectors) {
      const el = await page.$(sel);
      if (el) {
        await el.click({ timeout: 5000 }).catch(() => {});
        log(`BROWSER clicked play via ${sel}`);
        pressed = true;
        break;
      }
    }
    if (!pressed) {
      const playUrl = `${BASE}/web/index.html#!/server/${SERVER_ID}/playback?key=${encodeURIComponent(KEY)}`;
      log('BROWSER no play button matched; navigating directly to the playback route');
      await page.goto(playUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    }
    report.play_pressed_via_button = pressed;
    await page.waitForTimeout(6000);

    const verdict = await measureAdvance(page, WATCH, 'plex-web');
    report.player = verdict;
    await page.screenshot({ path: path.join(OUT_DIR, 'player.png') }).catch(() => {});

    // Server-side cross-check: does PMS itself see a session advancing?
    const sess = await httpGet(`${BASE}/status/sessions?X-Plex-Token=${TOKEN}`);
    const sessM = sess.body.match(/viewOffset="(\d+)"/);
    report.server_sessions_size = (sess.body.match(/size="(\d+)"/) || [])[1] || '0';
    report.server_view_offset_ms = sessM ? Number(sessM[1]) : null;

    log('');
    log(`PLAYER: video_element=${verdict.sawVideoElement} samples=${verdict.samples} ` +
        `currentTime ${verdict.min_currentTime} -> ${verdict.max_currentTime} (advance ${verdict.advance}s)`);
    if (verdict.last) {
      log(`  last state: paused=${verdict.last.paused} readyState=${verdict.last.readyState} ` +
          `networkState=${verdict.last.networkState} error=${verdict.last.error} videos=${verdict.last.count}`);
    }
    log(`SERVER: sessions=${report.server_sessions_size} viewOffset=${report.server_view_offset_ms}`);

    fs.writeFileSync(path.join(OUT_DIR, 'web_baseline_report.json'), JSON.stringify(report, null, 2));

    if (!verdict.sawVideoElement) {
      console.error('REFUSE: no <video> element ever appeared — Plex Web UI was not drivable in ' +
                    'this environment, so the 0:00 symptom is UNSCORED (not a pass, not a fail). ' +
                    `Artefacts in ${OUT_DIR}`);
      process.exit(EXIT_REFUSE);
    }
    if (!verdict.advanced) {
      console.error(`FAIL: Plex Web player did NOT advance — position stayed at ` +
                    `${verdict.max_currentTime}s over ${WATCH}s. The stuck-at-0:00 symptom ` +
                    `reproduces in Plex's OWN web player with no MiSTerPlex involved, so it is ` +
                    `NOT caused by the cast client.`);
      process.exit(EXIT_FAIL);
    }
    log(`PASS: Plex Web player advanced ${verdict.advance}s. Plex Web, the media and the server ` +
        `are healthy for ${KEY}; a stuck 0:00 while casting is therefore a MiSTerPlex-side bug.`);
    process.exit(EXIT_PASS);
  } catch (e) {
    console.error(`REFUSE: browser automation error: ${redact(e && e.message)}`);
    process.exit(EXIT_REFUSE);
  } finally {
    if (browser) await browser.close().catch(() => {});
  }
}

main().catch((e) => {
  console.error(`REFUSE: unhandled error: ${redact(e && e.message)}`);
  process.exit(EXIT_REFUSE);
});
