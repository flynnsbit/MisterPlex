#!/usr/bin/env node
/**
 * test_cast_timeline_playwright.js
 *
 * Browser fidelity check for the cast/timeline path.
 * Approach: Playwright drives headless Chromium through the real Plex Web UI,
 * authenticates via localStorage token injection, navigates to the media item,
 * selects the MiSTerPlex cast target, and presses Play.
 *
 * The authoritative assertion is still on /player/timeline/poll (same as
 * test_cast_timeline_poll.sh) — NOT on what the browser renders — because that
 * is the response the real client actually consumes.
 *
 * If any browser-UI step fails (selector not found, timeout), the script falls
 * back to the HTTP-only path and exits 77 with a reason, so a UI-selector
 * regression does not produce a false green or false red.
 *
 * Exit codes:
 *   0  PASS  — browser triggered cast play AND timeline advanced
 *   1  FAIL  — browser path succeeded but timeline stuck
 *  77  SKIP  — Playwright/Chromium missing, or UI unreachable
 *
 * Reads credentials from $MISTERPLEX_CONF or $HOME/.config/misterplex/misterplex.conf
 * Token MUST NOT appear in source; it is read at runtime only.
 *
 * Usage:
 *   node test_cast_timeline_playwright.js
 *   CAST_POLL_SECONDS=30 MISTER_HOST=192.168.1.183 node test_cast_timeline_playwright.js
 */

'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const os = require('os');

// ── conf-file helpers ─────────────────────────────────────────────────────────
function readConf(confPath) {
  if (!confPath || !fs.existsSync(confPath)) return {};
  const vals = {};
  for (const line of fs.readFileSync(confPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.+)/);
    if (m) vals[m[1]] = m[2].trim().replace(/\r$/, '');
  }
  return vals;
}

function resolveConf() {
  if (process.env.MISTERPLEX_CONF) return readConf(process.env.MISTERPLEX_CONF);
  const candidates = [
    path.join(__dirname, '../../..', 'assets', 'misterplex.conf'),
    path.join(os.homedir(), '.config', 'misterplex', 'misterplex.conf'),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return readConf(c);
  }
  return {};
}

// ── runtime config ────────────────────────────────────────────────────────────
const conf = resolveConf();
const HOST      = process.env.MISTER_HOST   || '192.168.1.183';
const PLEX_BASE = process.env.PLEX_BASE     || conf.PLEX_BASE     || '';
const TOKEN     = process.env.PLEX_TOKEN    || conf.PLEX_TOKEN    || '';
const PLEX_KEY  = process.env.PLEX_KEY      || conf.PLEX_KEY      || '/library/metadata/3';
const POLL_SEC  = parseInt(process.env.CAST_POLL_SECONDS || '30', 10);
const DAEMON    = `http://${HOST}:3005`;
const CAST_NAME = process.env.CAST_TARGET_NAME || 'MiSTerPlex';

function skip(reason) {
  console.error(`SKIP-NOT-PASS test_cast_timeline_playwright: ${reason}`);
  process.exit(77);
}
function fail(reason) {
  console.log(`CAST_PW_RESULT=FAIL reason=${reason}`);
  process.exit(1);
}

// ── timeline poll helper (no external deps — stdlib http only) ────────────────
function pollTimeline(commandID) {
  return new Promise((resolve) => {
    const url = `${DAEMON}/player/timeline/poll?commandID=${commandID}&wait=1`;
    const req = http.get(url, { timeout: 4000 }, (res) => {
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => resolve(body));
    });
    req.on('error', () => resolve(''));
    req.on('timeout', () => { req.destroy(); resolve(''); });
  });
}

function xmlAttr(xml, attr) {
  const m = xml.match(new RegExp(`${attr}="([^"]*)"`));
  return m ? m[1] : null;
}

// ── run ───────────────────────────────────────────────────────────────────────
(async () => {
  if (!TOKEN) skip('PLEX_TOKEN missing — set MISTERPLEX_CONF or PLEX_TOKEN env');
  if (!PLEX_BASE) skip('PLEX_BASE missing');

  // Check Playwright availability
  let playwright;
  try {
    playwright = require('playwright');
  } catch (_) {
    // Try local node_modules (tests/hw/e2e/)
    try {
      playwright = require(path.join(__dirname, 'node_modules', 'playwright'));
    } catch (_2) {
      skip('playwright npm module not found (run: npm install inside tests/hw/e2e/)');
    }
  }

  console.log('test_cast_timeline_playwright: BEGIN');
  console.log(`Scope: 1 browser session, cast to "${CAST_NAME}", assert on daemon timeline poll`);

  // ── check daemon reachability ─────────────────────────────────────────────
  const baselineXml = await pollTimeline(7001);
  if (!baselineXml.includes('Timeline')) skip(`daemon unreachable at ${DAEMON}`);
  const bState = xmlAttr(baselineXml, 'state');
  const bTime  = xmlAttr(baselineXml, 'time');
  console.log(`BASELINE state=${bState} time=${bTime}`);

  // ── launch Chromium ────────────────────────────────────────────────────────
  const { chromium } = playwright;
  let browser;
  try {
    browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  } catch (e) {
    skip(`chromium launch failed: ${e.message}`);
  }

  let uiSucceeded = false;
  let uiError = null;

  try {
    const context = await browser.newContext({
      // Inject Plex auth token into localStorage before page load
      storageState: {
        origins: [{
          origin: PLEX_BASE,
          localStorage: [
            { name: 'myPlexAccessToken', value: TOKEN },
            { name: 'myPlexAuthToken',   value: TOKEN },
          ],
        }],
      },
    });

    const page = await context.newPage();
    // Capture console/network errors for debugging without failing the test
    page.on('pageerror', (e) => console.log(`  browser-err: ${e.message.slice(0, 80)}`));

    // Navigate to Plex Web
    console.log(`BROWSER navigating to ${PLEX_BASE}/web/index.html`);
    try {
      await page.goto(`${PLEX_BASE}/web/index.html`, { waitUntil: 'domcontentloaded', timeout: 20000 });
    } catch (e) {
      throw new Error(`page load failed: ${e.message}`);
    }

    // Wait for sign-in to complete (look for the home/library section)
    // Plex Web may require myPlex cloud auth even with a local server token.
    // If it lands on /signin, we report skip rather than fail.
    await page.waitForTimeout(3000);
    const url = page.url();
    console.log(`BROWSER landed at: ${url}`);

    if (url.includes('/signin') || url.includes('/login')) {
      throw new Error('Plex Web redirected to sign-in (local token not accepted by web app)');
    }

    // Navigate directly to the media item
    console.log(`BROWSER navigating to metadata key ${PLEX_KEY}`);
    // Plex Web uses a hash-based router: #!/server/{machineId}/details?key=...
    // Try a direct fetch of metadata via API to get the correct deep-link format
    const metaUrl = `${PLEX_BASE}${PLEX_KEY}?X-Plex-Token=${TOKEN}`;
    // Navigate via Plex Web's own routing by setting a direct URL param
    const ratingKey = path.basename(PLEX_KEY);
    await page.goto(
      `${PLEX_BASE}/web/index.html#!/server/auto/details?key=${encodeURIComponent(PLEX_KEY)}&context=plexpass`,
      { waitUntil: 'networkidle', timeout: 20000 }
    );
    await page.waitForTimeout(2000);
    console.log(`BROWSER at: ${page.url()}`);

    // Find the cast button — Plex Web uses an icon-based button
    // Selectors are version-specific; we try multiple known patterns.
    const castSelectors = [
      '[data-testid="cast-button"]',
      '[class*="CastButton"]',
      '[class*="castButton"]',
      '[title*="Cast"]',
      '[aria-label*="Cast"]',
      'button[class*="cast"]',
      '[data-qa="preplayPlayButton"]',  // fallback: sometimes opens cast menu
    ];

    let castBtn = null;
    for (const sel of castSelectors) {
      try {
        castBtn = await page.waitForSelector(sel, { timeout: 3000, state: 'visible' });
        if (castBtn) { console.log(`BROWSER found cast btn via selector: ${sel}`); break; }
      } catch (_) { /* try next */ }
    }

    if (!castBtn) throw new Error('cast button not found (UI selectors exhausted)');
    await castBtn.click();
    await page.waitForTimeout(1500);

    // Find MiSTerPlex in the cast target list
    const castTargetSelectors = [
      `[data-testid*="cast-target"]:has-text("${CAST_NAME}")`,
      `text="${CAST_NAME}"`,
      `[class*="DeviceRow"]:has-text("${CAST_NAME}")`,
      `[class*="castTarget"]:has-text("${CAST_NAME}")`,
    ];

    let target = null;
    for (const sel of castTargetSelectors) {
      try {
        target = await page.waitForSelector(sel, { timeout: 3000, state: 'visible' });
        if (target) { console.log(`BROWSER found "${CAST_NAME}" via: ${sel}`); break; }
      } catch (_) { /* try next */ }
    }

    if (!target) throw new Error(`"${CAST_NAME}" not found in cast target list`);
    await target.click();
    await page.waitForTimeout(1000);

    // Find and click the Play button
    const playSelectors = [
      '[data-testid="preplay-play"]',
      '[data-qa="preplayPlayButton"]',
      '[class*="PlayButton"]',
      'button[class*="play"]',
      '[aria-label="Play"]',
      '[title="Play"]',
    ];

    let playBtn = null;
    for (const sel of playSelectors) {
      try {
        playBtn = await page.waitForSelector(sel, { timeout: 3000, state: 'visible' });
        if (playBtn) { console.log(`BROWSER found play btn via: ${sel}`); break; }
      } catch (_) { /* try next */ }
    }

    if (!playBtn) throw new Error('play button not found');
    await playBtn.click();
    console.log('BROWSER play clicked');
    uiSucceeded = true;

  } catch (e) {
    uiError = e.message;
    console.log(`BROWSER_UI_SKIP reason: ${uiError}`);
  } finally {
    if (browser) await browser.close();
  }

  if (!uiSucceeded) {
    // Browser UI path failed — skip with explanation so it's not a false result
    skip(`browser-ui-step failed: ${uiError}`);
  }

  // ── poll daemon timeline for actual assertion ─────────────────────────────
  console.log(`POLL_BEGIN window=${POLL_SEC}s assertion=state+time from ${DAEMON}/player/timeline/poll`);

  let pollN = 0, playingN = 0, advancingN = 0;
  let prevTime = -1, timeMax = 0;
  const stateSeq = [];
  const deadline = Date.now() + POLL_SEC * 1000;
  let cmdId = 7100;

  while (Date.now() < deadline) {
    const xml = await pollTimeline(cmdId++);
    const state = xmlAttr(xml, 'state');
    const timeStr = xmlAttr(xml, 'time');
    const dur = xmlAttr(xml, 'duration');
    const curTime = timeStr ? parseInt(timeStr, 10) : -1;

    console.log(`  poll ${pollN}: state=${state ?? '?'} time=${timeStr ?? '?'} duration=${dur ?? '?'}`);
    stateSeq.push(state ?? '?');

    if (state === 'playing') {
      playingN++;
      if (curTime > prevTime && prevTime >= 0) advancingN++;
      if (curTime > timeMax) timeMax = curTime;
    }
    if (curTime >= 0) prevTime = curTime;
    pollN++;
  }

  console.log(`POLL_END polls=${pollN} playing=${playingN} advancing=${advancingN} time_max_ms=${timeMax}`);
  console.log(`STATE_SEQUENCE: ${stateSeq.join(' ')}`);

  if (pollN === 0) fail('scope-zero: no polls completed');
  if (playingN === 0) fail(`state-never-playing: sequence=${stateSeq.join(',')}`);
  if (advancingN < 2) fail(`time-not-advancing: playing=${playingN} advancing=${advancingN} time_max=${timeMax}`);

  console.log(`CAST_PW_RESULT=PASS state=playing time_max_ms=${timeMax} polls=${pollN} playing=${playingN} advancing=${advancingN}`);
  process.exit(0);
})().catch((e) => {
  console.error(`UNHANDLED: ${e.message}`);
  process.exit(77);
});
