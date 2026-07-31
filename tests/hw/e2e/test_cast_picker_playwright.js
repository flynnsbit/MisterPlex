#!/usr/bin/env node
/**
 * test_cast_picker_playwright.js
 *
 * Playwright drives real Plex Web against a LOCAL PMS and verifies MiSTerPlex
 * end-to-end as a cast target:
 *   1. Sign in (token injection) + dismiss Plex Home "Select User"
 *   2. Open "MiSTerPlex Tests" library item (default 240p / RK3)
 *   3. Open Select Player; assert MiSTerPlex via BEFORE/AFTER body-text DIFF
 *      (whole-page regex for "MiSTerPlex" is a FALSE POSITIVE — library/item/
 *      server names all contain it)
 *   4. Assert WHICH companion server Web polled (/clients + /neighborhood/devices)
 *      via context.on('request') — page.on('request') captures 0 of these
 *   5. Select MiSTerPlex, start playback, assert companion timeline playing
 *   6. Stop (and best-effort pause)
 *
 * Exit codes:
 *   0  PASS
 *   1  FAIL — picker / companion / playback
 *  77  SKIP-NOT-PASS — missing env/deps/PMS unreachable (never a green gate)
 *
 * Credentials: PLEX_BASE + PLEX_TOKEN env, or MISTERPLEX_CONF / ~/.config/...
 * NEVER hardcode private PMS :32400 or tokens (test_no_private_data).
 *
 * Usage:
 *   PLEX_BASE=http://YOUR-PLEX-SERVER:32400 PLEX_TOKEN=… \
 *     node tests/hw/e2e/test_cast_picker_playwright.js
 *   ./tests/hw/e2e/run_cast_picker.sh
 *   make e2e-cast-picker
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

/** Full body line set — used for picker BEFORE/AFTER diff (false-positive guard). */
async function bodyLineSet(page) {
  const text = await page
    .evaluate(() => (document.body && document.body.innerText) || '')
    .catch(() => '');
  return new Set(
    String(text)
      .split(/\n+/)
      .map((s) => s.trim())
      .filter(Boolean)
  );
}

function addedLines(before, after) {
  const out = [];
  for (const line of after) {
    if (!before.has(line)) out.push(line);
  }
  return out;
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

/**
 * Click a Plex Home profile tile.
 * HARD TRAP (lab): getByText(name).click() does NOT dismiss Select User —
 * only clicking the avatar circle ~40px above the label works. Broad
 * ancestor queries can hit a non-interactive wrapper and silently no-op.
 */
async function clickHomeProfile(page, target) {
  const label = page.getByText(target, { exact: true }).first();
  await label.waitFor({ state: 'visible', timeout: 15000 });
  const box = await label.boundingBox();
  if (!box) {
    await label.click({ timeout: 5000, force: true });
    return 'text_force_no_box';
  }

  // Primary (proven): avatar circle centered above the name label.
  const x = box.x + box.width / 2;
  for (const dy of [40, 55, 28, 70]) {
    const y = Math.max(8, box.y - dy);
    await page.mouse.click(x, y);
    await page.waitForTimeout(1200);
    const t = await pageBodyText(page, 400);
    if (!/select user/i.test(t)) return `mouse_avatar_dy${dy}`;
  }

  // Narrow ancestor: only a small button/link near the label (not page root).
  const handle = await label.elementHandle();
  if (handle) {
    const clicked = await page.evaluate((el) => {
      let n = el;
      for (let i = 0; i < 6 && n; i++) {
        n = n.parentElement;
        if (!n) break;
        const tag = (n.tagName || '').toLowerCase();
        const role = n.getAttribute('role') || '';
        const clickable =
          tag === 'button' || tag === 'a' || role === 'button' || n.onclick != null;
        if (!clickable) continue;
        const r = n.getBoundingClientRect();
        if (r.width > 0 && r.width <= 220 && r.height > 0 && r.height <= 280) {
          n.click();
          return true;
        }
      }
      return false;
    }, handle);
    if (clicked) return 'small_ancestor_click';
  }

  await label.click({ timeout: 5000, force: true });
  return 'text_force';
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
  let how = '';
  try {
    how = await clickHomeProfile(page, target);
    log(`user_picker click_method=${how}`);
  } catch (e) {
    return { shown: true, picked: null, error: e.message, names, phase: 'picker' };
  }

  // Profile switch can take a while (servers reconnect under the chosen user).
  for (let attempt = 0; attempt < 2; attempt++) {
    const after = await waitForUserPickerOrShell(page, 45000);
    if (after.phase === 'shell') return { shown: true, picked: target, phase: 'shell', how };
    if (after.phase !== 'picker') {
      return { shown: true, picked: null, phase: after.phase, names: after.names, text: after.text, how };
    }
    // Still on picker — retry avatar click once.
    log(`user_picker still_open retry=${attempt + 1}`);
    try {
      how = await clickHomeProfile(page, target);
      log(`user_picker retry_method=${how}`);
    } catch (e) {
      return { shown: true, picked: null, still_on_picker: true, error: e.message, names, how };
    }
  }
  return { shown: true, picked: null, still_on_picker: true, names, how };
}

async function waitForSelectPlayerControl(page, maxMs = 60000) {
  const deadline = Date.now() + maxMs;
  // Parent-measured primary control: a[aria-label="Select Player"] — NOT "Cast".
  const selectors = [
    'a[aria-label="Select Player"]',
    'button[aria-label="Select Player"]',
    '[aria-label="Select Player"]',
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

/**
 * Discovery URL tracker. HARD TRAP: page.on('request') captured 0 of these;
 * context.on('request') captured hundreds. Always attach at context level.
 */
function attachDiscoveryTracker(context) {
  const all = [];
  const discovery = [];
  const onReq = (r) => {
    const u = r.url();
    all.push(u);
    // companionServer feeds picker via these two endpoints only
    if (/\/clients(?:\?|$)/.test(u) || /\/neighborhood\/devices/.test(u)) {
      discovery.push(u);
    }
  };
  context.on('request', onReq);
  return {
    all,
    discovery,
    resetDiscovery() {
      discovery.length = 0;
    },
    detach() {
      try {
        context.off('request', onReq);
      } catch (_) {}
    },
  };
}

function hostFromUrl(u) {
  try {
    return new URL(u).hostname;
  } catch (_) {
    return '';
  }
}

/** Normalize hostname → comparable key (IP or dashed plex.direct → dotted IP). */
function normalizeHostKey(host) {
  if (!host) return '';
  const h = String(host).toLowerCase();
  if (h === 'localhost') return '127.0.0.1';
  // 192-168-1-24.<hash>.plex.direct → 192.168.1.24
  const m = h.match(/^(\d{1,3}(?:-\d{1,3}){3})\./);
  if (m) return m[1].replace(/-/g, '.');
  return h;
}

function expectedCompanionKeys(cfg) {
  const keys = new Set();
  const explicit = process.env.EXPECT_COMPANION_HOST || cfg.expectCompanionHost || '';
  if (explicit) {
    for (const part of explicit.split(/[,\s]+/).filter(Boolean)) {
      keys.add(normalizeHostKey(part));
    }
  }
  try {
    const u = new URL(cfg.plexBase);
    keys.add(normalizeHostKey(u.hostname));
  } catch (_) {}
  // Web on the PMS host often hits loopback for companionServer.
  if (process.env.ALLOW_LOOPBACK_COMPANION !== '0') {
    keys.add('127.0.0.1');
  }
  return keys;
}

/**
 * Assert companion server chosen by Plex Web.
 *
 * Portable rule: discovery hosts must match PLEX_BASE (or EXPECT_COMPANION_HOST).
 * Does NOT encode a household SHIELD IP. Multi-PMS ordering fragility is caught
 * when Web polls a different owned server than the one under test.
 *
 * ASSERT_COMPANION=0 → log only, exit still can PASS on picker+play (lab debug).
 * Default ASSERT_COMPANION=1 when discovery traffic is expected.
 */
function assertCompanionServer(tracker) {
  const urls = [...tracker.discovery];
  const hosts = [...new Set(urls.map(hostFromUrl).filter(Boolean))];
  const keys = hosts.map(normalizeHostKey);
  const uniqueKeys = [...new Set(keys)];

  log(`companion_discovery_count=${urls.length}`);
  for (const u of [...new Set(urls)].slice(0, 12)) {
    log(`  discovery ${u.split('?')[0]}`);
  }
  log(`companion_hosts_raw=${hosts.join(',') || '(none)'}`);
  log(`companion_hosts_norm=${uniqueKeys.join(',') || '(none)'}`);

  const mode = (process.env.ASSERT_COMPANION || '1').trim();
  if (mode === '0' || /^skip|off|no$/i.test(mode)) {
    // Explicit skip of topology assert — NOT a pass of the companion check.
    log('COMPANION_ASSERT=SKIP-NOT-PASS reason=ASSERT_COMPANION=0 (logged only)');
    return { skipped: true, hosts: uniqueKeys, urls };
  }

  if (urls.length === 0) {
    fail(
      'companion_discovery_not_observed',
      'Opened Select Player but context captured zero /clients or /neighborhood/devices requests. ' +
        `Total context requests=${tracker.all.length}. ` +
        'If this is a cached picker with no network, set ASSERT_COMPANION=0 to log-only (still not a companion PASS).'
    );
  }

  const expected = expectedCompanionKeys(cfg);
  log(`companion_expected_keys=${[...expected].join(',')}`);

  const hit = uniqueKeys.filter((k) => expected.has(k));
  if (hit.length === 0) {
    fail(
      'wrong_companion_server',
      'Plex Web polled a companionServer that is NOT the PLEX_BASE under test.\n' +
        `  polled_norm=${uniqueKeys.join(',')}\n` +
        `  expected_norm=${[...expected].join(',')}\n` +
        'This is the FriendlyName sort-order fragility: Web takes the first owned, ' +
        'non-cloud, private, connected server by lowercased friendlyName.\n' +
        'See docs/select-player-runbook.md — rename the intended PMS so it sorts first.\n' +
        'Do not "fix" this by encoding another household server IP into CI.'
    );
  }

  log(`COMPANION_ASSERT=PASS matched=${hit.join(',')} polled=${uniqueKeys.join(',')}`);
  return { skipped: false, hosts: uniqueKeys, matched: hit, urls };
}

/**
 * HARD TRAP: never score MiSTerPlex by scanning the whole page.
 * Library "MiSTerPlex Tests", item "MiSTerPlex Test 240p", server
 * "MiSTerPlex Studio" all produce false positives. Only NEW lines after
 * opening Select Player count.
 */
async function assertMisterplexInPickerDiff(page, beforeSet) {
  const name = cfg.castName;
  const afterSet = await bodyLineSet(page);
  const added = addedLines(beforeSet, afterSet);
  log(`picker_added_line_count=${added.length}`);
  for (const line of added.slice(0, 40)) {
    log(`  picker+ ${line}`);
  }

  // Prefer an exact new line equal to cast name; also accept a line that is
  // exactly the cast target (not library/item/server titles which were present before).
  const nameRe = new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'i');
  const hitExact = added.some((l) => nameRe.test(l));
  // Some builds suffix status: "MiSTerPlex" on its own line is ideal; also
  // "MiSTerPlex\nAvailable" as separate lines. Reject lines that clearly look
  // like library/item titles if they somehow appear only after open.
  const hitLoose = added.some(
    (l) =>
      nameRe.test(l) ||
      (new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i').test(l) &&
        !/tests|soak|studio|240p|480p|720p|1080p|metadata/i.test(l) &&
        l.length <= name.length + 24)
  );

  const ok = hitExact || hitLoose;
  log(`MISTERPLEX_IN_PICKER=${ok} hitExact=${hitExact} hitLoose=${hitLoose}`);

  if (!ok) {
    await shot(page, 'fail_picker_no_misterplex');
    fail(
      'picker_did_not_contain_MiSTerPlex',
      `Select Player opened but ${JSON.stringify(name)} was not in BEFORE/AFTER body diff.\n` +
        `Added lines (sample): ${added.slice(0, 40).join(' | ') || '(none)'}\n` +
        'Whole-page search is intentionally NOT used (false positive on library/item/server names).\n' +
        'See companionServer/FriendlyName runbook: docs/select-player-runbook.md'
    );
  }

  // Click the cast target inside the picker — prefer role, then exact text.
  const candidates = [
    page.getByRole('menuitem', { name: nameRe }),
    page.getByRole('option', { name: nameRe }),
    page.getByText(name, { exact: true }),
  ];
  for (const loc of candidates) {
    try {
      const first = loc.first();
      if (await first.isVisible({ timeout: 3000 }).catch(() => false)) {
        log(`picker_click via ${await first.evaluate((el) => el.tagName).catch(() => '?')}`);
        return first;
      }
    } catch (_) {
      /* next */
    }
  }

  // Last resort: any exact-text node (still exact, not substring).
  const fallback = page.getByText(name, { exact: true }).first();
  if (await fallback.isVisible({ timeout: 2000 }).catch(() => false)) return fallback;

  await shot(page, 'fail_picker_row_not_clickable');
  fail(
    'picker_row_not_clickable',
    `${JSON.stringify(name)} appeared in picker diff but no clickable row was found.`
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
  const r = await httpGet(`${daemonBase(cfg)}/player/playback/stop?commandID=9901`, {}, 3000);
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

  const web = await httpGet(`${cfg.plexBase}/web/index.html`);
  if (web.status < 200 || web.status >= 400) {
    skip(`Plex Web unreachable at ${cfg.plexBase}/web/index.html HTTP ${web.status}`);
  }

  const idn = await pmsIdentity();
  log(
    `pms_identity status=${idn.status} friendlyName=${idn.friendlyName || '?'} machineId=${idn.machineId || '?'}`
  );

  // Prefs FriendlyName (identity XML often omits it)
  const prefs = await httpGet(`${cfg.plexBase}/:/prefs`, { 'X-Plex-Token': cfg.token });
  const prefName = (prefs.body.match(/id="FriendlyName"[^>]*value="([^"]*)"/) || [])[1] || '';
  log(`pms_friendlyName_pref=${prefName || '(blank)'}`);

  const ratingKey = await resolveRatingKey();
  const metaKey = `/library/metadata/${ratingKey}`;

  const baseTl = await pollDaemonTimeline(7000);
  const daemonUp = baseTl.includes('Timeline') || baseTl.includes('MediaContainer');
  if (!daemonUp) {
    log(
      `WARN daemon timeline not reachable at ${daemonBase(cfg)} — picker + companion still scored; playback assert will FAIL if still down`
    );
  } else {
    log(`daemon_ok ${daemonBase(cfg)}`);
    // Clear any leftover session so playing_samples are from THIS run.
    await httpGet(`${daemonBase(cfg)}/player/playback/stop?commandID=7001`, {}, 3000);
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

  await context.addCookies([
    {
      name: 'X-Plex-Token',
      value: cfg.token,
      url: cfg.plexBase,
    },
  ]);

  // Reinforce token before any Plex Web script runs. storageState alone was
  // observed as "Initialize server without token" + VolatileWebStorage miss.
  await context.addInitScript((tok) => {
    try {
      window.localStorage.setItem('myPlexAccessToken', tok);
      window.localStorage.setItem('myPlexAuthToken', tok);
    } catch (_) {
      /* ignore */
    }
  }, cfg.token);

  // HARD TRAP: context-level listener (page-level misses companion discovery).
  const tracker = attachDiscoveryTracker(context);

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

    log('waiting for Select User or shell...');
    const pickerUser = await dismissUserPicker(page, cfg.webUser);
    log(
      `user_gate phase=${pickerUser.phase || (pickerUser.shown ? 'picker' : 'none')} picked=${pickerUser.picked || '-'}`
    );
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
    const picker2 = await dismissUserPicker(page, cfg.webUser);
    if (picker2.shown && picker2.picked) log(`user_picker re-dismissed profile=${picker2.picked}`);
    if (picker2.shown && !picker2.picked) {
      await shot(page, 'fail_user_picker_after_details');
      fail('plex_home_user_picker_not_dismissed', 'Select User still showing after details navigation.');
    }
    log(`at ${page.url()}`);
    await shot(page, '01_details');

    // ── 3. Select Player — BEFORE snapshot, then open, then DIFF ────────────
    const ctl = await waitForSelectPlayerControl(page, 45000);
    if (ctl.kind === 'user_picker') {
      const again = await dismissUserPicker(page, cfg.webUser);
      if (!again.picked && again.shown) {
        await shot(page, 'fail_user_picker_before_cast');
        fail('plex_home_user_picker_not_dismissed', 'Select User reappeared before cast control.');
      }
    }

    // Capture body BEFORE opening picker (false-positive guard).
    // Wait until details chrome is actually painted — an empty BEFORE set
    // would make every line look "added" and defeat the whole-page FP guard.
    {
      const readyDeadline = Date.now() + 30000;
      let n = 0;
      while (Date.now() < readyDeadline) {
        const s = await bodyLineSet(page);
        n = s.size;
        if (n >= 8) break;
        await page.waitForTimeout(500);
      }
      if (n < 8) {
        await shot(page, 'fail_details_empty_before_picker');
        fail(
          'details_body_empty_before_picker',
          `Details page body had only ${n} lines before Select Player; cannot trust picker diff.`
        );
      }
    }
    const beforePicker = await bodyLineSet(page);
    log(`body_lines_before_picker=${beforePicker.size}`);
    // Reset discovery so we only score polls triggered by this open.
    tracker.resetDiscovery();

    let opened = null;
    if (ctl.kind === 'ok') {
      log(`select_player_control selector=${ctl.sel}`);
      await ctl.el.click({ timeout: 5000 });
      opened = ctl.sel;
    } else {
      // retry locate
      const again = await waitForSelectPlayerControl(page, 15000);
      if (again.kind === 'ok') {
        log(`select_player_control selector=${again.sel}`);
        await again.el.click({ timeout: 5000 });
        opened = again.sel;
      }
    }
    if (!opened) {
      await shot(page, 'fail_no_select_player_control');
      const body = await pageBodyText(page, 400);
      fail(
        'select_player_control_not_found',
        'Could not find Select Player control (a[aria-label="Select Player"]) on the details page. ' +
          `body_sample=${JSON.stringify(body.slice(0, 200))}`
      );
    }

    // Give the menu + companion fetch time to land.
    await page.waitForTimeout(4000);
    await shot(page, '02_picker_open');

    // Companion first (network), then picker contents (DOM diff).
    const companion = assertCompanionServer(tracker);

    const target = await assertMisterplexInPickerDiff(page, beforePicker);
    await target.click();
    log('selected_cast_target');
    await page.waitForTimeout(1000);
    await shot(page, '03_target_selected');

    // ── 4. Play ─────────────────────────────────────────────────────────────
    const played = await clickPlay(page);
    if (!played) {
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
      // Re-check once — daemon may have been flaky at start.
      const againTl = await pollDaemonTimeline(7100);
      if (!(againTl.includes('Timeline') || againTl.includes('MediaContainer'))) {
        await shot(page, 'fail_daemon_down_after_play');
        fail(
          'playback_did_not_start',
          `Play was clicked in Plex Web but companion at ${daemonBase(cfg)} is unreachable — cannot confirm playing state.`
        );
      }
    }

    const prog = await waitPlayingOnDaemon(cfg.playWaitSec);
    if (prog.playing < 2) {
      await shot(page, 'fail_not_playing');
      fail(
        'playback_did_not_start',
        `UI play clicked but daemon timeline never stayed in state=playing ` +
          `(playing_samples=${prog.playing} time_max_ms=${prog.maxT}). ` +
          `Picker contained ${cfg.castName}; companion=${(companion.hosts || []).join(',')}; ` +
          'failure is post-select playback.'
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
      `summary picker=ok companion=${(companion.matched || companion.hosts || []).join(',') || 'ok'} ` +
        `play=ok stop=ok cast=${cfg.castName} ratingKey=${ratingKey} time_max_ms=${prog.maxT} ` +
        `context_requests=${tracker.all.length}`
    );
    process.exitCode = EXIT_PASS;
  } catch (e) {
    await shot(page, 'fail_unhandled');
    fail('unhandled_error', redact(e.stack || e.message || String(e)));
  } finally {
    tracker.detach();
    await browser.close().catch(() => {});
  }
})().catch((e) => {
  console.error(`UNHANDLED: ${redact(e.message || e)}`);
  process.exit(EXIT_SKIP);
});
