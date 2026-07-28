#!/usr/bin/env node
/**
 * cast_cors_browser.js — real-browser CORS enforcement probe for the companion.
 *
 * Why a browser is required: every host-side check we own (curl, raw sockets in
 * test_companion_eof) speaks HTTP without CORS, and the pre-existing Playwright
 * observer launches Chromium with --disable-web-security. None of them can see a
 * preflight rejection, which is exactly how Plex Web cast broke: Plex Web sends
 * X-Plex-Target-Client-Identifier on every /player/ command, the companion's
 * Access-Control-Allow-Headers omitted it, and Chrome refused to send the request
 * at all. The player still appeared castable (that list comes from PMS,
 * server-side) but playMedia never arrived and the web player stayed at 0:00.
 *
 * This probe runs Chromium with web security ENABLED (browser default), from a
 * cross-origin page, and issues the same fetch Plex Web issues.
 *
 * Contract:
 *   argv[1] = origin URL to load the probe page from (cross-origin vs daemon)
 *   argv[2] = daemon base URL
 *   argv[3] = comma-separated request headers to send
 *   argv[4] = "expect-allow" | "expect-block"
 *
 * Exit: 0 = observed matched expectation, 1 = mismatch, 2 = refuse (bad args),
 *       77 = skip (playwright/browser unavailable — never reported as a pass).
 */

'use strict';

const path = require('path');

function refuse(msg) {
  console.error(`CAST_CORS_REFUSE: ${msg}`);
  process.exit(2);
}

const [, , ORIGIN, DAEMON, HEADER_CSV, EXPECT] = process.argv;
if (!ORIGIN || !DAEMON || !HEADER_CSV || !EXPECT)
  refuse('usage: cast_cors_browser.js <origin> <daemon> <hdr,hdr,...> <expect-allow|expect-block>');
if (EXPECT !== 'expect-allow' && EXPECT !== 'expect-block')
  refuse(`unknown expectation "${EXPECT}"`);

const HEADERS = HEADER_CSV.split(',').map((h) => h.trim()).filter(Boolean);
if (HEADERS.length === 0) refuse('empty header list — nothing to vary');

function loadPlaywright() {
  const candidates = [];
  if (process.env.PLAYWRIGHT_MODULE) candidates.push(process.env.PLAYWRIGHT_MODULE);
  candidates.push('playwright');
  candidates.push(path.join(__dirname, 'node_modules', 'playwright'));
  // The Playwright install is owned by W-E2E; reuse it rather than duplicating.
  candidates.push(path.join(__dirname, '..', '..', '..', '..', 'w-e2e',
                            'tests', 'hw', 'e2e', 'node_modules', 'playwright'));
  for (const c of candidates) {
    try {
      return require(c);
    } catch (_) { /* try next */ }
  }
  return null;
}

(async () => {
  const playwright = loadPlaywright();
  if (!playwright) {
    console.error('CAST_CORS_SKIP: playwright module not found');
    process.exit(77);
  }

  let browser;
  try {
    // No --disable-web-security: the whole point is to let Chromium enforce CORS
    // exactly as the user's browser does.
    browser = await playwright.chromium.launch({ headless: true, args: ['--no-sandbox'] });
  } catch (e) {
    console.error(`CAST_CORS_SKIP: chromium launch failed: ${String(e.message).slice(0, 160)}`);
    process.exit(77);
  }

  let observed;
  try {
    const page = await (await browser.newContext()).newPage();
    const corsErrors = [];
    page.on('console', (m) => {
      const t = m.text();
      if (m.type() === 'error' && /CORS policy/i.test(t)) corsErrors.push(t.slice(0, 300));
    });
    await page.goto(ORIGIN, { waitUntil: 'domcontentloaded', timeout: 30000 });

    const pageOrigin = await page.evaluate(() => window.location.origin);
    const daemonOrigin = new URL(DAEMON).origin;
    if (pageOrigin === daemonOrigin)
      refuse(`page origin ${pageOrigin} equals daemon origin — CORS would not apply`);

    observed = await page.evaluate(async ({ daemon, headers }) => {
      const h = {};
      for (const k of headers) h[k] = 'cast-cors-probe';
      try {
        const r = await fetch(`${daemon}/player/timeline/poll?commandID=cast-cors-probe`,
                              { headers: h });
        const body = await r.text();
        return { allowed: true, status: r.status, bytes: body.length };
      } catch (e) {
        return { allowed: false, err: String(e && e.message).slice(0, 160) };
      }
    }, { daemon: DAEMON, headers: HEADERS });
    observed.corsErrors = corsErrors;
  } finally {
    if (browser) await browser.close();
  }

  const expectAllow = EXPECT === 'expect-allow';
  const line = `CAST_CORS origin=${ORIGIN} daemon=${DAEMON} headers=[${HEADERS.join(' ')}] ` +
               `expect=${EXPECT} observed=${observed.allowed ? 'allowed' : 'blocked'}` +
               (observed.allowed ? ` status=${observed.status} bytes=${observed.bytes}`
                                 : ` err="${observed.err}"`);
  console.log(line);
  if (observed.corsErrors && observed.corsErrors.length)
    console.log(`CAST_CORS_BROWSER_ERR ${observed.corsErrors[0]}`);

  if (observed.allowed !== expectAllow) {
    console.error(`CAST_CORS_FAIL: expected ${EXPECT}, browser ${observed.allowed ? 'allowed' : 'blocked'} the request`);
    process.exit(1);
  }
  if (expectAllow && observed.status !== 200) {
    console.error(`CAST_CORS_FAIL: request allowed but status=${observed.status}`);
    process.exit(1);
  }
  console.log('CAST_CORS_OK');
  process.exit(0);
})().catch((e) => {
  console.error(`CAST_CORS_ERROR: ${String(e && e.stack || e).slice(0, 400)}`);
  process.exit(1);
});
