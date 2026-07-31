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
const { spawnSync } = require('child_process');
const { loadConfig, daemonBase, redact, ROOT } = require('./conf');

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

/** Thrown instead of process.exit so try/finally teardown always runs. */
class FailError extends Error {
  constructor(reason, detail) {
    super(reason);
    this.name = 'FailError';
    this.reason = reason;
    this.detail = detail || '';
    this.exitCode = EXIT_FAIL;
  }
}

function fail(reason, detail) {
  console.error(`FAIL test_cast_picker_playwright: ${reason}`);
  if (detail) console.error(detail);
  throw new FailError(reason, detail);
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

/**
 * Resolve ratingKey + canonical item title from PMS.
 * Title is required later as a deterministic details-ready signal
 * (sidebar-only paint is NOT enough — parent fail_no_play_button.png).
 */
async function resolveItem() {
  let ratingKey = '';
  if (cfg.ratingKey) ratingKey = String(cfg.ratingKey).replace(/^\/library\/metadata\//, '');
  else if (cfg.plexKey) {
    const m = String(cfg.plexKey).match(/metadata\/(\d+)/);
    if (m) ratingKey = m[1];
  }

  const headers = {
    'X-Plex-Token': cfg.token,
    Accept: 'application/json',
  };

  if (ratingKey) {
    const meta = await httpGet(`${cfg.plexBase}/library/metadata/${ratingKey}`, headers);
    if (meta.status === 200) {
      try {
        const j = JSON.parse(meta.body);
        const m = (j.MediaContainer?.Metadata || [])[0];
        if (m && m.title) {
          log(`resolved ratingKey=${ratingKey} title=${m.title}`);
          return { ratingKey: String(ratingKey), title: String(m.title) };
        }
      } catch (_) {
        /* fall through to library search */
      }
    }
  }

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
  return { ratingKey: String(hit.ratingKey), title: String(hit.title || cfg.itemTitle) };
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
 *
 * HARD TRAP 2: picker may also list a stale ghost "MiSTerPlexTest" (no space).
 * Gate requires an EXACT line match for cfg.castName ("MiSTerPlex") and clicks
 * only the exact-text node — loose/substring hits must not satisfy the gate.
 */
async function assertMisterplexInPickerDiff(page, beforeSet) {
  const name = cfg.castName;
  const afterSet = await bodyLineSet(page);
  const added = addedLines(beforeSet, afterSet);
  log(`picker_added_line_count=${added.length}`);
  for (const line of added.slice(0, 40)) {
    log(`  picker+ ${line}`);
  }

  const nameRe = new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'i');
  const exactLines = added.filter((l) => nameRe.test(l));
  const hitExact = exactLines.length > 0;
  // Ghost / near-miss labels (e.g. "MiSTerPlexTest" from stale :13005 entry).
  const ghosts = added.filter(
    (l) =>
      !nameRe.test(l) &&
      new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i').test(l) &&
      !/tests|soak|studio|240p|480p|720p|1080p|metadata/i.test(l)
  );
  if (ghosts.length) log(`picker_ghost_labels=${ghosts.join(' | ')}`);

  log(`MISTERPLEX_IN_PICKER=${hitExact} hitExact=${hitExact} exact_lines=${exactLines.join('|') || '(none)'}`);

  if (!hitExact) {
    await shot(page, 'fail_picker_no_misterplex');
    fail(
      'picker_did_not_contain_MiSTerPlex',
      `Select Player opened but exact ${JSON.stringify(name)} was not in BEFORE/AFTER body diff.\n` +
        `Added lines (sample): ${added.slice(0, 40).join(' | ') || '(none)'}\n` +
        (ghosts.length
          ? `Ghost near-misses (NOT accepted): ${ghosts.join(' | ')}\n`
          : '') +
        'Whole-page / substring search is intentionally NOT used.\n' +
        'See companionServer/FriendlyName runbook: docs/select-player-runbook.md'
    );
  }

  // Click ONLY the exact cast name — never a ghost like "MiSTerPlexTest".
  const candidates = [
    { how: 'role=menuitem exact', loc: page.getByRole('menuitem', { name: nameRe }) },
    { how: 'role=option exact', loc: page.getByRole('option', { name: nameRe }) },
    { how: 'getByText exact', loc: page.getByText(name, { exact: true }) },
  ];
  for (const c of candidates) {
    try {
      const first = c.loc.first();
      if (await first.isVisible({ timeout: 3000 }).catch(() => false)) {
        const txt = ((await first.innerText().catch(() => '')) || '').trim();
        // Defend against role match that still grabbed a longer ghost label.
        if (txt && !nameRe.test(txt.split('\n')[0].trim()) && txt !== name) {
          log(`picker_click skip how=${c.how} text=${JSON.stringify(txt.slice(0, 40))}`);
          continue;
        }
        const tag = await first.evaluate((el) => el.tagName).catch(() => '?');
        log(`picker_click how=${c.how} tag=${tag} text=${JSON.stringify(txt.slice(0, 40) || name)}`);
        return first;
      }
    } catch (_) {
      /* next */
    }
  }

  await shot(page, 'fail_picker_row_not_clickable');
  fail(
    'picker_row_not_clickable',
    `Exact ${JSON.stringify(name)} was in picker diff but no exact clickable row was found.` +
      (ghosts.length ? ` Ghosts present: ${ghosts.join(' | ')}` : '')
  );
}

/** Ordered Play controls — log which matched (same discipline as Select Player). */
const PLAY_SELECTORS = [
  // Pre-play details (most common on /details)
  '[data-testid="preplay-play"]',
  '[data-qa="preplayPlayButton"]',
  'button[data-testid="preplay-play"]',
  // Aria (player chrome / details)
  'button[aria-label="Play"]',
  '[aria-label="Play"]',
  // Visible text fallbacks
  'button:has-text("Play")',
  '[role="button"]:has-text("Play")',
];

/**
 * Wait until item details have actually rendered — not just the shell/sidebar.
 * Parent RED: fail_no_play_button.png showed spinner-only content while
 * body_lines_before_picker=19 (sidebar). Line-count alone is insufficient.
 *
 * Deterministic signals (any path):
 *   1. item title text visible
 *   2. a Play control from PLAY_SELECTORS visible
 * Fail distinct: details_never_rendered (timeout) vs later play_button_not_found.
 */
async function waitForDetailsReady(page, itemTitle, maxMs = 90000) {
  const title = String(itemTitle || '').trim();
  const deadline = Date.now() + maxMs;
  let lastBody = '';
  let sawTitle = false;
  let playSel = null;

  while (Date.now() < deadline) {
    // Title — prefer exact, then substring (PMS titles often include year).
    if (title) {
      const exact = page.getByText(title, { exact: true }).first();
      if (await exact.isVisible().catch(() => false)) sawTitle = true;
      else {
        const loose = page.getByText(title, { exact: false }).first();
        if (await loose.isVisible().catch(() => false)) sawTitle = true;
        else {
          // cfg.itemTitle substring (e.g. "MiSTerPlex Test 240p" vs "... (2026)")
          const short = cfg.itemTitle || '';
          if (short && short !== title) {
            const s = page.getByText(short, { exact: false }).first();
            if (await s.isVisible().catch(() => false)) sawTitle = true;
          }
        }
      }
    }

    for (const sel of PLAY_SELECTORS) {
      try {
        const el = page.locator(sel).first();
        if (await el.isVisible().catch(() => false)) {
          playSel = sel;
          break;
        }
      } catch (_) {
        /* next */
      }
    }

    lastBody = await pageBodyText(page, 500);
    const spinnerOnly =
      /loading/i.test(lastBody) &&
      !sawTitle &&
      !playSel &&
      lastBody.split('\n').filter(Boolean).length < 12;

    if (sawTitle && playSel) {
      log(`details_ready title=1 play_selector=${playSel}`);
      return { ok: true, playSel, sawTitle: true };
    }
    // Title alone is enough to leave "never rendered"; Play may appear after cast select.
    if (sawTitle && !spinnerOnly) {
      // Prefer also seeing duration/metadata chrome common on preplay
      if (/play|video|audio|subtitle|duration|\d+\s*min|\d+:\d+/i.test(lastBody) || playSel) {
        log(`details_ready title=1 play_selector=${playSel || '(none-yet)'} body_hint=metadata`);
        return { ok: true, playSel, sawTitle: true };
      }
    }

    await page.waitForTimeout(400);
  }

  await shot(page, 'fail_details_never_rendered');
  fail(
    'details_never_rendered',
    `Item details did not finish rendering within ${maxMs}ms.\n` +
      `expected_title=${JSON.stringify(title)} sawTitle=${sawTitle} playSel=${playSel || '(none)'}\n` +
      `body_sample=${JSON.stringify(lastBody.slice(0, 240))}\n` +
      'This is a page-load race, not a missing Play selector — fix wait conditions, not product.'
  );
}

/**
 * Click Play using ordered stable selectors. Caller must have waited for
 * details_ready first. Returns matched selector string, or null if none visible
 * within per-selector auto-wait (no fixed sleep retry loops).
 */
async function clickPlay(page, preferSel) {
  const ordered = preferSel
    ? [preferSel, ...PLAY_SELECTORS.filter((s) => s !== preferSel)]
    : PLAY_SELECTORS.slice();
  for (const sel of ordered) {
    try {
      const el = page.locator(sel).first();
      // Playwright auto-wait: visible + stable, not a fixed sleep.
      await el.waitFor({ state: 'visible', timeout: 8000 });
      if (!(await el.isEnabled().catch(() => true))) {
        log(`play_button skip disabled selector=${sel}`);
        continue;
      }
      await el.click({ timeout: 5000 });
      log(`play_button selector=${sel}`);
      return sel;
    } catch (_) {
      /* next candidate */
    }
  }
  return null;
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

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/** Force companion stop — does not depend on browser still being alive. */
async function forceStopDaemon(tag = 'teardown') {
  for (let i = 0; i < 4; i++) {
    const r = await httpGet(
      `${daemonBase(cfg)}/player/playback/stop?commandID=${9800 + i}`,
      {},
      3000
    );
    log(`${tag}_stop_http i=${i} status=${r.status}`);
  }
}

/**
 * Device must be idle after the suite: not playing/paused with an active session.
 * Parent measured leftover Plex Web long-poll controllers issuing pause/stop
 * under concurrent CPU windows — browser close alone is not enough without
 * verifying the companion timeline is quiescent.
 */
async function verifyDaemonQuiescent(maxMs = 12000) {
  const deadline = Date.now() + maxMs;
  let lastXml = '';
  let lastState = '';
  let lastTime = '';
  while (Date.now() < deadline) {
    lastXml = await pollDaemonTimeline(9700 + (Date.now() % 50));
    lastState = xmlAttr(lastXml, 'state') || '';
    lastTime = xmlAttr(lastXml, 'time') || '';
    const dur = xmlAttr(lastXml, 'duration') || '0';
    // Accept stopped, or buffering/navigation with no active media duration.
    if (lastState === 'stopped') {
      return { ok: true, state: lastState, time: lastTime, xml: lastXml };
    }
    if (
      (lastState === 'buffering' || lastState === '') &&
      (dur === '0' || dur === '' || lastTime === '0')
    ) {
      // Confirm stability across a second sample (no controller re-starting).
      await sleep(800);
      const xml2 = await pollDaemonTimeline(9750);
      const s2 = xmlAttr(xml2, 'state') || '';
      const t2 = xmlAttr(xml2, 'time') || '';
      const d2 = xmlAttr(xml2, 'duration') || '0';
      if (s2 === 'playing' || s2 === 'paused') {
        lastState = s2;
        lastTime = t2;
        lastXml = xml2;
        continue;
      }
      if (s2 === 'stopped' || d2 === '0' || d2 === '' || t2 === '0') {
        return { ok: true, state: s2 || lastState, time: t2 || lastTime, xml: xml2 };
      }
    }
    // Still dirty — hammer stop again.
    if (lastState === 'playing' || lastState === 'paused') {
      await forceStopDaemon('teardown_retry');
    }
    await sleep(500);
  }
  return { ok: false, state: lastState, time: lastTime, xml: lastXml };
}

/**
 * Kill the browser controller hard: blank page (drops wait=1 timeline polls),
 * close page → context → browser. Must run even on failure paths.
 */
async function closeBrowserController(page, context, browser, tracker) {
  try {
    if (page && !page.isClosed()) {
      await page.goto('about:blank', { waitUntil: 'domcontentloaded', timeout: 5000 }).catch(() => {});
      await page.close({ runBeforeUnload: false }).catch(() => {});
    }
  } catch (_) {
    /* ignore */
  }
  try {
    if (tracker) tracker.detach();
  } catch (_) {
    /* ignore */
  }
  try {
    if (context) await context.close();
  } catch (_) {
    /* ignore */
  }
  try {
    if (browser) await browser.close();
  } catch (_) {
    /* ignore */
  }
  log('browser_controller_closed');
}

/**
 * Full teardown: stop media, destroy browser controller, assert quiescent.
 * Returns { ok, detail }. Caller must FAIL the run if ok=false after a pass path.
 */
async function hardTeardown(page, context, browser, tracker) {
  await forceStopDaemon('teardown');
  await closeBrowserController(page, context, browser, tracker);
  // Brief settle so any in-flight wait=1 from the closed browser dies.
  await sleep(1500);
  await forceStopDaemon('teardown_post_browser');
  const q = await verifyDaemonQuiescent(12000);
  if (q.ok) {
    log(`TEARDOWN_OK state=${q.state || 'stopped'} time=${q.time || '0'}`);
    return { ok: true, ...q };
  }
  log(`TEARDOWN_DIRTY state=${q.state || '?'} time=${q.time || '?'}`);
  return { ok: false, ...q };
}

function countPngs(dir) {
  try {
    if (!fs.existsSync(dir)) return 0;
    return fs.readdirSync(dir).filter((f) => /\.png$/i.test(f)).length;
  } catch (_) {
    return 0;
  }
}

function parentHdmiCaptureCmd(cfg) {
  const dir = cfg.hdmiCaptureDir;
  // Parent-owned MacroSilicon path. Suite never opens this device.
  // Warm-up: instrument discards first --warmup-skip frames; capture enough extras.
  const n = Math.max(40, cfg.hdmiWarmupSkip + 30);
  return (
    `mkdir -p ${JSON.stringify(dir)} && ` +
    `ffmpeg -y -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 ` +
    `-i ${cfg.hdmiVideoDev} -frames:v ${n} ${JSON.stringify(path.join(dir, 'f_%04d.png'))}`
  );
}

function parentHdmiScoreCmd(cfg) {
  const tool = path.join(ROOT, 'tools', 'hdmi_motion_instrument.py');
  return (
    `python3 ${JSON.stringify(tool)} ${JSON.stringify(cfg.hdmiCaptureDir)} ` +
    `--warmup-skip ${cfg.hdmiWarmupSkip} --json; echo "true rc=$?"`
  );
}

/**
 * Optional conf-gated HDMI motion stage.
 * - Never opens /dev/video0 (parent owns capture).
 * - Prints exact parent capture + score commands.
 * - Holds playback so parent can capture during E2E_HDMI_HOLD_SEC.
 * - If capture dir already has PNGs, runs the instrument and asserts:
 *     rc=0 MOTION_OK required
 *     rc=77 UNSCORED → hard FAIL (not inconclusive)
 *     rc=1 FREEZE / rc=2 COLOR_FAIL → hard FAIL
 */
async function optionalHdmiMotionStage() {
  if (!cfg.hdmiMotion) {
    log('HDMI_MOTION=off (set E2E_HDMI_MOTION=1 to enable parent-scored pixel gate)');
    return { enabled: false };
  }

  const capDir = cfg.hdmiCaptureDir;
  const captureCmd = parentHdmiCaptureCmd(cfg);
  const scoreCmd = parentHdmiScoreCmd(cfg);
  log('HDMI_MOTION=on');
  log(`HDMI_CAPTURE_DIR=${capDir}`);
  log(`PARENT_HDMI_CAPTURE_CMD=${captureCmd}`);
  log(`PARENT_HDMI_SCORE_CMD=${scoreCmd}`);
  log(
    `HDMI_HOLD_SEC=${cfg.hdmiHoldSec} — parent should run PARENT_HDMI_CAPTURE_CMD now while playback holds`
  );

  // Hold playing so parent can grab a burst. Suite does NOT touch the grabber.
  const holdMs = Math.max(0, cfg.hdmiHoldSec) * 1000;
  const holdEnd = Date.now() + holdMs;
  let cmd = 8500;
  while (Date.now() < holdEnd) {
    const xml = await pollDaemonTimeline(cmd++);
    log(`  hdmi_hold state=${xmlAttr(xml, 'state') || '?'} time=${xmlAttr(xml, 'time') || '?'}`);
    await sleep(1000);
  }

  const nPng = countPngs(capDir);
  log(`hdmi_capture_png_count=${nPng} dir=${capDir}`);
  if (nPng < 3) {
    fail(
      'hdmi_motion_no_frames',
      `E2E_HDMI_MOTION=1 but capture dir has ${nPng} PNGs (need ≥3).\n` +
        'Parent must run PARENT_HDMI_CAPTURE_CMD during HDMI_HOLD (suite never opens /dev/video0).\n' +
        `CAPTURE: ${captureCmd}\n` +
        `SCORE:   ${scoreCmd}`
    );
  }

  const tool = path.join(ROOT, 'tools', 'hdmi_motion_instrument.py');
  if (!fs.existsSync(tool)) {
    fail(
      'hdmi_motion_instrument_missing',
      `Missing ${tool}. Land tools/hdmi_motion_instrument.py on this tree before enabling E2E_HDMI_MOTION.`
    );
  }

  log(`hdmi_score spawning instrument on ${capDir}`);
  const res = spawnSync(
    'python3',
    [tool, capDir, '--warmup-skip', String(cfg.hdmiWarmupSkip), '--json'],
    { encoding: 'utf8', timeout: 300000 }
  );
  const out = `${res.stdout || ''}${res.stderr || ''}`;
  for (const line of out.split('\n').filter(Boolean).slice(-30)) {
    log(`  instrument: ${line.slice(0, 240)}`);
  }
  // Capture true rc directly (spawnSync status) — never through a pipe.
  const rc = typeof res.status === 'number' ? res.status : 99;
  log(`hdmi_instrument true rc=${rc}`);

  if (rc === 77) {
    fail(
      'hdmi_motion_unscored',
      'hdmi_motion_instrument.py returned rc=77 UNSCORED — treated as hard FAIL in this gate ' +
        '(soft-skip is never a pass). Re-capture with a longer burst / confirm TREK24 overlay.'
    );
  }
  if (rc === 1) {
    fail('hdmi_motion_freeze', `instrument FREEZE rc=1\n${out.slice(-500)}`);
  }
  if (rc === 2) {
    fail('hdmi_motion_color_fail', `instrument COLOR_FAIL rc=2\n${out.slice(-500)}`);
  }
  if (rc !== 0) {
    fail(
      'hdmi_motion_instrument_failed',
      `instrument unexpected rc=${rc}\n${out.slice(-500)}`
    );
  }
  log('HDMI_MOTION_OK instrument rc=0');
  return { enabled: true, rc: 0, pngs: nPng };
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

  const item = await resolveItem();
  const ratingKey = item.ratingKey;
  const itemTitle = item.title;
  const metaKey = `/library/metadata/${ratingKey}`;
  log(`item_title=${itemTitle}`);

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

  let suitePassed = false;
  let teardownResult = null;
  let bodyError = null;

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

    // Deterministic details-ready (title + metadata/Play) — NOT line-count/sleep.
    // Parent RED was spinner-only content with sidebar lines >= 8.
    const detailsReady = await waitForDetailsReady(page, itemTitle, Math.max(cfg.timeoutMs, 90000));
    await shot(page, '01_details');
    log(`details_ready_ok playSel=${detailsReady.playSel || '-'}`);

    // ── 3. Select Player — BEFORE snapshot, then open, then DIFF ────────────
    const ctl = await waitForSelectPlayerControl(page, 45000);
    if (ctl.kind === 'user_picker') {
      const again = await dismissUserPicker(page, cfg.webUser);
      if (!again.picked && again.shown) {
        await shot(page, 'fail_user_picker_before_cast');
        fail('plex_home_user_picker_not_dismissed', 'Select User reappeared before cast control.');
      }
    }

    // BEFORE snapshot only after details-ready so library/item titles are present
    // and excluded from the picker diff (false-positive guard).
    const beforePicker = await bodyLineSet(page);
    log(`body_lines_before_picker=${beforePicker.size}`);
    if (beforePicker.size < 8) {
      await shot(page, 'fail_details_empty_before_picker');
      fail(
        'details_body_empty_before_picker',
        `Details-ready passed but body had only ${beforePicker.size} lines; cannot trust picker diff.`
      );
    }
    // Reset discovery so we only score polls triggered by this open.
    tracker.resetDiscovery();

    let opened = null;
    if (ctl.kind === 'ok') {
      log(`select_player_control selector=${ctl.sel}`);
      await ctl.el.click({ timeout: 5000 });
      opened = ctl.sel;
    } else {
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
        'Could not find Select Player control (a[aria-label="Select Player"] / button[aria-label=...]) on the details page. ' +
          `body_sample=${JSON.stringify(body.slice(0, 200))}`
      );
    }

    // Wait for picker UI + discovery network — prefer menu/listbox over fixed sleep.
    {
      const menu = page.locator('[role="menu"], [role="listbox"], [role="dialog"]').first();
      try {
        await menu.waitFor({ state: 'visible', timeout: 10000 });
        log('picker_surface visible');
      } catch (_) {
        log('picker_surface not role-labelled — waiting for discovery traffic');
      }
      const discDeadline = Date.now() + 12000;
      while (Date.now() < discDeadline && tracker.discovery.length === 0) {
        await page.waitForTimeout(200);
      }
      // Small settle so added body lines include player rows after fetch.
      if (tracker.discovery.length) await page.waitForTimeout(800);
      else await page.waitForTimeout(2500);
    }
    await shot(page, '02_picker_open');

    // Companion first (network), then picker contents (DOM diff).
    const companion = assertCompanionServer(tracker);

    const target = await assertMisterplexInPickerDiff(page, beforePicker);
    const clickedText = ((await target.innerText().catch(() => '')) || '').trim().split('\n')[0].trim();
    const exactNameRe = new RegExp(
      `^${cfg.castName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`,
      'i'
    );
    if (clickedText && !exactNameRe.test(clickedText) && clickedText !== cfg.castName) {
      await shot(page, 'fail_picker_clicked_ghost');
      fail(
        'picker_clicked_non_exact_target',
        `Refusing to click ghost/near-miss label ${JSON.stringify(clickedText)}; want exact ${JSON.stringify(cfg.castName)}`
      );
    }
    await target.click();
    log(`selected_cast_target exact=${cfg.castName} clicked_text=${JSON.stringify(clickedText || cfg.castName)}`);
    await shot(page, '03_target_selected');

    // ── 4. Play — re-confirm details still ready after cast target change ───
    const afterCast = await waitForDetailsReady(page, itemTitle, 60000);
    const played = await clickPlay(page, afterCast.playSel || detailsReady.playSel);
    if (!played) {
      await shot(page, 'fail_no_play_button');
      const body = await pageBodyText(page, 400);
      // Distinguish "page still loading" from "loaded but no Play control".
      const stillLoading =
        !afterCast.sawTitle ||
        (/loading/i.test(body) && !/play/i.test(body)) ||
        body.split('\n').filter(Boolean).length < 12;
      if (stillLoading) {
        fail(
          'details_never_rendered',
          'After selecting MiSTerPlex, item details were not ready for Play.\n' +
            `body_sample=${JSON.stringify(body.slice(0, 240))}`
        );
      }
      fail(
        'play_button_not_found',
        'Details rendered and MiSTerPlex was selected, but no Play control matched ' +
          `PLAY_SELECTORS=[${PLAY_SELECTORS.join(', ')}]. body_sample=${JSON.stringify(body.slice(0, 200))}`
      );
    }
    log(`play_clicked selector=${played}`);
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

    // ── 4b. Optional HDMI motion (parent capture; suite never opens video0) ─
    const hdmi = await optionalHdmiMotionStage();

    // ── 5. Pause (best-effort) + Stop via UI, then hard teardown ────────────
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
    await page.waitForTimeout(800);
    const afterStop = await pollDaemonTimeline(9002);
    log(`after_stop state=${xmlAttr(afterStop, 'state') || '?'}`);
    await shot(page, '05_stopped');

    // Mark logical pass before teardown — teardown failure must still RED the run.
    suitePassed = true;
    log(
      `suite_body_ok picker=ok companion=${(companion.matched || companion.hosts || []).join(',') || 'ok'} ` +
        `play=ok hdmi=${hdmi.enabled ? 'ok' : 'off'} stop=ok cast=${cfg.castName} ` +
        `ratingKey=${ratingKey} time_max_ms=${prog.maxT} context_requests=${tracker.all.length}`
    );
  } catch (e) {
    suitePassed = false;
    if (e instanceof FailError) {
      bodyError = e;
    } else {
      await shot(page, 'fail_unhandled').catch(() => {});
      console.error(`FAIL test_cast_picker_playwright: unhandled_error`);
      console.error(redact(e.stack || e.message || String(e)));
      bodyError = new FailError('unhandled_error', redact(e.stack || e.message || String(e)));
    }
  } finally {
    teardownResult = await hardTeardown(page, context, browser, tracker).catch((te) => ({
      ok: false,
      state: 'teardown_error',
      err: te.message,
    }));
  }

  if (bodyError) {
    // Body already printed FAIL lines via fail() / unhandled path.
    process.exit(bodyError.exitCode || EXIT_FAIL);
  }

  if (suitePassed && teardownResult && !teardownResult.ok) {
    console.error('FAIL test_cast_picker_playwright: teardown_device_not_quiescent');
    console.error(
      'Suite body passed but device/controller was left dirty after teardown.\n' +
        `state=${teardownResult.state || '?'} time=${teardownResult.time || '?'} ` +
        `err=${teardownResult.err || ''}\n` +
        'Plex Web must not keep long-polling /player/timeline/poll or issuing pause/stop ' +
        'after the suite exits (corrupts concurrent CPU/soak measurements).'
    );
    process.exit(EXIT_FAIL);
  }
  if (suitePassed && teardownResult && teardownResult.ok) {
    log('CAST_PICKER_E2E_RESULT=PASS');
    log(
      `summary picker=ok play=ok stop=ok teardown=ok cast=${cfg.castName} ratingKey=${ratingKey}`
    );
    process.exitCode = EXIT_PASS;
    return;
  }
  process.exit(EXIT_FAIL);
})().catch((e) => {
  console.error(`UNHANDLED: ${redact(e.message || e)}`);
  try {
    http
      .get(
        `${daemonBase(cfg)}/player/playback/stop?commandID=9799`,
        { timeout: 2000 },
        (res) => res.resume()
      )
      .on('error', () => {});
  } catch (_) {
    /* ignore */
  }
  process.exit(EXIT_SKIP);
});
