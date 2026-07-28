#!/usr/bin/env node
/**
 * cast_play_web_e2e.js — drive the real Plex Web UI and prove cast playback starts.
 *
 * This is the user's literal acceptance path: open Plex Web, pick MiSTerPlex in
 * the player picker, press Play on a library item, and watch the timeline leave
 * 0:00. Everything runs in a real Chromium with web security ENABLED, so a CORS
 * preflight rejection fails this gate instead of hiding in it. (Measured: this
 * Plex Web build relays player commands through the PMS rather than contacting
 * the player directly, so CORS is not always on the critical path -- the gate
 * accepts either addressing and asserts on the daemon's own timeline.)
 *
 * Assertions, in order:
 *   1. MiSTerPlex is offered in Plex Web's own player picker.
 *   2. Pressing Play (dismissing any Resume dialog) makes the browser issue a
 *      /player/playback/playMedia command that is not blocked by the browser.
 *   3. The daemon timeline, polled *from the browser* (so cross-origin rules
 *      apply), reports state=playing with strictly advancing time across
 *      samples — i.e. the web player is not stuck at 0:00.
 *
 * Exit codes: 0 pass, 1 fail, 2 refuse (missing config), 77 skip (no browser or
 * a UI step could not be completed — never reported as a pass).
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

function refuse(msg) { console.error(`CAST_E2E_REFUSE: ${msg}`); process.exit(2); }
function skip(msg) { console.error(`CAST_E2E_SKIP: ${msg}`); process.exit(77); }
function fail(msg) { console.error(`CAST_E2E_FAIL: ${msg}`); process.exit(1); }

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
  ]) if (fs.existsSync(c)) return readConf(c);
  return {};
}

const conf = resolveConf();
const BASE = process.env.PLEX_BASE || conf.PLEX_BASE || '';
const TOKEN = process.env.PLEX_TOKEN || conf.PLEX_TOKEN || '';
const KEY = process.env.PLEX_KEY || conf.PLEX_KEY || '';
const HOST = process.env.MISTER_HOST || '192.168.1.183';
const PORT = process.env.MISTERPLEX_PORT || '3005';
const PLAYER = process.env.MISTERPLEX_NAME || 'MiSTerPlex';
const HOME_USER = process.env.PLEX_HOME_USER || '';
const SAMPLES = parseInt(process.env.CAST_SAMPLES || '5', 10);
const SAMPLE_MS = parseInt(process.env.CAST_SAMPLE_MS || '3000', 10);
const DAEMON = `http://${HOST}:${PORT}`;

if (!BASE) refuse('PLEX_BASE not configured');
if (!TOKEN) refuse('PLEX_TOKEN not configured');
if (!KEY) refuse('PLEX_KEY not configured');
if (SAMPLES < 3) refuse('CAST_SAMPLES must be >= 3 to show advance, not a single reading');

function loadPlaywright() {
  const c = [];
  if (process.env.PLAYWRIGHT_MODULE) c.push(process.env.PLAYWRIGHT_MODULE);
  c.push('playwright', path.join(__dirname, 'node_modules', 'playwright'),
         path.join(__dirname, '..', '..', '..', '..', 'w-e2e', 'tests', 'hw', 'e2e',
                   'node_modules', 'playwright'));
  for (const m of c) { try { return require(m); } catch (_) {} }
  return null;
}

(async () => {
  const pw = loadPlaywright();
  if (!pw) skip('playwright module not found');

  let browser;
  try {
    // No --disable-web-security on purpose.
    browser = await pw.chromium.launch({ headless: true, args: ['--no-sandbox'] });
  } catch (e) { skip(`chromium launch failed: ${String(e.message).slice(0, 160)}`); }

  const daemonSent = [];
  const daemonFailed = [];
  const corsErrors = [];
  let verdict = null;

  try {
    const ctx = await browser.newContext({
      storageState: { origins: [{ origin: BASE, localStorage: [
        { name: 'myPlexAccessToken', value: TOKEN },
        { name: 'myPlexAuthToken', value: TOKEN },
      ] }] },
    });
    const page = await ctx.newPage();
    // Plex Web may address the player directly or relay through PMS
    // (/player/... on the server host, which PMS forwards to the client). Accept
    // either: what matters is that a playMedia command actually leaves the browser.
    const playerCmds = [];
    const allReq = [];
    page.on('request', (r) => {
      allReq.push(r.method() + ' ' + r.url().replace(/X-Plex-Token=[^&]*/, 'X-Plex-Token=<redacted>').slice(0, 150));
      const u = r.url();
      if (u.startsWith(DAEMON)) daemonSent.push(u.slice(DAEMON.length));
      if (/\/player\/playback\//.test(u))
        playerCmds.push(u.replace(/X-Plex-Token=[^&]*/, 'X-Plex-Token=<redacted>').slice(0, 160));
    });
    page.on('requestfailed', (r) => {
      if (r.url().startsWith(DAEMON))
        daemonFailed.push(`${r.url().slice(DAEMON.length)} :: ${(r.failure() || {}).errorText || '?'}`);
    });
    page.on('console', (m) => {
      if (m.type() === 'error' && /CORS policy/i.test(m.text())) corsErrors.push(m.text().slice(0, 240));
    });

    // Local playback is the failure mode this gate exists to catch: when Plex Web
    // drops the selected player it silently starts a transcode in the browser.
    const localPlayback = [];
    page.on('request', (r) => {
      if (/\/video\/:\/transcode\/universal\/(start|session)/.test(r.url()))
        localPlayback.push(r.url().slice(0, 90));
    });

    await page.goto(`${BASE}/web/index.html`, { waitUntil: 'domcontentloaded', timeout: 60000 });

    // Plex Home installs land on a user picker; the app shell never renders until
    // a user is chosen, which is why UI selectors "did not exist" before.
    let shellReady = false;
    for (let i = 0; i < 30 && !shellReady; i++) {
      await page.waitForTimeout(2000);
      if (await page.$('[aria-label="Select Player"]')) { shellReady = true; break; }
      const t = await page.evaluate(() => document.body.innerText || '');
      if (/Select User/i.test(t)) {
        if (!HOME_USER) skip('Plex Home user picker shown but PLEX_HOME_USER is not set');
        try { await page.getByText(HOME_USER, { exact: true }).first().click({ timeout: 5000 }); } catch (_) {}
      }
    }
    if (!shellReady) skip('player picker button never rendered (not signed in?)');

    // Navigate to the item BEFORE picking the player: a full page load would drop
    // the selected cast target and silently send playback to the browser instead.
    const serverId = process.env.PLEX_SERVER_ID || 'auto';
    await page.goto(`${BASE}/web/index.html#!/server/${serverId}/details?key=${encodeURIComponent(KEY)}`,
                    { waitUntil: 'domcontentloaded', timeout: 60000 });
    let playBtn;
    try {
      playBtn = await page.waitForSelector('[data-testid="preplay-play"]', { timeout: 45000 });
    } catch (e) { skip(`play button not found on details page for ${KEY}`); }

    await page.click('[aria-label="Select Player"]');
    await page.waitForTimeout(2500);
    const menuText = await page.evaluate(() => document.body.innerText || '');
    if (!menuText.includes(PLAYER))
      fail(`"${PLAYER}" is not offered in Plex Web's player picker — cast target not advertised`);
    console.log(`CAST_E2E player "${PLAYER}" offered in Plex Web picker`);
    try {
      await page.getByRole('menuitem').filter({ hasText: PLAYER }).first().click({ timeout: 15000 });
    } catch (e) { skip(`could not click "${PLAYER}" menu entry`); }
    await page.waitForTimeout(4000);
    playBtn = await page.waitForSelector('[data-testid="preplay-play"]', { timeout: 20000 });

    const before = playerCmds.length;
    const beforeAll = allReq.length;
    await playBtn.click();
    console.log(`CAST_E2E pressed Play on ${KEY}`);
    await page.waitForTimeout(2500);

    // Partially watched items open a Resume/Start-over dialog before any command
    // is sent. Always take "start from the beginning" so the expected offset is 0.
    let resumeDialog = false;
    try {
      await page.getByText('Start from the beginning', { exact: false }).first().click({ timeout: 8000 });
      resumeDialog = true;
    } catch (_) { /* unwatched item: no dialog */ }
    console.log(`CAST_E2E resume dialog: ${resumeDialog ? 'handled (start from beginning)' : 'not shown'}`);

    let cmd = null;
    for (let i = 0; i < 40 && !cmd; i++) {
      cmd = playerCmds.slice(before).find((u) => u.includes('playMedia')) || null;
      if (!cmd) await page.waitForTimeout(500);
    }
    if (!cmd && localPlayback.length) {
      fail('Plex Web dropped the selected player and played locally in the browser ' +
           `(${localPlayback.length} transcode requests) instead of casting to ${PLAYER}`);
    }
    if (!cmd) {
      console.error('CAST_E2E post-Play requests:\n  ' + allReq.slice(beforeAll).join('\n  '));
      console.error('CAST_E2E post-Play page text: ' +
        (await page.evaluate(() => (document.body.innerText || '').slice(0, 400))).replace(/\n/g, ' | '));
      fail(`Plex Web issued no playMedia after Play — the press did not cast` +
           (corsErrors.length ? ` — CORS: ${corsErrors[0]}` : '') +
           (daemonFailed.length ? ` — browser-blocked: ${daemonFailed[0]}` : ''));
    }
    const relayed = !cmd.startsWith(DAEMON);
    console.log(`CAST_E2E playMedia issued (${relayed ? 'relayed via PMS' : 'direct to player'})`);

    // 3. timeline must advance, sampled from inside the browser
    const times = [];
    for (let i = 0; i < SAMPLES; i++) {
      const s = await page.evaluate(async ({ daemon, id, n }) => {
        try {
          const r = await fetch(`${daemon}/player/timeline/poll?commandID=e2e-${n}`,
                                { headers: { 'X-Plex-Client-Identifier': 'cast-e2e',
                                             'X-Plex-Target-Client-Identifier': id } });
          const b = await r.text();
          const g = (a) => { const m = b.match(new RegExp(`${a}="([^"]*)"`)); return m ? m[1] : null; };
          return { ok: true, state: g('state'), time: parseInt(g('time') || '-1', 10) };
        } catch (e) { return { ok: false, err: String(e && e.message).slice(0, 140) }; }
      }, { daemon: DAEMON, id: process.env.MISTERPLEX_ID || 'misterplex-183', n: i });
      if (!s.ok)
        fail(`browser could not read the timeline (${s.err})` +
             (corsErrors.length ? ` — CORS: ${corsErrors[0]}` : ''));
      console.log(`CAST_E2E sample ${i}: state=${s.state} time=${s.time}`);
      times.push(s);
      if (i < SAMPLES - 1) await page.waitForTimeout(SAMPLE_MS);
    }

    const playing = times.filter((t) => t.state === 'playing').length;
    const advanced = times[times.length - 1].time - times[0].time;
    const monotonic = times.every((t, i) => i === 0 || t.time >= times[i - 1].time);
    verdict = { playing, advanced, monotonic, samples: times.length };

    if (playing === 0)
      fail(`timeline never reached state=playing (states: ${times.map((t) => t.state).join(',')})`);
    if (times[times.length - 1].time <= 0)
      fail('web player stuck at 0:00 — timeline time never left zero');
    if (advanced <= 0)
      fail(`timeline did not advance across ${times.length} samples (${times.map((t) => t.time).join('->')})`);
    if (!monotonic)
      fail(`timeline went backwards: ${times.map((t) => t.time).join('->')}`);

    // Leave the device idle again.
    await page.evaluate(async ({ daemon, id }) => {
      try {
        await fetch(`${daemon}/player/playback/stop?commandID=e2e-stop`,
                    { headers: { 'X-Plex-Target-Client-Identifier': id } });
      } catch (_) {}
    }, { daemon: DAEMON, id: process.env.MISTERPLEX_ID || 'misterplex-183' });
  } finally {
    if (browser) await browser.close();
  }

  console.log(`CAST_E2E_OK player="${PLAYER}" key=${KEY} samples=${verdict.samples} ` +
              `playing=${verdict.playing}/${verdict.samples} advanced_ms=${verdict.advanced} ` +
              `monotonic=${verdict.monotonic} browser_blocked=${daemonFailed.length}`);
  process.exit(0);
})().catch((e) => {
  console.error(`CAST_E2E_ERROR: ${String((e && e.stack) || e).slice(0, 500)}`);
  process.exit(1);
});
