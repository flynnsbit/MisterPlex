#!/usr/bin/env node
/**
 * test_cast_picker_playwright.js
 *
 * Playwright drives real Plex Web against a LOCAL PMS and verifies MiSTerPlex
 * end-to-end as a cast target:
 *   1. Sign in (token injection)
 *   2. Open "MiSTerPlex Tests" library item (default 240p / RK3)
 *   3. Open Select Player and ASSERT MiSTerPlex is listed (regression gate)
 *   4. Select MiSTerPlex, start playback, assert playing
 *   5. Stop (and best-effort pause)
 *
 * Exit codes:
 *   0  PASS
 *   1  FAIL — picker missing MiSTerPlex, playback did not start, controls failed
 *  77  SKIP-NOT-PASS — missing env/deps/PMS unreachable (not a green gate)
 *
 * Credentials: PLEX_BASE + PLEX_TOKEN env, or MISTERPLEX_CONF / ~/.config/...
 * NEVER hardcode private PMS :32400 or tokens (test_no_private_data).
 *
 * Usage:
 *   PLEX_BASE=http://YOUR-PLEX-SERVER:32400 PLEX_TOKEN=… \
 *     node tests/hw/e2e/test_cast_picker_playwright.js
 *
 *   # or after npm install in tests/hw/e2e:
 *   ./tests/hw/e2e/run_cast_picker.sh
 */

'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { loadConfig, daemonBase, redact } = require('./conf');

const EXIT_PASS = 0;
const EXIT_FAIL = 1;
const EXIT_SKIP = 77;

const cfg = loadConfig();

function log(...a) {
  console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : x)));
}

function skip(reason) {
  console.error(`SKIP-NOT-PASS test_cast_picker_playwright: ${reason}`);
  process.exit(EXIT_SKIP);
}

function fail(reason, detail) {
  console.error(`FAIL test_cast_picker_playwright: ${reason}`);
  if (detail) console.error(detail);
  process.exit(EXIT_FAIL);
}

function ensureOutDir() {
  fs.mkdirSync(cfg.outDir, { recursive: true });
}

async function shot(page, name) {
  try {
    ensureOutDir();
    const p = path.join(cfg.outDir, `${name}.png`);
    await page.screenshot({ path: p, fullPage: true });
    log(`screenshot ${p}`);
    return p;
  } catch (e) {
    log(`screenshot failed: ${e.message}`);
    return '';
  }
}

function httpGet(url, headers = {}, timeoutMs = 8000) {
  return new Promise((resolve) => {
    const lib = url.startsWith('https') ? https : http;
    const req = lib.get(url, { headers, timeout: timeoutMs, rejectUnauthorized: false }, (res) => {
      let body = '';
      res.on('data', (d) => {
        body += d;
      });
      res.on('end', () => resolve({ status: res.statusCode || 0, body }));
    });
    req.on('error', () => resolve({ status: 0, body: '' }));
    req.on('timeout', () => {
      req.destroy();
      resolve({ status: 0, body: '' });
    });
  });
}

function xmlAttr(xml, attr) {
  const m = String(xml).match(new RegExp(`${attr}="([^"]*)"`));
  return m ? m[1] : null;
}

function loadPlaywright() {
  const local = path.join(__dirname, 'node_modules', 'playwright');
  try {
    return require(local);
  } catch (_) {
    try {
      return require('playwright');
    } catch (_2) {
      skip(
        'playwright not installed — run: (cd tests/hw/e2e && npm install && npx playwright install chromium)'
      );
    }
  }
}

async function resolveRatingKey() {
  if (cfg.ratingKey) return String(cfg.ratingKey).replace(/^\/library\/metadata\//, '');
  if (cfg.plexKey) {
    const m = String(cfg.plexKey).match(/metadata\/(\d+)/);
    if (m) return m[1];
  }

  const headers = {
    'X-Plex-Token': cfg.token,
    Accept: 'application/json',
  };
  const sec = await httpGet(`${cfg.plexBase}/library/sections`, headers);
  if (sec.status !== 200) {
    fail('pms_sections_unreachable', `HTTP ${sec.status} from ${cfg.plexBase}/library/sections`);
  }
  let sections;
  try {
    sections = JSON.parse(sec.body);
  } catch (_) {
    fail('pms_sections_bad_json', 'could not parse /library/sections');
  }
  const dirs = sections.MediaContainer?.Directory || [];
  const lib = dirs.find((d) => (d.title || '').includes(cfg.libraryName));
  if (!lib) {
    fail(
      'library_not_found',
      `no section title containing ${JSON.stringify(cfg.libraryName)}; have: ${dirs
        .map((d) => d.title)
        .join(' | ')}`
    );
  }
  const all = await httpGet(`${cfg.plexBase}/library/sections/${lib.key}/all`, headers);
  if (all.status !== 200) fail('library_all_unreachable', `HTTP ${all.status}`);
  let items;
  try {
    items = JSON.parse(all.body);
  } catch (_) {
    fail('library_all_bad_json');
  }
  const metas = items.MediaContainer?.Metadata || [];
  const hit =
    metas.find((m) => (m.title || '') === cfg.itemTitle) ||
    metas.find((m) => (m.title || '').includes(cfg.itemTitle));
  if (!hit) {
    fail(
      'item_not_found',
      `no item matching ${JSON.stringify(cfg.itemTitle)}; have: ${metas
        .map((m) => m.title)
        .slice(0, 12)
        .join(' | ')}`
    );
  }
  log(`resolved library=${lib.title} ratingKey=${hit.ratingKey} title=${hit.title}`);
  return String(hit.ratingKey);
}

async function pmsIdentity() {
  const r = await httpGet(`${cfg.plexBase}/identity`);
  const id = xmlAttr(r.body, 'machineIdentifier') || '';
  const name = xmlAttr(r.body, 'friendlyName') || '';
  return { machineId: id, friendlyName: name, status: r.status };
}

async function pollDaemonTimeline(cmdId) {
  const url = `${daemonBase(cfg)}/player/timeline/poll?commandID=${cmdId}&wait=0`;
  const r = await httpGet(url, {}, 4000);
  return r.body || '';
}


async function pageBodyText(page, n = 800) {
  return page
    .evaluate((lim) => ((document.body && document.body.innerText) || '').slice(0, lim), n)
    .catch(() => '');
}

function parseProfileNames(bodyText) {
  const lines = String(bodyText || '')
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean);
  return lines.filter(
    (s) =>
      !/^select user$/i.test(s) &&
      !/^managed account$/i.test(s) &&
      !/^add user/i.test(s) &&
      !/^(teen|younger kid|adult)$/i.test(s) &&
      s.length < 40
  );
}

async function waitForUserPickerOrShell(page, maxMs = 90000) {
  const deadline = Date.now() + maxMs;
  while (Date.now() < deadline) {
    const t = await pageBodyText(page, 800);
    const names = parseProfileNames(t);
    // Require at least one profile name — title-only "Select User" + spinner is not ready.
    if (/select user/i.test(t) && names.length > 0) return { phase: 'picker', names, text: t };
    if (await page.locator('[aria-label="Select Player"]').first().isVisible().catch(() => false)) {
      return { phase: 'shell', names: [], text: t };
    }
    if (/\bhome\b/i.test(t) && /library|movies|tv shows|watchlist|tests/i.test(t) && !/select user/i.test(t)) {
      return { phase: 'shell', names: [], text: t };
    }
    if (/sign in|log in/i.test(t) && t.length < 400) return { phase: 'signin', names: [], text: t };
    await page.waitForTimeout(1500);
  }
  const t = await pageBodyText(page, 800);
  return { phase: 'timeout', names: parseProfileNames(t), text: t };
}

async function dismissUserPicker(page, preferred) {
  // Plex Home: "Select User" blocks the whole shell until a profile is chosen.
  const gate = await waitForUserPickerOrShell(page, 90000);
  if (gate.phase === 'shell') return { shown: false, picked: null, phase: 'shell' };
  if (gate.phase === 'signin') return { shown: false, picked: null, phase: 'signin' };
  if (gate.phase !== 'picker') {
    return { shown: false, picked: null, phase: gate.phase, names: gate.names, text: gate.text };
  }

  const names = gate.names || [];
  const target =
    preferred && names.some((n) => n.toLowerCase() === preferred.toLowerCase())
      ? names.find((n) => n.toLowerCase() === preferred.toLowerCase())
      : names[0];
  if (!target) return { shown: true, picked: null, names, phase: 'picker' };

  log(`user_picker clicking profile=${target} options=${names.slice(0, 8).join('|')}`);
  try {
    await page.getByText(target, { exact: true }).first().click({ timeout: 15000 });
  } catch (e) {
    // Fallback: click the tile that contains the name text.
    try {
      await page.locator(`text=${target}`).first().click({ timeout: 8000 });
    } catch (e2) {
      return { shown: true, picked: null, error: e2.message || e.message, names };
    }
  }

  const after = await waitForUserPickerOrShell(page, 60000);
  if (after.phase === 'shell') return { shown: true, picked: target, phase: 'shell' };
  if (after.phase === 'picker') {
    return { shown: true, picked: null, still_on_picker: true, names: after.names };
  }
  return { shown: true, picked: null, phase: after.phase, names: after.names, text: after.text };
}

async function waitForSelectPlayerControl(page, maxMs = 60000) {
  const deadline = Date.now() + maxMs;
  const selectors = [
    'a[aria-label="Select Player"]',
    'button[aria-label="Select Player"]',
    '[aria-label="Select Player"]',
    '[data-testid="cast-button"]',
  ];
  while (Date.now() < deadline) {
    const t = await pageBodyText(page, 400);
    if (/select user/i.test(t) && parseProfileNames(t).length > 0) return { kind: 'user_picker' };
    for (const sel of selectors) {
      try {
        const el = page.locator(sel).first();
        if (await el.isVisible().catch(() => false)) return { kind: 'ok', sel, el };
      } catch (_) {}
    }
    await page.waitForTimeout(1000);
  }
  return { kind: 'timeout' };
}

async function handleResumeDialog(page) {


  try {
    const btn = page.getByText(/start from the beginning/i).first();
    if (await btn.isVisible({ timeout: 4000 }).catch(() => false)) {
      await btn.click();
      log('resume_dialog: start from beginning');
      return true;
    }
  } catch (_) {}
  return false;
}

async function openSelectPlayer(page) {
  // Parent-measured primary control (Plex Web "Select Player", not "Cast").
  const selectors = [
    'a[aria-label="Select Player"]',
    'button[aria-label="Select Player"]',
    '[aria-label="Select Player"]',
    '[data-testid="cast-button"]',
    '[aria-label*="Cast" i]',
    '[title*="Cast" i]',
    'button:has-text("Cast")',
  ];
  for (const sel of selectors) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 2500 }).catch(() => false)) {
        log(`select_player_control selector=${sel}`);
        await el.click({ timeout: 5000 });
        return sel;
      }
    } catch (_) {
      /* next */
    }
  }
  return null;
}

async function readPickerLabels(page) {
  // Collect visible text from common menu/dialog surfaces after opening picker.
  return page.evaluate(() => {
    const roots = [
      ...document.querySelectorAll('[role="menu"], [role="listbox"], [role="dialog"], [class*="Menu"], [class*="menu"]'),
    ];
    const texts = [];
    const walk = (el) => {
      if (!el) return;
      const t = (el.innerText || el.textContent || '').trim();
      if (t && t.length < 200) texts.push(t);
    };
    if (roots.length === 0) walk(document.body);
    else roots.forEach(walk);
    // Flatten unique lines
    const lines = new Set();
    for (const block of texts) {
      for (const line of block.split(/\n+/)) {
        const s = line.trim();
        if (s) lines.add(s);
      }
    }
    return [...lines];
  });
}

async function assertMisterplexInPicker(page) {
  const name = cfg.castName;
  // Prefer exact / role-based hits
  const candidates = [
    page.getByRole('menuitem', { name: new RegExp(name, 'i') }),
    page.getByRole('option', { name: new RegExp(name, 'i') }),
    page.getByText(name, { exact: true }),
    page.locator(`[data-testid*="cast"] :text-is("${name}")`),
    page.locator(`text=${name}`),
  ];

  for (const loc of candidates) {
    try {
      const first = loc.first();
      if (await first.isVisible({ timeout: 4000 }).catch(() => false)) {
        log(`picker_hit castName=${name}`);
        return first;
      }
    } catch (_) {
      /* next */
    }
  }

  const labels = await readPickerLabels(page);
  await shot(page, 'fail_picker_no_misterplex');
  const preview = labels.slice(0, 40).join(' | ');
  fail(
    'picker_did_not_contain_MiSTerPlex',
    `Select Player opened but ${JSON.stringify(name)} was not found.\n` +
      `Picker labels (sample): ${preview || '(empty)'}\n` +
      `See companionServer/FriendlyName runbook: docs/select-player-runbook.md`
  );
}

async function clickPlay(page) {
  const selectors = [
    '[data-testid="preplay-play"]',
    '[data-qa="preplayPlayButton"]',
    'button[aria-label="Play"]',
    '[aria-label="Play"]',
    'button:has-text("Play")',
    '[class*="PlayButton"]',
  ];
  for (const sel of selectors) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 3000 }).catch(() => false)) {
        log(`play_button selector=${sel}`);
        await el.click({ timeout: 5000 });
        return true;
      }
    } catch (_) {
      /* next */
    }
  }
  return false;
}

async function clickPauseOrPlayToggle(page) {
  const sels = [
    'button[aria-label="Pause"]',
    '[aria-label="Pause"]',
    'button[aria-label="Play"]',
    '[aria-label="Play"]',
  ];
  for (const sel of sels) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 2000 }).catch(() => false)) {
        await el.click();
        return sel;
      }
    } catch (_) {
      /* next */
    }
  }
  return null;
}

async function clickStop(page) {
  const sels = [
    'button[aria-label="Stop"]',
    '[aria-label="Stop"]',
    'button:has-text("Stop")',
    '[data-testid*="stop"]',
  ];
  for (const sel of sels) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 2000 }).catch(() => false)) {
        await el.click();
        log(`stop_button selector=${sel}`);
        return true;
      }
    } catch (_) {
      /* next */
    }
  }
  // Fallback: companion HTTP stop (still validates player path; UI stop preferred)
  const r = await httpGet(
    `${daemonBase(cfg)}/player/playback/stop?commandID=9901`,
    {},
    3000
  );
  log(`stop_http status=${r.status}`);
  return r.status === 200;
}

async function waitPlayingOnDaemon(seconds) {
  const deadline = Date.now() + seconds * 1000;
  let cmd = 8000;
  let last = '';
  let playing = 0;
  let advance = 0;
  let prev = -1;
  let maxT = 0;
  while (Date.now() < deadline) {
    const xml = await pollDaemonTimeline(cmd++);
    last = xml;
    const state = xmlAttr(xml, 'state');
    const t = parseInt(xmlAttr(xml, 'time') || '-1', 10);
    log(`  timeline state=${state || '?'} time=${xmlAttr(xml, 'time') || '?'}`);
    if (state === 'playing') {
      playing++;
      if (t > prev && prev >= 0) advance++;
      if (t > maxT) maxT = t;
    }
    if (t >= 0) prev = t;
    await new Promise((r) => setTimeout(r, 1000));
  }
  return { playing, advance, maxT, last };
}

(async () => {
  log('test_cast_picker_playwright: BEGIN');
  log(`conf=${cfg.confPath} library=${cfg.libraryName} item~=${cfg.itemTitle} cast=${cfg.castName}`);

  if (!cfg.plexBase) {
    skip('PLEX_BASE missing — export PLEX_BASE=http://YOUR-PLEX-SERVER:32400 or set in conf');
  }
  if (!cfg.token) {
    skip('PLEX_TOKEN missing — export PLEX_TOKEN or set in conf');
  }
  if (/plex\.nevertrustaf\.art|32401/.test(cfg.plexBase)) {
    fail(
      'refusing_non_local_pms',
      `PLEX_BASE looks like a remote/ignored server (${cfg.plexBase}). ` +
        'Point PLEX_BASE at the LOCAL PMS only.'
    );
  }

  // Sanity: web UI reachable
  const web = await httpGet(`${cfg.plexBase}/web/index.html`);
  if (web.status < 200 || web.status >= 400) {
    skip(`Plex Web unreachable at ${cfg.plexBase}/web/index.html HTTP ${web.status}`);
  }

  const idn = await pmsIdentity();
  log(`pms_identity status=${idn.status} friendlyName=${idn.friendlyName || '?'} machineId=${idn.machineId || '?'}`);

  const ratingKey = await resolveRatingKey();
  const metaKey = `/library/metadata/${ratingKey}`;

  // Daemon optional for picker assertion; required for playback assertion.
  const baseTl = await pollDaemonTimeline(7000);
  const daemonUp = baseTl.includes('Timeline') || baseTl.includes('MediaContainer');
  if (!daemonUp) {
    log(`WARN daemon timeline not reachable at ${daemonBase(cfg)} — picker will still be scored; playback assert may fail`);
  } else {
    log(`daemon_ok ${daemonBase(cfg)}`);
  }

  const playwright = loadPlaywright();
  const { chromium } = playwright;

  let browser;
  try {
    const launchOpts = {
      headless: cfg.headless,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (cfg.chromiumPath) {
      launchOpts.executablePath = cfg.chromiumPath;
      log(`chromium_path ${cfg.chromiumPath}`);
    }
    browser = await chromium.launch(launchOpts);
  } catch (e) {
    skip(
      `chromium launch failed: ${e.message}. ` +
        'Run: (cd tests/hw/e2e && npx playwright install chromium) ' +
        'or set PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH to a Chrome for Testing binary.'
    );
  }

  const context = await browser.newContext({
    viewport: { width: 1400, height: 900 },
    storageState: {
      origins: [
        {
          origin: cfg.plexBase,
          localStorage: [
            { name: 'myPlexAccessToken', value: cfg.token },
            { name: 'myPlexAuthToken', value: cfg.token },
          ],
        },
      ],
    },
  });

  // Also set cookie token used by some PMS web builds
  await context.addCookies([
    {
      name: 'X-Plex-Token',
      value: cfg.token,
      url: cfg.plexBase,
    },
  ]);

  // Token via storageState only (matches lab probe). addInitScript can leave the
  // Home profile list spinning on some Plex Web builds.
  const page = await context.newPage();
  page.setDefaultTimeout(cfg.timeoutMs);
  page.on('pageerror', (e) => log(`browser-err ${String(e.message).slice(0, 100)}`));

  try {
    // ── 1. Launch Plex Web on LOCAL PMS ─────────────────────────────────────
    const home = `${cfg.plexBase}/web/index.html`;
    log(`goto ${home}`);
    await page.goto(home, { waitUntil: 'domcontentloaded', timeout: cfg.timeoutMs });
    await page.waitForTimeout(2000);
    let url = page.url();
    log(`landed ${url}`);

    if (/signin|login/i.test(url)) {
      await page.goto(`${home}#?X-Plex-Token=${encodeURIComponent(cfg.token)}`, {
        waitUntil: 'domcontentloaded',
        timeout: cfg.timeoutMs,
      });
      await page.waitForTimeout(4000);
      url = page.url();
      log(`after_token_hash ${url}`);
    }
    if (/signin|login/i.test(url)) {
      await shot(page, 'fail_signin_redirect');
      fail(
        'plex_web_signin_required',
        'Plex Web redirected to sign-in; token injection did not establish a session. ' +
          'Confirm PLEX_TOKEN is an account/server token accepted by this PMS web UI.'
      );
    }

    // Plex Home profile gate — shell never renders until dismissed.
    // Body is often empty/spinner for several seconds before "Select User".
    log('waiting for Select User or shell...');
    const pickerUser = await dismissUserPicker(page, cfg.webUser);
    log(`user_gate phase=${pickerUser.phase || (pickerUser.shown ? 'picker' : 'none')} picked=${pickerUser.picked || '-'}`);
    if (pickerUser.phase === 'signin') {
      await shot(page, 'fail_signin_redirect');
      fail('plex_web_signin_required', 'Plex Web shows sign-in after token injection.');
    }
    if (pickerUser.shown && !pickerUser.picked) {
      await shot(page, 'fail_user_picker');
      fail(
        'plex_home_user_picker_not_dismissed',
        'Plex Web "Select User" is blocking the shell. ' +
          'Set PLEX_WEB_USER to a profile name on this PMS (admin/home user). ' +
          (pickerUser.error ? `click_error=${pickerUser.error}` : '') +
          (pickerUser.names ? ` names=${pickerUser.names.join('|')}` : '')
      );
    }
    if (pickerUser.shown) log(`user_picker dismissed profile=${pickerUser.picked}`);

    // ── 2. Open test item ───────────────────────────────────────────────────
    const serverSeg = idn.machineId || 'auto';
    const details = `${cfg.plexBase}/web/index.html#!/server/${serverSeg}/details?key=${encodeURIComponent(
      metaKey
    )}`;
    log(`goto details key=${metaKey}`);
    await page.goto(details, { waitUntil: 'domcontentloaded', timeout: cfg.timeoutMs });
    // Details can flash spinner / re-show user picker while connections settle.
    const picker2 = await dismissUserPicker(page, cfg.webUser);
    if (picker2.shown && picker2.picked) log(`user_picker re-dismissed profile=${picker2.picked}`);
    if (picker2.shown && !picker2.picked) {
      await shot(page, 'fail_user_picker_after_details');
      fail('plex_home_user_picker_not_dismissed', 'Select User still showing after details navigation.');
    }
    log(`at ${page.url()}`);
    await shot(page, '01_details');

    // ── 3. Select Player — assert MiSTerPlex present ────────────────────────
    const ctl = await waitForSelectPlayerControl(page, 45000);
    if (ctl.kind === 'user_picker') {
      const again = await dismissUserPicker(page, cfg.webUser);
      if (!again.picked && again.shown) {
        await shot(page, 'fail_user_picker_before_cast');
        fail('plex_home_user_picker_not_dismissed', 'Select User reappeared before cast control.');
      }
    }
    let opened = null;
    if (ctl.kind === 'ok') {
      log(`select_player_control selector=${ctl.sel}`);
      await ctl.el.click({ timeout: 5000 });
      opened = ctl.sel;
    } else {
      opened = await openSelectPlayer(page);
    }
    if (!opened) {
      await shot(page, 'fail_no_select_player_control');
      const body = await pageBodyText(page, 400);
      fail(
        'select_player_control_not_found',
        'Could not find Select Player / cast control on the details page. ' +
          `body_sample=${JSON.stringify(body.slice(0, 200))}`
      );
    }
    await page.waitForTimeout(1500);
    await shot(page, '02_picker_open');

    const target = await assertMisterplexInPicker(page);
    await target.click();
    log('selected_cast_target');
    await page.waitForTimeout(1000);
    await shot(page, '03_target_selected');

    // ── 4. Play ─────────────────────────────────────────────────────────────
    const played = await clickPlay(page);
    if (!played) {
      // Sometimes selecting the player auto-focuses; try keyboard / second open
      log('play button not immediately visible — retry after short wait');
      await page.waitForTimeout(1500);
      if (!(await clickPlay(page))) {
        await shot(page, 'fail_no_play_button');
        fail('play_button_not_found', 'MiSTerPlex was selectable but Play control was not found.');
      }
    }
    log('play_clicked');
    await handleResumeDialog(page);
    await shot(page, '04_play_clicked');

    if (!daemonUp) {
      await shot(page, 'fail_daemon_down_after_play');
      fail(
        'playback_did_not_start',
        `Play was clicked in Plex Web but companion at ${daemonBase(cfg)} is unreachable — cannot confirm playing state.`
      );
    }

    const prog = await waitPlayingOnDaemon(cfg.playWaitSec);
    if (prog.playing < 2) {
      await shot(page, 'fail_not_playing');
      fail(
        'playback_did_not_start',
        `UI play clicked but daemon timeline never stayed in state=playing ` +
          `(playing_samples=${prog.playing} time_max_ms=${prog.maxT}). ` +
          `Picker contained ${cfg.castName}; failure is post-select playback.`
      );
    }
    log(`playing_ok samples=${prog.playing} advance=${prog.advance} time_max_ms=${prog.maxT}`);

    // ── 5. Pause (best-effort) + Stop ───────────────────────────────────────
    const toggled = await clickPauseOrPlayToggle(page);
    if (toggled) {
      log(`pause_or_toggle ${toggled}`);
      await page.waitForTimeout(1500);
      const xml = await pollDaemonTimeline(9001);
      log(`after_toggle state=${xmlAttr(xml, 'state') || '?'}`);
    } else {
      log('pause_control_not_found (non-fatal)');
    }

    const stopped = await clickStop(page);
    if (!stopped) {
      await shot(page, 'fail_stop');
      fail('stop_failed', 'Could not stop via UI or companion HTTP.');
    }
    await page.waitForTimeout(1500);
    const afterStop = await pollDaemonTimeline(9002);
    log(`after_stop state=${xmlAttr(afterStop, 'state') || '?'}`);
    await shot(page, '05_stopped');

    log('CAST_PICKER_E2E_RESULT=PASS');
    log(
      `summary picker=ok play=ok stop=ok cast=${cfg.castName} ratingKey=${ratingKey} time_max_ms=${prog.maxT}`
    );
    process.exitCode = EXIT_PASS;
  } catch (e) {
    await shot(page, 'fail_unhandled');
    fail('unhandled_error', redact(e.stack || e.message || String(e)));
  } finally {
    await browser.close().catch(() => {});
  }
})().catch((e) => {
  console.error(`UNHANDLED: ${redact(e.message || e)}`);
  process.exit(EXIT_SKIP);
});
