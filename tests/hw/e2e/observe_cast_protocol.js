#!/usr/bin/env node
/**
 * observe_cast_protocol.js
 *
 * Protocol observation for W-CAST: captures the exact sequence of HTTP
 * requests/responses between Plex Web (browser) and the MiSTerPlex daemon.
 *
 * Specifically answers:
 *   - Does Plex Web send a pause/stop command AFTER playMedia?
 *   - What is the exact timeline-poll response sequence the browser sees?
 *   - Are there any unexpected interstitial commands between playMedia and playing?
 *
 * Approach:
 *   1. Launch Chromium with Playwright, inject Plex auth via localStorage.
 *   2. Install route interceptors on ALL requests to the daemon — every
 *      request is logged with timestamp and forwarded unchanged.
 *   3. Navigate Plex Web to the media item, attempt UI cast + play.
 *   4. If UI interaction fails: inject a fetch() from the browser's own
 *      JavaScript context (same origin policy, same headers Plex Web uses)
 *      to trigger playMedia and observe what the Plex SDK does next.
 *   5. Observe for OBSERVE_SECONDS (default 60s) and print the full log.
 *
 * Assertion: NONE — this is pure observation for W-CAST diagnosis.
 * Exit 0 always (even with no data). Prints structured log to stdout.
 *
 * Usage:
 *   node observe_cast_protocol.js
 *   OBSERVE_SECONDS=90 MISTER_HOST=192.168.1.183 node observe_cast_protocol.js
 */

'use strict';

const fs   = require('fs');
const http = require('http');
const path = require('path');
const os   = require('os');

// ── conf resolution (same as gate script) ─────────────────────────────────────
function readConf(p) {
  if (!p || !fs.existsSync(p)) return {};
  const v = {};
  for (const l of fs.readFileSync(p, 'utf8').split('\n')) {
    const m = l.match(/^([A-Z_]+)=(.+)/);
    if (m) v[m[1]] = m[2].trim().replace(/\r$/, '');
  }
  return v;
}
function resolveConf() {
  if (process.env.MISTERPLEX_CONF) return readConf(process.env.MISTERPLEX_CONF);
  for (const c of [
    path.join(__dirname, '../../..', 'assets', 'misterplex.conf'),
    path.join(os.homedir(), '.config', 'misterplex', 'misterplex.conf'),
  ]) { if (fs.existsSync(c)) return readConf(c); }
  return {};
}

const conf   = resolveConf();
const HOST   = process.env.MISTER_HOST  || '192.168.1.183';
const BASE   = process.env.PLEX_BASE    || conf.PLEX_BASE   || '';
const TOKEN  = process.env.PLEX_TOKEN   || conf.PLEX_TOKEN  || '';
const KEY    = process.env.PLEX_KEY     || conf.PLEX_KEY    || '/library/metadata/3';
const OBS_S  = parseInt(process.env.OBSERVE_SECONDS || '60', 10);
const DAEMON = `http://${HOST}:3005`;

if (!TOKEN || !BASE) {
  console.error('OBSERVE_SKIP: PLEX_TOKEN or PLEX_BASE missing');
  process.exit(77);
}

// ── structured log ─────────────────────────────────────────────────────────────
const T0 = Date.now();
const log = [];
function stamp() { return `+${((Date.now() - T0) / 1000).toFixed(3)}s`; }
function emit(type, msg, extra) {
  const entry = { t: stamp(), type, msg, ...extra };
  log.push(entry);
  const extra_str = extra && Object.keys(extra).length
    ? '  ' + JSON.stringify(extra).slice(0, 200)
    : '';
  console.log(`[${entry.t}] ${type.padEnd(12)} ${msg}${extra_str}`);
}

// ── quick XML attr extractor ──────────────────────────────────────────────────
function xa(xml, attr) {
  const m = xml && xml.match(new RegExp(`${attr}="([^"]*)"`));
  return m ? m[1] : null;
}

// ── raw daemon poller (parallel, to see what the browser triggers) ─────────────
let pollIndex = 0;
async function daemonPoll() {
  return new Promise((resolve) => {
    const url = `${DAEMON}/player/timeline/poll?commandID=${2000 + pollIndex++}&wait=1`;
    const req = http.get(url, { timeout: 3000 }, (res) => {
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => resolve(body));
    });
    req.on('error', () => resolve(''));
    req.on('timeout', () => { req.destroy(); resolve(''); });
  });
}

async function pollLoop(durationMs) {
  const deadline = Date.now() + durationMs;
  while (Date.now() < deadline) {
    const xml = await daemonPoll();
    if (xml) {
      emit('DAEMON_POLL', 'timeline', {
        state: xa(xml, 'state'),
        time:  xa(xml, 'time'),
        dur:   xa(xml, 'duration'),
      });
    }
  }
}

// ── main ──────────────────────────────────────────────────────────────────────
(async () => {
  let playwright;
  try {
    playwright = require('playwright');
  } catch (_) {
    try {
      playwright = require(path.join(__dirname, 'node_modules', 'playwright'));
    } catch (_2) {
      console.error('OBSERVE_SKIP: playwright module not found');
      process.exit(77);
    }
  }

  const { chromium } = playwright;
  emit('INFO', 'observe_cast_protocol BEGIN', { daemon: DAEMON, pms: BASE, window: `${OBS_S}s` });

  const pmsHost = BASE.replace(/^https?:\/\//, '').split(':')[0];
  const pmsPort = BASE.replace(/^https?:\/\//, '').split(':')[1] || '32400';

  // ── browser setup ──────────────────────────────────────────────────────────
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-web-security'],
  });

  const context = await browser.newContext({
    storageState: {
      origins: [{
        origin: BASE,
        localStorage: [
          { name: 'myPlexAccessToken', value: TOKEN },
          { name: 'myPlexAuthToken',   value: TOKEN },
        ],
      }],
    },
  });

  const page = await context.newPage();

  // ── intercept ALL requests — log and forward unchanged ────────────────────
  await page.route(`http://${HOST}:3005/**`, async (route, request) => {
    const method = request.method();
    const url    = request.url();
    const path_  = url.replace(DAEMON, '');
    const hdrs   = request.headers();
    emit('BROWSER_REQ', `${method} ${path_}`, {
      'x-plex-client-id': hdrs['x-plex-client-identifier'] || '–',
      'x-plex-token':     hdrs['x-plex-token'] ? '[present]' : '[absent]',
    });

    let response;
    try {
      response = await route.fetch();
    } catch (e) {
      emit('BROWSER_FETCH_ERR', path_, { err: e.message.slice(0, 80) });
      await route.abort();
      return;
    }

    let bodyText = '';
    try {
      bodyText = await response.text();
    } catch (_) {}

    const state_ = xa(bodyText, 'state');
    const time_  = xa(bodyText, 'time');
    emit('BROWSER_RESP', `${response.status()} ${path_}`, {
      state: state_ || '–',
      time:  time_  || '–',
      body_snippet: bodyText.slice(0, 120).replace(/\s+/g, ' '),
    });

    await route.fulfill({ response });
  });

  // Also log all PMS requests (to see if Plex Web talks to PMS around cast)
  await page.route(`http://${pmsHost}:${pmsPort}/player/**`, async (route, request) => {
    emit('PMS_PLAYER_REQ', `${request.method()} ${request.url().replace(BASE, '')}`, {});
    const resp = await route.fetch().catch(() => null);
    if (resp) await route.fulfill({ response: resp });
    else await route.abort();
  });

  page.on('pageerror', (e) => emit('PAGE_ERR', e.message.slice(0, 100)));
  page.on('console',   (m) => {
    if (m.type() === 'error') emit('CONSOLE_ERR', m.text().slice(0, 100));
  });

  // ── parallel daemon poller (independent observer, not browser traffic) ─────
  const pollPromise = pollLoop(OBS_S * 1000);

  // ── navigate Plex Web ──────────────────────────────────────────────────────
  emit('INFO', `navigating to ${BASE}/web/index.html`);
  try {
    await page.goto(`${BASE}/web/index.html`, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await page.waitForTimeout(3000);
    emit('INFO', `landed: ${page.url()}`);
  } catch (e) {
    emit('NAV_ERR', e.message.slice(0, 100));
  }

  // ── attempt media item navigation ─────────────────────────────────────────
  const ratingKey = path.basename(KEY);
  try {
    await page.goto(
      `${BASE}/web/index.html#!/server/auto/details?key=${encodeURIComponent(KEY)}`,
      { waitUntil: 'networkidle', timeout: 20000 }
    );
    await page.waitForTimeout(2000);
    emit('INFO', `media page: ${page.url()}`);
  } catch (e) {
    emit('NAV_ERR', `media nav: ${e.message.slice(0, 80)}`);
  }

  // ── dump visible buttons for selector discovery ────────────────────────────
  try {
    const btns = await page.evaluate(() =>
      Array.from(document.querySelectorAll('button, [role="button"]'))
        .slice(0, 30)
        .map(el => ({
          tag:   el.tagName,
          class: (el.className || '').toString().slice(0, 60),
          text:  (el.textContent || '').trim().slice(0, 30),
          aria:  el.getAttribute('aria-label') || '',
          qa:    el.getAttribute('data-qa') || '',
          test:  el.getAttribute('data-testid') || '',
        }))
    );
    emit('UI_BUTTONS', `found ${btns.length} buttons`, { buttons: btns });
    console.log('BUTTON_INVENTORY:');
    for (const b of btns) {
      console.log(`  [${b.tag}] class=${b.class.slice(0,50)} text="${b.text}" aria="${b.aria}" qa="${b.qa}" test="${b.test}"`);
    }
  } catch (e) {
    emit('UI_ERR', `button scan: ${e.message.slice(0, 80)}`);
  }

  // ── attempt cast button click using discovered selectors ───────────────────
  let uiCastDone = false;
  const castSelectors = [
    '[data-qa="preplayPlayButton"]',
    '[data-testid="cast-button"]',
    '[class*="CastButton"]',
    '[class*="castButton"]',
    '[class*="CastIcon"]',
    'button[class*="cast"]',
    '[aria-label*="cast" i]',
    '[aria-label*="Cast"]',
    '[title*="Cast"]',
    '[class*="MediaPoster"] button',
    '[class*="preplay"] button',
    // From dumped buttons above — try broad class scans
    '[class*="MetadataButton"]',
    '[class*="PlayerButton"]',
    '[class*="PlayButton"]',
  ];

  for (const sel of castSelectors) {
    try {
      const el = await page.waitForSelector(sel, { timeout: 1500, state: 'visible' });
      if (el) {
        emit('UI', `clicking: ${sel}`);
        await el.click();
        await page.waitForTimeout(1500);
        uiCastDone = true;
        break;
      }
    } catch (_) { /* keep trying */ }
  }

  if (!uiCastDone) {
    emit('UI', 'cast button not found via selectors; injecting playMedia from browser JS context');
    // Inject playMedia directly from the browser's JS context.
    // This originates FROM the browser (same origin, same headers the SDK uses).
    // Key observation point: does the Plex Web SDK react to the response and
    // send any follow-up commands (pause, stop, etc.)?
    try {
      const result = await page.evaluate(async ({ daemon, token, key, pmsHost, pmsPort, ratingKey }) => {
        const url = new URL(`${daemon}/player/playback/playMedia`);
        url.searchParams.set('key', key);
        url.searchParams.set('containerKey', '/playQueues/browser-obs?own=1');
        url.searchParams.set('ratingKey', ratingKey);
        url.searchParams.set('address', pmsHost);
        url.searchParams.set('port', pmsPort);
        url.searchParams.set('protocol', 'http');
        url.searchParams.set('offset', '0');
        url.searchParams.set('commandID', '3001');
        const resp = await fetch(url.toString(), {
          headers: {
            'X-Plex-Token': token,
            'X-Plex-Client-Identifier': 'plex-web-obs',
            'X-Plex-Product': 'Plex Web',
            'X-Plex-Version': '4.0',
            'X-Plex-Platform': 'Chrome',
            'X-Plex-Device-Name': 'Chrome',
          },
        });
        const body = await resp.text();
        return { status: resp.status, body: body.slice(0, 300) };
      }, { daemon: DAEMON, token: TOKEN, key: KEY, pmsHost, pmsPort, ratingKey });

      emit('JS_PLAYMEDIA', `injected playMedia from browser JS`, {
        status: result.status,
        state: xa(result.body, 'state'),
        time:  xa(result.body, 'time'),
        body:  result.body.slice(0, 120),
      });
    } catch (e) {
      emit('JS_ERR', `playMedia inject failed: ${e.message.slice(0, 100)}`);
    }

    // Now watch what the page does in response — does Plex Web's SDK react?
    emit('INFO', 'watching browser activity for 15s after injected playMedia');
    await page.waitForTimeout(15000);
  } else {
    // UI cast done — watch for follow-up requests
    emit('INFO', 'UI cast done — watching for 30s');
    await page.waitForTimeout(30000);
  }

  // ── check for specific pause/stop commands in log ─────────────────────────
  console.log('\n=== PROTOCOL_SEQUENCE_SUMMARY ===');
  const daemonReqs = log.filter(e => e.type === 'BROWSER_REQ' || e.type === 'BROWSER_RESP');
  console.log(`Total browser→daemon interactions: ${daemonReqs.length}`);

  const pauseCmds = log.filter(e =>
    e.type === 'BROWSER_REQ' && (
      (e.msg || '').includes('/playback/pause') ||
      (e.msg || '').includes('/playback/stop')  ||
      (e.msg || '').includes('/playback/play')
    )
  );

  console.log(`\nPlayback control commands sent by browser:`);
  if (pauseCmds.length === 0) {
    console.log('  NONE — browser did not send pause/stop/play after playMedia');
  } else {
    for (const cmd of pauseCmds) {
      console.log(`  ${cmd.t} ${cmd.msg}`);
    }
  }

  const pollResps = log.filter(e =>
    e.type === 'BROWSER_RESP' && (e.msg || '').includes('timeline/poll')
  );
  console.log(`\nTimeline poll responses seen by browser (${pollResps.length} total):`);
  for (const r of pollResps.slice(0, 20)) {
    console.log(`  ${r.t} state=${r.state} time=${r.time}`);
  }

  const daemonPolls = log.filter(e => e.type === 'DAEMON_POLL');
  console.log(`\nIndependent daemon polls (${daemonPolls.length} total):`);
  for (const p of daemonPolls.slice(0, 20)) {
    console.log(`  ${p.t} state=${p.state} time=${p.time}`);
  }

  console.log('\n=== FULL_LOG ===');
  for (const e of log) {
    if (e.type === 'DAEMON_POLL') continue; // already shown above
    const extras = { ...e };
    delete extras.t; delete extras.type; delete extras.msg;
    const es = Object.keys(extras).length ? '  ' + JSON.stringify(extras).slice(0, 200) : '';
    console.log(`[${e.t}] ${e.type.padEnd(12)} ${e.msg}${es}`);
  }

  await browser.close();

  emit('INFO', 'observation complete');
  await pollPromise;

  process.exit(0);
})().catch((e) => {
  console.error(`UNHANDLED: ${e.stack || e.message}`);
  process.exit(1);
});
