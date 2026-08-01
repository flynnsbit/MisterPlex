#!/usr/bin/env node
/**
 * test_cast_picker_playwright.js
 *
 * Playwright drives real Plex Web against a LOCAL PMS and verifies MiSTerPlex
 * end-to-end as a cast target:
 *   1. Sign in (token injection) + dismiss Plex Home "Select User"
 *   2. Open tier item (E2E_TIER=240p→RK3 / 480p→RK8 soak); parent applies DECODE conf
 *   3. Open Select Player; assert MiSTerPlex via BEFORE/AFTER body-text DIFF
 *      (whole-page regex for "MiSTerPlex" is a FALSE POSITIVE — library/item/
 *      server names all contain it)
 *   4. Assert WHICH companion server Web polled (/clients + /neighborhood/devices)
 *      via context.on('request') — page.on('request') captures 0 of these
 *   5. Select exact MiSTerPlex (reject ghost MiSTerPlexTest), play, timeline
 *   6. Optional transitions (pause/resume, seek, stop+recast, play→idle→play)
 *   7. Optional HDMI motion (parent captures /dev/video0; suite scores)
 *   8. Hard teardown: close OUR browser controller only (not global quiescence)
 *
 * Exit codes:
 *   0  PASS
 *   1  FAIL — picker / companion / playback / daemon unreachable when required
 *   2  UNVERIFIED — PLEX_BASE set but PMS unreachable/unusable (never green; w-lint style)
 *  77  SKIP-NOT-PASS — missing env/deps/chromium (never a green gate)
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
const { loadConfig, daemonBase, redact, ROOT, parentConfCommands, normalizeDecode } = require('./conf');
const {
  discoverRealTitle,
  isFixtureMeta,
  isBankGeometry,
  mediaInfo,
} = require('./discover_real');
const {
  captureLedger,
  assertLedgerWindow,
  assertPidUnchanged,
  formatSnap,
} = require('./ledger');
const { createRunCorrelation } = require('./run_correlate');
const { readUiPlayerTimeline, assertUiDaemonTimeline } = require('./ui_timeline');
const { createTimelineSeries } = require('./timeline_series');
const {
  analyzeCounterGaps,
  nsFromInstrumentJson,
  assertGlassLoss,
} = require('./glass_counter_loss');
const { emitGlassExpect } = require('./glass_expect');
const { assertDeviceIdleP4 } = require('./device_idle');

const EXIT_PASS = 0;
const EXIT_FAIL = 1;
/** Configured but cannot verify claim (PMS down) — never PASS (match CORE_IDENTITY_UNVERIFIED). */
const EXIT_UNVERIFIED = 2;
const EXIT_SKIP = 77;

const cfg = loadConfig();

/** Per-suite join key → daemon e2e_mark / origin lines. No lipsync scoring. */
const runCorr = createRunCorrelation({
  misterHost: cfg.misterHost || process.env.MISTER_HOST || '127.0.0.1',
  misterPort: cfg.misterPort || process.env.MISTER_PORT || 3005,
  outDir: cfg.outDir,
  log,
});

/** Wallclock ↔ Plex position series for parent HDMI three-way join. */
const tlSeries = createTimelineSeries({
  outDir: cfg.outDir,
  runId: runCorr.runId,
  log,
});

/** Baseline misterplexd process identity (self-reported via telemetry — not pidof). */
let baselineDaemonPid = -1;
let baselineDaemonExe = '';

async function captureAndAssertPid(tag, { hardFail = true } = {}) {
  const snap = await captureLedger(cfg);
  const r = assertPidUnchanged(baselineDaemonPid, snap, tag, {
    baselineExe: baselineDaemonExe,
  });
  if (baselineDaemonPid < 0 && snap && snap.pid > 0) {
    baselineDaemonPid = snap.pid;
    baselineDaemonExe = snap.exe || '';
    log(
      `DAEMON_PID_BASELINE pid=${baselineDaemonPid} exe=${baselineDaemonExe || 'NA'} ` +
        `tag=${tag} src=${snap.source} ` +
        `(identity=telemetry getpid+readlink/proc/self/exe — NOT host pidof/cmdline)`
    );
  } else if (baselineDaemonPid > 0 && !baselineDaemonExe && snap && snap.exe) {
    baselineDaemonExe = snap.exe;
  }
  if (!r.ok) {
    if (hardFail) {
      fail(r.reason || 'daemon_pid_changed', r.detail || '');
    }
    return { ok: false, ...r, snap };
  }
  if (r.softSkip) {
    log(`DAEMON_PID_SOFT_SKIP tag=${tag} ${r.detail}`);
  } else if (snap && snap.pid > 0) {
    log(
      `DAEMON_PID_OK tag=${tag} pid=${snap.pid} exe=${(snap.exe || baselineDaemonExe || '').replace(/^.*\//, '')}`
    );
  }
  return { ok: true, ...r, snap };
}

function log(...a) {
  console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : x)));
}

function skip(reason) {
  console.error(`SKIP-NOT-PASS test_cast_picker_playwright: ${reason}`);
  console.error('CAST_PICKER_E2E_RESULT=SKIP-NOT-PASS');
  process.exit(EXIT_SKIP);
}

/**
 * Configured target cannot be verified (e.g. PMS unreachable).
 * Never PASS. Distinct from FAIL (assertion disproved) and SKIP (deps missing).
 */
function unresolved(reason, detail) {
  console.error(`UNVERIFIED test_cast_picker_playwright: ${reason}`);
  if (detail) console.error(detail);
  console.error('CAST_PICKER_E2E_RESULT=UNVERIFIED');
  const err = new FailError(reason, detail || '');
  err.exitCode = EXIT_UNVERIFIED;
  err.unverified = true;
  throw err;
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
  console.error('CAST_PICKER_E2E_RESULT=FAIL');
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
/** Best-effort friendlyName for a polled companion host (sort-order diagnostics). */
async function probeHostFriendlyName(hostKey) {
  if (!hostKey || hostKey === '127.0.0.1' || hostKey === 'localhost') {
    return { host: hostKey, friendlyName: '(loopback)', status: 0 };
  }
  const url = `http://${hostKey}:32400/identity`;
  const r = await httpGet(url, {}, 2500);
  const fn =
    (r.body && (r.body.match(/friendlyName="([^"]*)"/) || [])[1]) ||
    (r.body && (r.body.match(/mediaServerFriendlyName="([^"]*)"/) || [])[1]) ||
    '';
  return { host: hostKey, friendlyName: fn || '(unknown)', status: r.status };
}

async function assertCompanionServer(tracker) {
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

  // Always probe friendlyNames of polled hosts so sort-order is greppable.
  const probes = [];
  for (const k of uniqueKeys.slice(0, 8)) {
    probes.push(await probeHostFriendlyName(k));
  }
  const sortedByName = [...probes].sort((a, b) =>
    String(a.friendlyName).toLowerCase().localeCompare(String(b.friendlyName).toLowerCase())
  );
  for (const p of probes) {
    log(
      `  companion_host_identity host=${p.host} friendlyName=${JSON.stringify(p.friendlyName)} ` +
        `http=${p.status}`
    );
  }
  if (sortedByName.length) {
    log(
      `COMPANION_FRIENDLYNAME_SORT_HINT first_would_win=${JSON.stringify(sortedByName[0].friendlyName)} ` +
        `order=${sortedByName.map((p) => p.friendlyName).join(' < ')}`
    );
  }

  const hit = uniqueKeys.filter((k) => expected.has(k));
  if (hit.length === 0) {
    fail(
      'wrong_companion_server',
      'Plex Web polled a companionServer that is NOT the PLEX_BASE under test.\n' +
        `  polled_norm=${uniqueKeys.join(',')}\n` +
        `  expected_norm=${[...expected].join(',')}\n` +
        `  polled_friendlyNames=${probes.map((p) => `${p.host}=${p.friendlyName}`).join('; ')}\n` +
        'ROOT CAUSE CLASS: _pickCompanionServer takes the FIRST owned, private, ' +
        'connected, non-shared server sorted by lowercased friendlyName.\n' +
        'Lab fix was renaming local PMS to "MiSTerPlex Studio" so it sorts before ' +
        '"node-worker1". ANY new owned server sorting earlier silently breaks casting.\n' +
        'Action: list owned servers by friendlyName (case-insensitive), rename/remove ' +
        'the one that sorts first, or point PLEX_BASE at the winner.\n' +
        'Do NOT encode another household server IP into CI. plex.tv provides=player is ' +
        'neither necessary nor sufficient.\n' +
        'See docs/select-player-runbook.md.'
    );
  }

  log(`COMPANION_ASSERT=PASS matched=${hit.join(',')} polled=${uniqueKeys.join(',')}`);
  log(
    'COMPANION_SORT_FRAGILITY=active rule=first_owned_private_connected_by_lowercased_friendlyName ' +
      'lab_anchor_friendlyName=MiSTerPlex Studio — new owned server sorting earlier → silent cast break'
  );
  return { skipped: false, hosts: uniqueKeys, matched: hit, urls, probes };
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
      // Fire-and-forget mark — join UI play to daemon origin window (not lipsync).
      runCorr
        .mark('play_issued', { selector: sel })
        .then(() => runCorr.joinTelemetry('play_issued'))
        .catch(() => {});
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
  return false;
}

/**
 * Seek via UI scrubber click at fraction of bar width (0..1).
 * Returns how=selector or null if no bar found.
 */
async function uiSeekFraction(page, fraction) {
  const frac = Math.min(0.95, Math.max(0.02, fraction));
  const sels = [
    '[data-testid="seekBar"]',
    '[class*="SeekBar-bar"]',
    '[class*="SeekBar"]',
    '[role="slider"]',
    'input[type="range"]',
  ];
  for (const sel of sels) {
    try {
      const el = page.locator(sel).first();
      if (!(await el.isVisible({ timeout: 1500 }).catch(() => false))) continue;
      const box = await el.boundingBox();
      if (!box || box.width < 8) continue;
      const x = box.x + box.width * frac;
      const y = box.y + box.height / 2;
      await page.mouse.click(x, y);
      log(`ui_seek selector=${sel} frac=${frac.toFixed(3)} x=${x.toFixed(0)}`);
      return sel;
    } catch (_) {
      /* next */
    }
  }
  return null;
}

/**
 * UI clock vs companion timeline. Hard fail when unreadable if required.
 * E2E_REQUIRE_UI_TIMELINE=1 default.
 */
async function assertUiMatchesDaemon(page, tag, opts = {}) {
  const rawReq = process.env.E2E_REQUIRE_UI_TIMELINE;
  const requireUi =
    rawReq === undefined || rawReq === ''
      ? true
      : /^(1|true|yes|on)$/i.test(String(rawReq));
  // Hover player chrome so time labels render.
  try {
    await page.mouse.move(400, 400);
    await page.mouse.move(420, 420);
    await sleep(200);
  } catch (_) {
    /* ignore */
  }
  const ui = await readUiPlayerTimeline(page);
  const xml = await pollDaemonTimeline(nextSuiteCmd());
  const daemon = {
    state: xmlAttr(xml, 'state') || '',
    time: parseInt(xmlAttr(xml, 'time') || '-1', 10),
    duration: parseInt(xmlAttr(xml, 'duration') || '0', 10),
  };
  const r = assertUiDaemonTimeline(ui, daemon, tag, {
    maxSkewMs: parseInt(process.env.E2E_UI_TIMELINE_SKEW_MS || '2500', 10),
    maxPctPoints: parseFloat(process.env.E2E_UI_TIMELINE_PCT_PP || '3'),
  });
  if (r.metrics) {
    const m = r.metrics;
    log(
      `UI_DAEMON_TIMELINE tag=${tag} ok=${r.ok ? 1 : 0} ` +
        `ui_ms=${m.ui_ms} daemon_ms=${m.daemon_ms} skew_ms=${m.skew_ms} ` +
        `ui_pct=${m.ui_pct != null ? m.ui_pct.toFixed(2) : 'NA'} ` +
        `daemon_pct=${m.daemon_pct != null ? m.daemon_pct.toFixed(2) : 'NA'} ` +
        `pct_delta=${m.pct_delta != null ? m.pct_delta.toFixed(2) : 'NA'} ` +
        `ui_src=${m.ui_source} ui_raw=${JSON.stringify(m.ui_raw)} daemon_state=${m.daemon_state}`
    );
    tlSeries.emit({
      tag,
      source: 'ui_and_daemon',
      plex_time_ms: m.daemon_ms,
      plex_duration_ms: m.daemon_dur_ms,
      state: m.daemon_state,
      ui_time_ms: m.ui_ms,
      ui_duration_ms: m.ui_dur_ms,
      skew_ms: m.skew_ms,
      ui_raw: m.ui_raw,
    });
  } else {
    log(
      `UI_DAEMON_TIMELINE tag=${tag} ok=0 reason=${r.reason} ui_src=${ui.source} ` +
        `ui_raw=${JSON.stringify(ui.raw)} daemon_t=${daemon.time}`
    );
    tlSeries.emit({
      tag,
      source: 'ui_read_fail',
      plex_time_ms: daemon.time >= 0 ? daemon.time : null,
      plex_duration_ms: daemon.duration > 0 ? daemon.duration : null,
      state: daemon.state,
      ui_raw: ui.raw,
      extra: { reason: r.reason || 'unknown' },
    });
  }
  if (!r.ok) {
    if (r.reason === 'ui_timeline_unreadable' && !requireUi) {
      log(
        `UI_TIMELINE_SOFT_SKIP tag=${tag} ${r.detail} — E2E_REQUIRE_UI_TIMELINE=0 (NOT a pass of truthfulness)`
      );
      return { ok: true, softSkip: true, ...r };
    }
    return r;
  }
  return r;
}

async function waitPlayingOnDaemon(seconds) {
  const deadline = Date.now() + seconds * 1000;
  let last = '';
  let playing = 0;
  let advance = 0;
  let prev = -1;
  let maxT = 0;
  let buffering = 0;
  let i = 0;
  while (Date.now() < deadline) {
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    last = xml;
    const state = xmlAttr(xml, 'state');
    const t = parseInt(xmlAttr(xml, 'time') || '-1', 10);
    const dur = parseInt(xmlAttr(xml, 'duration') || '0', 10);
    const w = tlSeries.wallNow();
    log(`  timeline state=${state || '?'} time=${xmlAttr(xml, 'time') || '?'} wall_ms=${w.ms}`);
    tlSeries.emit({
      tag: `wait_playing[${i++}]`,
      source: 'daemon_timeline',
      plex_time_ms: t >= 0 ? t : null,
      plex_duration_ms: dur > 0 ? dur : null,
      state: state || '',
    });
    if (state === 'playing') {
      playing++;
      if (t > prev && prev >= 0) advance++;
      if (t > maxT) maxT = t;
    } else if (state === 'buffering') {
      buffering++;
    }
    if (t >= 0) prev = t;
    await new Promise((r) => setTimeout(r, 1000));
  }
  return { playing, advance, maxT, last, buffering };
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/** Suite-owned commandID namespace — avoid 9800s used by long-lived user tabs. */
const SUITE_CMD_BASE = 41000 + (process.pid % 500) * 20;
let suiteCmdSeq = 0;
function nextSuiteCmd() {
  return SUITE_CMD_BASE + (suiteCmdSeq++ % 500);
}

/** Force companion stop — does not depend on browser still being alive. */
async function forceStopDaemon(tag = 'teardown') {
  let anyOk = false;
  for (let i = 0; i < 3; i++) {
    const cid = nextSuiteCmd();
    const r = await httpGet(
      `${daemonBase(cfg)}/player/playback/stop?commandID=${cid}`,
      {},
      3000
    );
    log(`${tag}_stop_http i=${i} cmd=${cid} status=${r.status}`);
    if (r.status === 200) anyOk = true;
  }
  return anyOk;
}

/** Best-effort unsubscribe so companion drops our timeline waiter slots. */
async function unsubscribeDaemon(tag = 'teardown') {
  const cid = nextSuiteCmd();
  const r = await httpGet(
    `${daemonBase(cfg)}/player/timeline/unsubscribe?commandID=${cid}`,
    {},
    3000
  );
  log(`${tag}_unsubscribe cmd=${cid} status=${r.status}`);
  return r.status === 200;
}

async function companionPlayback(pathAndQuery, tag = 'cmd') {
  const cid = nextSuiteCmd();
  const sep = pathAndQuery.includes('?') ? '&' : '?';
  const url = `${daemonBase(cfg)}/player/playback/${pathAndQuery}${sep}commandID=${cid}`;
  const r = await httpGet(url, {}, 4000);
  log(`${tag}_http path=${pathAndQuery} cmd=${cid} status=${r.status}`);
  return r;
}

/**
 * Teardown verifies OUR Playwright controller is gone — not global idle.
 *
 * Lab has a permanent user Plex Web tab that long-polls and can issue stop/pause.
 * Asserting device-wide controller-free / non-playing is a latent flake.
 *
 * PASS criteria:
 *   - browser page/context/browser closed successfully
 *   - suite issued stop + unsubscribe (best-effort HTTP)
 * FAIL criteria:
 *   - browser close threw / browser still connected
 * Soft note (not FAIL): timeline still playing/paused after our stop — may be
 * the user's controller or a race; we log TEARDOWN_NOTE_external_activity.
 */
async function verifyOurControllerGone(browserClosed, stopOk) {
  if (!browserClosed) {
    return {
      ok: false,
      reason: 'browser_not_closed',
      state: '',
      time: '',
    };
  }
  // One timeline sample for logging only — do not require global stopped.
  const xml = await pollDaemonTimeline(nextSuiteCmd());
  const state = xmlAttr(xml, 'state') || '';
  const time = xmlAttr(xml, 'time') || '';
  if (state === 'playing' || state === 'paused') {
    log(
      `TEARDOWN_NOTE_external_activity state=${state} time=${time} ` +
        '(another controller may own the daemon — suite browser is closed)'
    );
  }
  if (!stopOk) {
    log('TEARDOWN_NOTE_stop_http_not_200 (daemon may be down; browser still closed)');
  }
  return { ok: true, reason: 'controller_closed', state, time, xml, stopOk };
}

/**
 * Kill the browser controller hard: blank page (drops wait=1 timeline polls),
 * close page → context → browser. Must run even on failure paths.
 */
async function closeBrowserController(page, context, browser, tracker) {
  let closed = true;
  try {
    if (page && !page.isClosed()) {
      await page.goto('about:blank', { waitUntil: 'domcontentloaded', timeout: 5000 }).catch(() => {});
      await page.close({ runBeforeUnload: false }).catch(() => {});
    }
  } catch (e) {
    closed = false;
    log(`browser_page_close_err ${e.message}`);
  }
  try {
    if (tracker) tracker.detach();
  } catch (_) {
    /* ignore */
  }
  try {
    if (context) await context.close();
  } catch (e) {
    closed = false;
    log(`browser_context_close_err ${e.message}`);
  }
  try {
    if (browser) {
      if (browser.isConnected && browser.isConnected()) {
        await browser.close();
      } else {
        await browser.close().catch(() => {});
      }
      if (browser.isConnected && browser.isConnected()) {
        closed = false;
        log('browser_still_connected_after_close');
      }
    }
  } catch (e) {
    closed = false;
    log(`browser_close_err ${e.message}`);
  }
  log(`browser_controller_closed ok=${closed ? 1 : 0}`);
  return closed;
}

/**
 * Full teardown: stop media, destroy OUR browser controller, assert controller gone.
 * Does NOT require global device idle (user Plex tab may remain).
 */
async function hardTeardown(page, context, browser, tracker) {
  await unsubscribeDaemon('teardown').catch(() => false);
  const stopOk = await forceStopDaemon('teardown').catch(() => false);
  const browserClosed = await closeBrowserController(page, context, browser, tracker);
  // Brief settle so any in-flight wait=1 from OUR closed browser dies.
  await sleep(800);
  await unsubscribeDaemon('teardown_post_browser').catch(() => false);
  await forceStopDaemon('teardown_post_browser').catch(() => false);
  const q = await verifyOurControllerGone(browserClosed, stopOk);
  if (q.ok) {
    log(
      `TEARDOWN_OK controller=closed browser=closed stop_ok=${stopOk ? 1 : 0} ` +
        `state=${q.state || 'n/a'} time=${q.time || 'n/a'}`
    );
    return { ok: true, ...q };
  }
  log(`TEARDOWN_DIRTY reason=${q.reason || '?'} state=${q.state || '?'} time=${q.time || '?'}`);
  return { ok: false, ...q };
}

/** Emit parent-only conf ops and assert daemon tier probe when required. */
function assertDaemonTier(tier) {
  const pc = parentConfCommands(tier, cfg.misterHost);
  log(`TIER=${tier.name} expect_decode=${tier.expectDecode} ratingKey=${tier.ratingKey}`);
  for (const line of pc.applyText.split('\n')) log(line);
  log(`PARENT_TIER_EXPORT=${pc.probeExport}`);
  const reported = normalizeDecode(tier.daemonDecodeReported || '');
  const expect = normalizeDecode(tier.expectDecode);
  if (!reported) {
    if (tier.requireDaemonTier) {
      fail(
        'daemon_tier_unprobed',
        `E2E_TIER=${tier.name} requires parent to apply conf and export E2E_DAEMON_DECODE=${expect}.\n` +
          'Suite does not edit device conf or read daemon logs over SSH.\n' +
          pc.applyText
      );
    }
    log(
      `DAEMON_TIER_UNPROBED tier=${tier.name} expect=${expect} ` +
        '(set E2E_DAEMON_DECODE to assert; E2E_REQUIRE_DAEMON_TIER=1 to hard-require)'
    );
    return { ok: true, probed: false, expect };
  }
  if (reported !== expect) {
    fail(
      'daemon_tier_mismatch',
      `Daemon decode probe ${JSON.stringify(reported)} != tier expect ${JSON.stringify(expect)}.\n` +
        `Parent conf is wrong for E2E_TIER=${tier.name} — apply conf then re-export E2E_DAEMON_DECODE.\n` +
        pc.applyText
    );
  }
  log(`DAEMON_TIER_OK tier=${tier.name} decode=${reported}`);
  return { ok: true, probed: true, expect, reported };
}

/**
 * Resolve PMS item for a tier (ratingKey preferred).
 * E2E_CONTENT=real: discover non-fixture non-bank geometry; never silent fixture fallback.
 */
async function resolveItemForTier(tier) {
  const headers = {
    'X-Plex-Token': cfg.token,
    Accept: 'application/json',
  };

  if (cfg.isRealContent) {
    // Explicit RK via env only (tier default RK3/RK6 must not silently select fixtures).
    let ratingKey = String(process.env.PLEX_RATING_KEY || process.env.PLEX_KEY || '')
      .replace(/^\/library\/metadata\//, '');
    if (ratingKey) {
      const meta = await httpGet(`${cfg.plexBase}/library/metadata/${ratingKey}`, headers);
      if (meta.status !== 200) {
        fail('real_content_rating_key_unreachable', `HTTP ${meta.status} metadata/${ratingKey}`);
      }
      let m;
      try {
        m = (JSON.parse(meta.body).MediaContainer?.Metadata || [])[0];
      } catch (_) {
        fail('real_content_metadata_bad_json', ratingKey);
      }
      if (!m) fail('real_content_metadata_empty', ratingKey);
      const sectionTitle = m.librarySectionTitle || '';
      if (isFixtureMeta(m, sectionTitle)) {
        fail(
          'real_content_is_fixture',
          `ratingKey=${ratingKey} title=${JSON.stringify(m.title)} is a lab fixture — no fallback`
        );
      }
      const mi = mediaInfo(m);
      const allowBank = /^(1|true|yes|on)$/i.test(String(process.env.E2E_REAL_ALLOW_BANK_GEOM || ''));
      if (!allowBank && isBankGeometry(mi.width, mi.height)) {
        fail(
          'real_content_bank_geometry',
          `library_media=${mi.width}x${mi.height} is bank-sized; P7 needs non-bank geometry`
        );
      }
      log(
        `resolved REAL ratingKey=${ratingKey} title=${m.title} library_media=${mi.width}x${mi.height}`
      );
      return {
        ratingKey: String(ratingKey),
        title: String(m.title || ''),
        tier: tier.name,
        ...mi,
      };
    }
    // Runtime discovery — no fixture / bank fallback.
    log('CONTENT=real discover_real (no explicit PLEX_RATING_KEY)');
    const disc = await discoverRealTitle(cfg, { expectDecode: tier.expectDecode });
    if (!disc.ok) {
      fail(disc.reason || 'real_content_library_empty', disc.detail || '');
    }
    log(
      `discover_ok rk=${disc.item.ratingKey} title=${JSON.stringify(disc.item.title)} ` +
        `library_media=${disc.item.width}x${disc.item.height} score=${disc.item.score}`
    );
    return { ...disc.item, tier: tier.name };
  }

  let ratingKey = String(tier.ratingKey || '').replace(/^\/library\/metadata\//, '');
  if (ratingKey) {
    const meta = await httpGet(`${cfg.plexBase}/library/metadata/${ratingKey}`, headers);
    if (meta.status === 200) {
      try {
        const j = JSON.parse(meta.body);
        const m = (j.MediaContainer?.Metadata || [])[0];
        if (m && m.title) {
          log(`resolved tier=${tier.name} ratingKey=${ratingKey} title=${m.title}`);
          return { ratingKey: String(ratingKey), title: String(m.title), tier: tier.name };
        }
      } catch (_) {
        /* fall through */
      }
    }
  }
  // Fall back to shared resolveItem() path by temporarily setting cfg fields.
  const prevKey = cfg.ratingKey;
  const prevTitle = cfg.itemTitle;
  cfg.ratingKey = ratingKey || tier.ratingKey;
  cfg.itemTitle = tier.itemTitle;
  try {
    const item = await resolveItem();
    return { ...item, tier: tier.name };
  } finally {
    cfg.ratingKey = prevKey;
    cfg.itemTitle = prevTitle;
  }
}



async function probeResources() {
  const r = await httpGet(`${daemonBase(cfg)}/resources`, {}, 4000);
  return r.status || 0;
}

/** P4 STOPPED unregressed — device idle after suite stop (not UI-only). */
async function assertP4DeviceIdle(tag, timelineSamples) {
  const samples =
    timelineSamples ||
    (await sampleTimeline(6, 350, `${tag}_p4`));
  const tele = await captureLedger(cfg);
  const resSt = await probeResources();
  const r = assertDeviceIdleP4(samples, tele, {
    tag,
    resourcesStatus: resSt,
  });
  if (!r.ok) {
    fail(r.reason || 'p4_idle_fail', r.detail || '');
  }
  log(
    `P4_IDLE_OK tag=${tag} state=${r.state} resources=${resSt} ` +
      `telemetry_playing=${r.playing != null ? r.playing : 'NA'} session=${r.session != null ? r.session : 'NA'} ` +
      `glass_contract=IDLE_SCREEN=logo`
  );
  return r;
}

/** Emit GLASS_EXPECT + e2e_mark for parent HDMI join (suite does not capture). */
async function glassMark(cycle, transition, phase, extra = {}) {
  const xml = extra.xml != null ? extra.xml : await pollDaemonTimeline(nextSuiteCmd());
  const state = extra.state != null ? extra.state : xmlAttr(xml, 'state') || '';
  const time = extra.time != null ? extra.time : parseInt(xmlAttr(xml, 'time') || '-1', 10);
  const g = await emitGlassExpect(
    {
      cycle,
      transition,
      phase,
      picture: extra.picture || 'unknown',
      counter: extra.counter || 'na',
      daemon_state: state,
      daemon_time_ms: time,
      ui_time_ms: extra.ui_time_ms,
      ui_pct: extra.ui_pct,
      hold_ms: extra.hold_ms,
      defect_hint: extra.defect_hint || '',
      note: extra.note || '',
    },
    {
      runId: runCorr.runId,
      log,
      mark: (ev, x) => runCorr.mark(ev, x),
    }
  );
  // Optional in-process hold so parent HDMI can grab the named window if
  // capture runs concurrent with the suite (E2E_GLASS_HOLD=1).
  const doHold = /^(1|true|yes|on)$/i.test(String(process.env.E2E_GLASS_HOLD || '0'));
  if (doHold && g && g.hold_ms > 0 && (phase === 'after' || phase === 'hold')) {
    log(`GLASS_HOLD_BEGIN wall_ms=${g.host_wall_ms} hold_ms=${g.hold_ms} picture=${g.picture}`);
    await sleep(g.hold_ms);
    log(`GLASS_HOLD_END wall_ms=${Date.now()} picture=${g.picture}`);
  }
  return g;
}

async function waitTimelineState(wantStates, maxMs = 12000, label = 'wait_state') {
  const want = new Set(Array.isArray(wantStates) ? wantStates : [wantStates]);
  const deadline = Date.now() + maxMs;
  let last = { state: '', time: -1, xml: '' };
  while (Date.now() < deadline) {
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    const state = xmlAttr(xml, 'state') || '';
    const t = parseInt(xmlAttr(xml, 'time') || '-1', 10);
    last = { state, time: t, xml };
    log(`  ${label} state=${state || '?'} time=${xmlAttr(xml, 'time') || '?'}`);
    if (want.has(state)) return { ok: true, ...last };
    await sleep(400);
  }
  return { ok: false, ...last };
}

async function waitTimelineNear(targetMs, tolMs = 2500, maxMs = 15000) {
  const deadline = Date.now() + maxMs;
  let last = { state: '', time: -1 };
  while (Date.now() < deadline) {
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    const state = xmlAttr(xml, 'state') || '';
    const t = parseInt(xmlAttr(xml, 'time') || '-1', 10);
    last = { state, time: t, xml };
    log(`  seek_wait state=${state || '?'} time=${t}`);
    if (t >= 0 && Math.abs(t - targetMs) <= tolMs) {
      return { ok: true, ...last };
    }
    if (t >= targetMs - tolMs && (state === 'playing' || state === 'buffering')) {
      return { ok: true, ...last };
    }
    await sleep(400);
  }
  return { ok: false, ...last };
}

/** Sample companion timeline N times. HTTP 200 alone is never enough. */
async function sampleTimeline(n = 6, intervalMs = 450, label = 'sample') {
  const samples = [];
  for (let i = 0; i < n; i++) {
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    const state = xmlAttr(xml, 'state') || '';
    const time = parseInt(xmlAttr(xml, 'time') || '-1', 10);
    const duration = parseInt(xmlAttr(xml, 'duration') || '0', 10);
    const w = tlSeries.wallNow();
    samples.push({
      state,
      time,
      duration,
      i,
      wall_ms: w.ms,
      wall_iso: w.iso,
    });
    log(`  ${label}[${i}] state=${state || '?'} time=${time} wall_ms=${w.ms}`);
    // Parent HDMI join: host wall clock + Plex-reported position (measured).
    tlSeries.emit({
      tag: `${label}[${i}]`,
      source: 'daemon_timeline',
      plex_time_ms: time >= 0 ? time : null,
      plex_duration_ms: duration > 0 ? duration : null,
      state,
    });
    if (i + 1 < n) await sleep(intervalMs);
  }
  return samples;
}

function timesOf(samples, pred) {
  return samples.filter(pred).map((s) => s.time).filter((t) => t >= 0);
}

/** Position must NOT advance (paused / held). */
function assertTimeFrozen(samples, tag, maxDriftMs = 700) {
  const playingish = samples.filter((s) => s.state === 'playing');
  if (playingish.length >= Math.ceil(samples.length / 2)) {
    return {
      ok: false,
      detail: `${tag}: majority still state=playing (HTTP pause accepted but not effective)`,
    };
  }
  const paused = samples.filter((s) => s.state === 'paused');
  if (paused.length < 2) {
    return {
      ok: false,
      detail: `${tag}: need ≥2 paused samples; got states=${samples.map((s) => s.state).join(',')}`,
    };
  }
  const ts = paused.map((s) => s.time).filter((t) => t >= 0);
  if (ts.length < 2) {
    return { ok: false, detail: `${tag}: paused samples lack time attrs` };
  }
  const drift = Math.max(...ts) - Math.min(...ts);
  if (drift > maxDriftMs) {
    return {
      ok: false,
      detail: `${tag}: paused time advanced drift=${drift}ms > ${maxDriftMs}ms (times=${ts.join(',')})`,
    };
  }
  return { ok: true, drift, time: ts[ts.length - 1], state: 'paused' };
}

/** Position must advance while playing. */
function assertTimeAdvancing(samples, tag, minAdvanceMs = 400) {
  const playing = samples.filter((s) => s.state === 'playing' && s.time >= 0);
  if (playing.length < 2) {
    return {
      ok: false,
      detail: `${tag}: need ≥2 playing samples with time; got states=${samples
        .map((s) => s.state)
        .join(',')}`,
    };
  }
  let advance = 0;
  for (let i = 1; i < playing.length; i++) {
    const d = playing[i].time - playing[i - 1].time;
    if (d > 0) advance += d;
  }
  const span = playing[playing.length - 1].time - playing[0].time;
  if (advance < minAdvanceMs && span < minAdvanceMs) {
    return {
      ok: false,
      detail:
        `${tag}: playing but time did not advance ` +
        `(advance=${advance}ms span=${span}ms min=${minAdvanceMs}; ` +
        `times=${playing.map((s) => s.time).join(',')})`,
    };
  }
  return {
    ok: true,
    advance: Math.max(advance, span),
    time: playing[playing.length - 1].time,
    state: 'playing',
  };
}

/** After suite stop: not playing/paused with an active advancing session. */
function assertStoppedOrIdle(samples, tag) {
  const bad = samples.filter((s) => s.state === 'playing' || s.state === 'paused');
  if (bad.length === 0) {
    return { ok: true, state: samples[samples.length - 1]?.state || 'idle' };
  }
  // Tolerate a single stale sample then idle.
  const tail = samples.slice(-3);
  if (tail.every((s) => s.state !== 'playing' && s.state !== 'paused')) {
    return { ok: true, state: tail[tail.length - 1].state };
  }
  // buffering@0 / stopped@0 is idle-shaped.
  const idleShaped = samples.filter(
    (s) =>
      s.state === 'stopped' ||
      s.state === '' ||
      (s.state === 'buffering' && (s.time === 0 || s.duration === 0))
  );
  if (idleShaped.length >= Math.ceil(samples.length / 2) && bad.length <= 1) {
    return { ok: true, state: idleShaped[idleShaped.length - 1].state || 'buffering' };
  }
  return {
    ok: false,
    detail: `${tag}: expected stopped/idle after stop; samples=${samples
      .map((s) => `${s.state}@${s.time}`)
      .join(' ')}`,
  };
}

function cycleFail(cycle, total, transition, reason, detail) {
  const fullReason = `transition_cycle_${cycle}_${transition}`;
  const fullDetail =
    `CYCLE ${cycle}/${total} FAILED at transition=${transition} reason=${reason}\n${detail || ''}`;
  console.error(`FAIL test_cast_picker_playwright: ${fullReason}`);
  console.error(fullDetail);
  const err = new FailError(fullReason, fullDetail);
  err.cycle = cycle;
  err.transition = transition;
  err.failReason = reason;
  throw err;
}

/**
 * Force a known start-of-cycle baseline so seek residual from the previous
 * cycle cannot poison the next (seek@8s left mid-clip). Always stop, then
 * recast+play from beginning; log the starting timeline time.
 */
async function resetCycleStartState(page, itemTitle, detailsUrl, cycle, total) {
  const tag = `c${cycle}_reset`;
  const pre = await sampleTimeline(3, 250, `${tag}_pre`);
  const preT = pre.length ? pre[pre.length - 1].time : -1;
  const preS = pre.length ? pre[pre.length - 1].state : '?';
  log(
    `CYCLE_START_RESET cycle=${cycle}/${total} prior_state=${preS} prior_time=${preT} ` +
      `(clearing seek/play residual before baseline)`
  );
  await forceStopDaemon(tag).catch(() => false);
  await sleep(700);
  const afterStop = await sampleTimeline(3, 250, `${tag}_stopped`);
  const stopOk = assertStoppedOrIdle(afterStop, tag);
  if (!stopOk.ok) {
    await forceStopDaemon(`${tag}_2`).catch(() => false);
    await sleep(500);
  }
  const ready = await gotoDetailsClean(page, detailsUrl, itemTitle);
  await ensureExactCastSelected(page, itemTitle);
  const ready2 = await waitForDetailsReady(page, itemTitle, 60000);
  await playFromDetails(page, itemTitle, ready2.playSel || ready.playSel, tag);
  await runCorr.mark('cycle_play_issued', { cycle });
  // Prefer "start from the beginning" — already inside handleResumeDialog.
  const waitSec = Math.min(cfg.playWaitSec, 12);
  const prog = await waitPlayingOnDaemon(waitSec);
  if (prog.playing < 2) {
    await runCorr.mark('cycle_not_playing', { cycle });
    cycleFail(
      cycle,
      total,
      'cycle_reset',
      'not_playing',
      `Could not establish clean cycle start (playing=${prog.playing} max_t=${prog.maxT})`
    );
  }
  const samples = await sampleTimeline(5, 350, `${tag}_base`);
  const adv = assertTimeAdvancing(samples, tag, 300);
  const t0 = samples.length ? samples[0].time : prog.maxT;
  const joined = await runCorr.joinTelemetry(`cycle_${cycle}_playing`);
  log(
    `CYCLE_START_STATE cycle=${cycle}/${total} time0_ms=${t0} advancing=${adv.ok ? 1 : 0} ` +
      `max_t=${prog.maxT} run_id=${runCorr.runId} daemon_session=${joined.session || 'NA'} ` +
      `(controlled baseline — not residual seek position)`
  );
  if (!adv.ok) {
    cycleFail(cycle, total, 'cycle_reset', 'not_advancing', adv.detail || '');
  }
  // Soft warn if we somehow resumed deep into the clip (resume dialog missed).
  if (t0 > 5000) {
    log(
      `WARN CYCLE_START_STATE time0_ms=${t0} is deep in clip — residual resume may have leaked; ` +
        `cycle continues but start was not near 0`
    );
  }
  return { time0: t0, advancing: adv.ok, maxT: prog.maxT };
}

async function dismissFullPlayerOverlay(page) {
  for (const sel of [
    'button[aria-label="Close"]',
    'button[aria-label="Close Player"]',
    'button[aria-label="Exit"]',
    '[data-testid="close-button"]',
    'button[aria-label="Back"]',
  ]) {
    const loc = page.locator(sel).first();
    try {
      if (await loc.isVisible({ timeout: 400 })) {
        await loc.click({ timeout: 2000, force: true });
        log(`full_player_dismiss via ${sel}`);
        await sleep(400);
        return true;
      }
    } catch (_) {
      /* next */
    }
  }
  try {
    await page.keyboard.press('Escape');
    await sleep(300);
  } catch (_) {
    /* ignore */
  }
  return false;
}

async function gotoDetailsClean(page, detailsUrl, itemTitle) {
  await page.goto(detailsUrl, { waitUntil: 'domcontentloaded', timeout: cfg.timeoutMs });
  await dismissUserPicker(page, cfg.webUser);
  await dismissFullPlayerOverlay(page);
  const ready = await waitForDetailsReady(page, itemTitle, Math.max(cfg.timeoutMs, 60000));
  const intercept = page
    .locator('[class*="FullPlayerTopControls"], [class*="PlayerContainer-container"]')
    .first();
  try {
    await intercept.waitFor({ state: 'hidden', timeout: 8000 });
    log('full_player_overlay hidden');
  } catch (_) {
    log('full_player_overlay_not_seen_or_still_visible');
    await dismissFullPlayerOverlay(page);
  }
  return ready;
}

async function ensureExactCastSelected(page, _itemTitle) {
  await dismissFullPlayerOverlay(page);
  for (let i = 0; i < 20; i++) {
    const intercept = page
      .locator('[class*="FullPlayerTopControls"], [class*="PlayerContainer-container"]')
      .first();
    const vis = await intercept.isVisible().catch(() => false);
    if (!vis) break;
    await sleep(250);
  }

  const ctl = await waitForSelectPlayerControl(page, 30000);
  if (ctl.kind !== 'ok') {
    fail(
      'transition_select_player_missing',
      'Select Player control not found while re-selecting cast after stop'
    );
  }
  const before = await bodyLineSet(page);
  log(`ensure_cast body_lines_before=${before.size} sel=${ctl.sel}`);
  await ctl.el.click({ timeout: 8000 });
  {
    const menu = page.locator('[role="menu"], [role="listbox"], [role="dialog"]').first();
    try {
      await menu.waitFor({ state: 'visible', timeout: 8000 });
    } catch (_) {
      await sleep(800);
    }
    await sleep(600);
  }
  const target = await assertMisterplexInPickerDiff(page, before);
  const clickedText = ((await target.innerText().catch(() => '')) || '')
    .trim()
    .split('\n')[0]
    .trim();
  const exactNameRe = new RegExp(
    `^${cfg.castName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`,
    'i'
  );
  if (clickedText && !exactNameRe.test(clickedText) && clickedText !== cfg.castName) {
    fail(
      'picker_clicked_non_exact_target',
      `Recast refused ghost label ${JSON.stringify(clickedText)}; want ${JSON.stringify(cfg.castName)}`
    );
  }
  await target.click();
  log(
    `ensure_cast_selected exact=${cfg.castName} clicked_text=${JSON.stringify(clickedText || cfg.castName)}`
  );
  return true;
}

async function playFromDetails(page, itemTitle, playSelPrefer, label) {
  const ready = playSelPrefer
    ? { playSel: playSelPrefer }
    : await waitForDetailsReady(page, itemTitle, Math.max(cfg.timeoutMs, 60000));
  const played = await clickPlay(page, ready.playSel);
  if (!played) {
    await dismissFullPlayerOverlay(page);
    const ready2 = await waitForDetailsReady(page, itemTitle, 30000);
    const played2 = await clickPlay(page, ready2.playSel);
    if (!played2) {
      fail(`${label}_play_missing`, `Play control missing during ${label}`);
    }
    await handleResumeDialog(page);
    return played2;
  }
  await handleResumeDialog(page);
  return played;
}

async function ensurePlayingSession(page, itemTitle, detailsUrl, label, waitSec) {
  let samples = await sampleTimeline(5, 400, `${label}_pre`);
  let adv = assertTimeAdvancing(samples, label, 300);
  if (adv.ok) return adv;
  log(`${label}: not advancing (state may be idle) — recast+play`);
  await forceStopDaemon(`${label}_clear`).catch(() => false);
  await sleep(600);
  const ready = await gotoDetailsClean(page, detailsUrl, itemTitle);
  await ensureExactCastSelected(page, itemTitle);
  const ready2 = await waitForDetailsReady(page, itemTitle, 60000);
  await playFromDetails(page, itemTitle, ready2.playSel || ready.playSel, label);
  const prog = await waitPlayingOnDaemon(waitSec || Math.min(cfg.playWaitSec, 12));
  if (prog.playing < 2) {
    return {
      ok: false,
      detail: `${label}: could not reach playing (samples=${prog.playing} buffering=${prog.buffering || 0})`,
    };
  }
  samples = await sampleTimeline(6, 400, `${label}_post`);
  return assertTimeAdvancing(samples, label, 400);
}

function countPngs(dir) {
  try {
    if (!fs.existsSync(dir)) return 0;
    return fs.readdirSync(dir).filter((f) => /\.png$/i.test(f)).length;
  } catch (_) {
    return 0;
  }
}

function parentHdmiCaptureCmd(cfg, capDir) {
  const dir = capDir || cfg.hdmiCaptureDir;
  const n = Math.max(40, cfg.hdmiWarmupSkip + 30);
  return (
    `mkdir -p ${JSON.stringify(dir)} && rm -f ${JSON.stringify(dir)}/f_*.png && ` +
    `ffmpeg -y -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 ` +
    `-i ${cfg.hdmiVideoDev} -frames:v ${n} ${JSON.stringify(path.join(dir, 'f_%04d.png'))}`
  );
}

function parentHdmiScoreCmd(cfg, capDir) {
  const tool = path.join(ROOT, 'tools', 'hdmi_motion_instrument.py');
  const dir = capDir || cfg.hdmiCaptureDir;
  return (
    `python3 ${JSON.stringify(tool)} ${JSON.stringify(dir)} ` +
    `--warmup-skip ${cfg.hdmiWarmupSkip} ` +
    `--source-fps ${cfg.hdmiSourceFps} --capture-fps ${cfg.hdmiCaptureFps} ` +
    `--json; echo "true rc=$?"`
  );
}

/**
 * Hold one continuous cast session so parent can run multiple HDMI/avsync
 * captures without stop/recast. Session-latched A/V (117 ms bimodality) is
 * DEVICE-side and invisible to this suite — we only keep the session alive,
 * assert PID/session stable, and emit join marks. NO lipsync scoring.
 */
async function runSessionHold(tier, ratingKey) {
  const holdSec = cfg.sessionHoldSec || 0;
  if (holdSec <= 0) {
    log('SESSION_HOLD=off (set E2E_SESSION_HOLD_SEC=360 for parent multi-capture)');
    return { enabled: false };
  }

  log('──────── SESSION_HOLD (parent multi-capture window) ────────');
  log(`SESSION_HOLD_SEC=${holdSec} run_id=${runCorr.runId} tier=${tier.name} rk=${ratingKey}`);
  log(
    'SESSION_LATCH_NOTE: A/V offset is SESSION-LATCHED on device (within-session spread ~3ms, ' +
      'between-cluster ~117ms). Suite cannot see it. Parent: ONE playback session, ' +
      'THREE back-to-back avsync captures. Do NOT stop/recast between captures.'
  );
  log(
    'NO_LIPSYNC_ASSERT: suite will only check playing + pid + session stability during hold. ' +
      'av-lock/av_drift_ms are blind (measured).'
  );

  // Ensure still playing after transitions.
  let prog = await waitPlayingOnDaemon(Math.min(cfg.playWaitSec, 15));
  if (prog.playing < 2) {
    fail(
      'session_hold_not_playing',
      `E2E_SESSION_HOLD_SEC=${holdSec} but daemon not playing (samples=${prog.playing}). ` +
        'Cannot open multi-capture window.'
    );
  }

  await runCorr.mark('session_hold_begin', {
    tier: tier.name,
    ratingKey: String(ratingKey),
  });
  const join0 = await runCorr.joinTelemetry('session_hold_begin');
  await captureAndAssertPid('session_hold_begin', { hardFail: true });

  const holdStartMs = Date.now();
  const holdEndMs = holdStartMs + holdSec * 1000;
  // Parent recipe windows aligned to the confirmed 3-capture experiment.
  const windows = [
    { name: 'cap1', atSec: 12, durSec: 100 },
    { name: 'cap2', atSec: 148, durSec: 100 },
    { name: 'cap3', atSec: 284, durSec: 76 },
  ];
  log('PARENT_MULTI_CAPTURE_RECIPE (pre-registered; ONE session — do not stop between):');
  log(
    `  tools/avsync_measure_hdmi.py  # parent-owned; suite never opens ${cfg.hdmiVideoDev}`
  );
  for (const w of windows) {
    if (w.atSec + 5 > holdSec) {
      log(
        `  SKIP_WINDOW ${w.name} at_s=${w.atSec} — hold ${holdSec}s too short (need ≥${w.atSec + w.durSec})`
      );
      continue;
    }
    log(
      `  WINDOW ${w.name} start_at_hold_s≈${w.atSec} duration_s≈${w.durSec} ` +
        `PREDICTION: within-session medians agree within ~30ms if SESSION-LATCHED; ` +
        `if captures differ by ~117ms → capture-instrument confound (should NOT happen on fixed device session)`
    );
  }
  log(
    `  fps labels for any motion instrument: source_fps=${cfg.hdmiSourceFps} (${cfg.hdmiSourceFpsLabel}) ` +
      `capture_fps=${cfg.hdmiCaptureFps} (${cfg.hdmiCaptureFpsLabel}) — not ffprobe unless caller-supplied`
  );
  log(
    `E2E_JOIN session=${join0.session || 'NA'} run_id=${runCorr.runId} ` +
      `pid=${baselineDaemonPid > 0 ? baselineDaemonPid : 'NA'}`
  );

  let tick = 0;
  let lastSession = join0.session || '';
  while (Date.now() < holdEndMs) {
    tick += 1;
    const elapsed = Math.floor((Date.now() - holdStartMs) / 1000);
    const left = Math.max(0, holdSec - elapsed);
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    const state = xmlAttr(xml, 'state') || '?';
    const time = xmlAttr(xml, 'time') || '?';
    const snap = await captureLedger(cfg);
    const pr = assertPidUnchanged(baselineDaemonPid, snap, `session_hold_t${elapsed}`);
    if (!pr.ok && !pr.softSkip) {
      fail(pr.reason || 'daemon_pid_changed', pr.detail || '');
    }
    if (
      lastSession &&
      snap.session >= 0 &&
      String(snap.session) !== String(lastSession) &&
      snap.session !== -1
    ) {
      fail(
        'session_hold_session_changed',
        `During SESSION_HOLD session ${lastSession} → ${snap.session} at elapsed_s=${elapsed} ` +
          `(respawn/new stream — multi-capture window invalid)`
      );
    }
    if (snap.session >= 0) lastSession = snap.session;

    if (state !== 'playing' && state !== 'buffering') {
      fail(
        'session_hold_left_playing',
        `SESSION_HOLD expected playing; state=${state} time=${time} elapsed_s=${elapsed} ` +
          `run_id=${runCorr.runId}`
      );
    }

    log(
      `SESSION_HOLD_TICK n=${tick} elapsed_s=${elapsed} left_s=${left} state=${state} ` +
        `time_ms=${time} pid=${snap.pid >= 0 ? snap.pid : 'NA'} session=${snap.session >= 0 ? snap.session : 'NA'} ` +
        `run_id=${runCorr.runId}`
    );

    // Mark capture window boundaries for log join.
    for (const w of windows) {
      if (elapsed === w.atSec) {
        await runCorr.mark(`session_hold_${w.name}_open`, {
          tier: tier.name,
          ratingKey: String(ratingKey),
          session: lastSession,
        });
        log(`SESSION_HOLD_WINDOW_OPEN name=${w.name} elapsed_s=${elapsed} run_id=${runCorr.runId}`);
      }
    }

    await sleep(1000);
  }

  await runCorr.mark('session_hold_end', {
    tier: tier.name,
    ratingKey: String(ratingKey),
  });
  await captureAndAssertPid('session_hold_end', { hardFail: true });
  runCorr.persist(cfg.outDir);
  log(
    `SESSION_HOLD_OK sec=${holdSec} run_id=${runCorr.runId} pid=${baselineDaemonPid} ` +
      `session=${lastSession || 'NA'} (still no lipsync claim)`
  );
  return { enabled: true, holdSec, session: lastSession, pid: baselineDaemonPid };
}

/**
 * Score parent-filled capture dir. Never opens /dev/video0.
 * synthetic/motion mode: rc=0 MOTION_OK required; 77 hard FAIL
 * real/color_structure: COLOR_FAIL(2)/STRUCTURE_FAIL(3)/FREEZE(1) fail;
 *   UNSCORED(77) allowed only when assert mode is color_structure (no counter)
 *   BUT STRUCTURE/COLOR still hard-fail. If rc=77 and mode=motion → FAIL.
 */
function scoreHdmiCaptureDir(capDir, cycleTag) {
  const tag = cycleTag || 'hdmi';
  const tool = path.join(ROOT, 'tools', 'hdmi_motion_instrument.py');
  if (!fs.existsSync(tool)) {
    fail(
      'hdmi_motion_instrument_missing',
      `Missing ${tool}. Land tools/hdmi_motion_instrument.py before glass/HDMI score.`
    );
  }
  const nPng = countPngs(capDir);
  log(`hdmi_capture_png_count=${nPng} dir=${capDir} tag=${tag}`);
  if (nPng < 3) {
    fail(
      'hdmi_motion_no_frames',
      `${tag}: glass/HDMI score needs ≥3 PNGs; have ${nPng}.\n` +
        'Parent fills capture dir (suite never opens /dev/video0).\n' +
        `CAPTURE: ${parentHdmiCaptureCmd(cfg, capDir)}\n` +
        `SCORE:   ${parentHdmiScoreCmd(cfg, capDir)}`
    );
  }
  log(`hdmi_score spawning instrument on ${capDir}`);
  const res = spawnSync(
    'python3',
    [
      tool,
      capDir,
      '--warmup-skip',
      String(cfg.hdmiWarmupSkip),
      '--source-fps',
      String(cfg.hdmiSourceFps),
      '--capture-fps',
      String(cfg.hdmiCaptureFps),
      '--json',
    ],
    { encoding: 'utf8', timeout: 300000 }
  );
  const out = `${res.stdout || ''}${res.stderr || ''}`;
  for (const line of out.split('\n').filter(Boolean).slice(-40)) {
    log(`  instrument: ${line.slice(0, 280)}`);
  }
  const rc = typeof res.status === 'number' ? res.status : 99;
  log(`hdmi_instrument true rc=${rc} tag=${tag}`);
  log(
    `hdmi_fps source=${cfg.hdmiSourceFps} (${cfg.hdmiSourceFpsLabel}) ` +
      `capture=${cfg.hdmiCaptureFps} (${cfg.hdmiCaptureFpsLabel})`
  );

  if (rc === 3) {
    fail(
      'hdmi_motion_structure_fail',
      `${tag}: instrument STRUCTURE_FAIL rc=3\n${out.slice(-600)}`
    );
  }
  if (rc === 2) {
    fail(
      'hdmi_motion_color_fail',
      `${tag}: instrument COLOR_FAIL rc=2\n${out.slice(-600)}`
    );
  }
  if (rc === 1) {
    fail(
      'hdmi_motion_freeze',
      `${tag}: instrument FREEZE rc=1\n${out.slice(-600)}`
    );
  }
  if (rc === 4) {
    fail(
      'hdmi_motion_rate_fail',
      `${tag}: instrument RATE_FAIL rc=4 (span/revisit/plateau — display integrity)\n` +
        out.slice(-600)
    );
  }
  if (rc === 77) {
    fail(
      'hdmi_motion_unscored',
      `${tag}: instrument rc=77 UNSCORED — hard FAIL ` +
        '(soft-skip is never a pass). Capture only after session established; ' +
        'synthetic needs TREK overlay.\n' +
        out.slice(-400)
    );
  }
  if (rc !== 0) {
    fail(
      'hdmi_motion_instrument_failed',
      `${tag}: instrument unexpected rc=${rc}\n${out.slice(-500)}`
    );
  }

  // Glass frame-loss % from counter gaps (parent: 22 skips / 1429 → 1.54%).
  // MOTION_OK alone is insufficient if gap loss exceeds threshold.
  const ns = nsFromInstrumentJson(out);
  const gap = analyzeCounterGaps(ns);
  log(
    `GLASS_COUNTER_GAPS tag=${tag} samples=${gap.n_samples} n=${gap.n_first}->${gap.n_last} ` +
      `span=${gap.source_span} skips=${gap.skips} loss_pct=${
        gap.loss_pct != null ? gap.loss_pct.toFixed(3) : 'NA'
      } max_gap=${gap.max_gap} plateaus=${gap.plateaus} backward=${gap.backward} ` +
      `value_kind=${gap.value_kind}`
  );
  const maxLoss = cfg.glassMaxLossPct != null ? cfg.glassMaxLossPct : 1.0;
  const gr = assertGlassLoss(gap, maxLoss, tag);
  if (!gr.ok) {
    if (gr.reason === 'glass_counter_unscored' && !cfg.requireGlass) {
      log(
        `GLASS_LOSS_SOFT_SKIP tag=${tag} ${gr.detail} — E2E_REQUIRE_GLASS=0 ` +
          '(NOT a pass of glass integrity; timeline-only is blind to ~1.5% loss)'
      );
    } else {
      fail(gr.reason || 'glass_frame_loss', gr.detail || '');
    }
  } else {
    log(`GLASS_LOSS_OK ${gr.detail}`);
  }

  log(`HDMI_MOTION_OK instrument rc=0 tag=${tag} glass_loss_ok=${gr.ok ? 1 : 0}`);
  return {
    enabled: true,
    rc: 0,
    mode: cfg.hdmiAssertMode,
    pngs: nPng,
    glass: gap,
    glassOk: !!gr.ok,
  };
}

/**
 * Hold playing and optionally score parent capture for one cycle.
 */
async function optionalHdmiMotionStage(cycle, totalCycles) {
  if (!cfg.hdmiMotion) {
    if (cycle === 1) {
      log('HDMI_MOTION=off (set E2E_HDMI_MOTION=1 to enable parent-scored pixel gate)');
    }
    return { enabled: false };
  }

  const every = cfg.hdmiEveryCycle;
  const isLast = cycle === totalCycles;
  if (!every && !isLast && cycle !== 1) {
    log(`HDMI_MOTION skip cycle=${cycle} (E2E_HDMI_EVERY_CYCLE=0; scoring first+last only)`);
    if (cycle !== 1) return { enabled: false, skipped: true };
  }
  // When every-cycle off: score cycle 1 and last only.
  if (!every && cycle !== 1 && !isLast) {
    return { enabled: false, skipped: true };
  }

  const base = String(cfg.hdmiCaptureDir).replace(/\/$/, '');
  const capDir =
    totalCycles > 1 || every
      ? path.join(base, `cycle_${String(cycle).padStart(2, '0')}`)
      : base;
  try {
    fs.mkdirSync(capDir, { recursive: true });
  } catch (_) {
    /* ignore */
  }

  const tag = `cycle_${cycle}_of_${totalCycles}`;
  const captureCmd = parentHdmiCaptureCmd(cfg, capDir);
  const scoreCmd = parentHdmiScoreCmd(cfg, capDir);
  log(`HDMI_MOTION=on tag=${tag} assert_mode=${cfg.hdmiAssertMode} content=${cfg.contentMode}`);
  log(
    `HDMI_FPS source_fps=${cfg.hdmiSourceFps} (${cfg.hdmiSourceFpsLabel || '?'}) ` +
      `capture_fps=${cfg.hdmiCaptureFps} (${cfg.hdmiCaptureFpsLabel || '?'}) ` +
      `— DEFAULT_ASSUMED is not a measurement (ERROR 17 class)`
  );
  log(`HDMI_CAPTURE_DIR=${capDir}`);
  log(`PARENT_HDMI_CAPTURE_CMD=${captureCmd}`);
  log(`PARENT_HDMI_SCORE_CMD=${scoreCmd}`);
  log(
    `HDMI_HOLD_SEC=${cfg.hdmiHoldSec} — parent should run PARENT_HDMI_CAPTURE_CMD now while playback holds`
  );

  const holdMs = Math.max(0, cfg.hdmiHoldSec) * 1000;
  const holdEnd = Date.now() + holdMs;
  while (Date.now() < holdEnd) {
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    log(
      `  hdmi_hold tag=${tag} state=${xmlAttr(xml, 'state') || '?'} time=${xmlAttr(xml, 'time') || '?'}`
    );
    await sleep(1000);
  }

  return scoreHdmiCaptureDir(capDir, tag);
}

/**
 * One stress cycle: pause/resume/seek/stop-idle-play with EFFECT asserts + optional HDMI.
 * Always begins with resetCycleStartState so prior-cycle seek@8s cannot accumulate.
 */
async function runOneTransitionCycle(page, itemTitle, detailsUrl, cycle, total) {
  const ctag = `c${cycle}`;
  const waitSec = Math.min(cfg.playWaitSec, 12);

  // ── controlled baseline (no residual seek from previous cycle) ─────────
  const start = await resetCycleStartState(page, itemTitle, detailsUrl, cycle, total);
  let adv = { ok: true, time: start.time0, advance: 0, detail: '' };

  // Ledger at start of continuous-play window (after baseline, before pause).
  await sleep(1100); // allow ≥1 Hz media telemetry tick when using log source
  const ledgerStart = await captureLedger(cfg);
  log(`LEDGER_START cycle=${cycle}/${total} ${formatSnap(ledgerStart)}`);

  await glassMark(cycle, 'play', 'after', {
    picture: 'motion',
    counter: 'advancing',
    note: 'baseline playing before pause — parent: motion + TREK n advancing',
    hold_ms: 2000,
  });

  // ── pause: UI-first (control plane user touches), then effect asserts ───
  await glassMark(cycle, 'pause', 'before', {
    picture: 'motion',
    counter: 'advancing',
    note: 'about to pause',
    hold_ms: 500,
  });
  let uiPause = await clickPauseOrPlayToggle(page);
  log(`transition_pause_ui selector=${uiPause || '(none)'}`);
  let st = await waitTimelineState(['paused'], 8000, `${ctag}_pause`);
  if (!st.ok) {
    // One HTTP fallback only if UI control missing/ineffective — tagged.
    log(`${ctag}_pause UI miss/ineffective — companion HTTP pause fallback (tagged)`);
    await companionPlayback('pause', `${ctag}_pause_http_fallback`);
    st = await waitTimelineState(['paused'], 6000, `${ctag}_pause_http`);
  }
  if (!st.ok && (st.state === 'buffering' || st.state === 'stopped' || st.state === '')) {
    log(`${ctag}_pause session_dropped — reseed`);
    adv = await ensurePlayingSession(page, itemTitle, detailsUrl, `${ctag}_pause_reseed`, waitSec);
    if (!adv.ok) cycleFail(cycle, total, 'pause_reseed', 'not_playing', adv.detail);
    uiPause = await clickPauseOrPlayToggle(page);
    st = await waitTimelineState(['paused'], 8000, `${ctag}_pause2`);
    if (!st.ok) {
      await companionPlayback('pause', `${ctag}_pause2_http`);
      st = await waitTimelineState(['paused'], 8000, `${ctag}_pause2_http`);
    }
  }
  if (!st.ok) {
    cycleFail(
      cycle,
      total,
      'pause',
      'state_not_paused',
      `Expected state=paused after UI pause; got state=${st.state} time=${st.time} ui=${uiPause || 'none'}`
    );
  }
  let samples = await sampleTimeline(6, 400, `${ctag}_paused`);
  let fr = assertTimeFrozen(samples, `${ctag}_pause`);
  if (!fr.ok) cycleFail(cycle, total, 'pause', 'time_still_advancing', fr.detail);
  // Nudge player chrome so scrubber/timeline is visible (user overlay defect window).
  await page.mouse.move(640, 600).catch(() => {});
  await page.mouse.click(640, 600).catch(() => {});
  await sleep(400);
  let uiPauseClock = null;
  {
    const uiR = await assertUiMatchesDaemon(page, `${ctag}_pause_ui_clock`);
    uiPauseClock = uiR;
    if (!uiR.ok && !uiR.softSkip) {
      cycleFail(cycle, total, 'ui_timeline', uiR.reason || 'ui_daemon_skew', uiR.detail || '');
    }
  }
  log(
    `transition_pause_ok cycle=${cycle}/${total} time=${fr.time} drift_ms=${fr.drift} ui=${uiPause || 'http_fallback'}`
  );
  // Control-plane: paused + frozen time. Glass: parent scores freeze AND
  // pause-overlay chrome resolution (user: "timeline very low res when paused").
  // Present path is 529×240 only — suite never claims fine chrome detail.
  const pauseHold = parseInt(process.env.E2E_PAUSE_OVERLAY_HOLD_MS || '4000', 10) || 4000;
  const uiM = (uiPauseClock && uiPauseClock.metrics) || {};
  await glassMark(cycle, 'pause', 'after', {
    picture: 'pause_overlay',
    counter: 'pinned',
    state: 'paused',
    time: fr.time,
    ui_time_ms: uiM.ui_ms != null ? uiM.ui_ms : undefined,
    ui_pct: uiM.ui_pct != null ? uiM.ui_pct : undefined,
    defect_hint: 'pause_overlay_low_res',
    note:
      'CONTROL: state=paused time frozen. GLASS(parent): frozen frame + player chrome/timeline ' +
      'visible on MiSTer — score chrome res (user low-res overlay bug). 529x240 present only. ' +
      'Playwright PASS ≠ video OK.',
    hold_ms: pauseHold,
  });
  // Always give parent a short named window even without E2E_GLASS_HOLD (log timestamps).
  log(
    `PAUSE_OVERLAY_WINDOW_OPEN wall_ms=${Date.now()} hold_ms=${pauseHold} ` +
      `daemon_time_ms=${fr.time} — parent: capture now for overlay chrome res`
  );
  if (!/^(1|true|yes|on)$/i.test(String(process.env.E2E_GLASS_HOLD || '0'))) {
    // Brief settle so chrome paints; full hold is parent's capture job unless E2E_GLASS_HOLD=1.
    await sleep(Math.min(1200, pauseHold));
  }
  log(`PAUSE_OVERLAY_WINDOW_CLOSE wall_ms=${Date.now()}`);

  // ── resume: UI-first play toggle ───────────────────────────────────────
  const pausedTime = fr.time;
  let uiResume = await clickPauseOrPlayToggle(page);
  log(`transition_resume_ui selector=${uiResume || '(none)'}`);
  st = await waitTimelineState(['playing'], 12000, `${ctag}_resume`);
  if (!st.ok) {
    log(`${ctag}_resume UI miss — companion HTTP play fallback (tagged)`);
    await companionPlayback('play', `${ctag}_resume_http_fallback`);
    st = await waitTimelineState(['playing'], 8000, `${ctag}_resume_http`);
  }
  if (!st.ok) {
    cycleFail(
      cycle,
      total,
      'resume',
      'state_not_playing',
      `Expected playing after UI resume; got state=${st.state} time=${st.time} ui=${uiResume || 'none'}`
    );
  }
  samples = await sampleTimeline(7, 400, `${ctag}_resumed`);
  adv = assertTimeAdvancing(samples, `${ctag}_resume`, 400);
  if (!adv.ok) cycleFail(cycle, total, 'resume', 'time_not_advancing', adv.detail);
  // Soft check: time should move past paused anchor (allow small equality if sample early).
  if (pausedTime >= 0 && adv.time + 50 < pausedTime) {
    cycleFail(
      cycle,
      total,
      'resume',
      'time_regressed',
      `resume time=${adv.time} < paused time=${pausedTime}`
    );
  }
  {
    const uiR = await assertUiMatchesDaemon(page, `${ctag}_resume_ui_clock`);
    if (!uiR.ok && !uiR.softSkip) {
      cycleFail(cycle, total, 'ui_timeline', uiR.reason || 'ui_daemon_skew', uiR.detail || '');
    }
  }
  log(
    `transition_resume_ok cycle=${cycle}/${total} time=${adv.time} advance_ms=${adv.advance} ui=${uiResume || 'http_fallback'}`
  );
  await glassMark(cycle, 'resume', 'after', {
    picture: 'motion',
    counter: 'advancing',
    state: 'playing',
    time: adv.time,
    note: 'EXPECT motion resumes; counter advances from pause pin',
    hold_ms: 2000,
  });

  // ── seek FORWARD: land near target THEN advance ────────────────────────
  // Short synthetic fixtures (~30s) and external controllers can drop the
  // session between resume and seek (buffering@0). Reseed if needed so seek
  // is tested on a live wantPlay session — HTTP 200 on a dead session is a false pass.
  {
    const preSeek = await sampleTimeline(3, 300, `${ctag}_pre_seek`);
    const alive = preSeek.some((s) => s.state === 'playing' || s.state === 'paused');
    if (!alive) {
      log(`${ctag}_seek session_not_alive before seek — reseed play`);
      adv = await ensurePlayingSession(page, itemTitle, detailsUrl, `${ctag}_seek_reseed`, waitSec);
      if (!adv.ok) cycleFail(cycle, total, 'seek_reseed', 'not_playing', adv.detail);
    }
  }
  const seekTo = 8000;
  // Prefer UI scrubber (user control plane). Fall back to HTTP seekTo only if bar missing.
  let seekHow = 'ui';
  const xmlDur = await pollDaemonTimeline(nextSuiteCmd());
  const durMs = parseInt(xmlAttr(xmlDur, 'duration') || '0', 10);
  const frac = durMs > 0 ? seekTo / durMs : 0.05;
  const uiSeek = await uiSeekFraction(page, frac);
  if (uiSeek) {
    log(`transition_seek_ui selector=${uiSeek} target_ms=${seekTo} frac=${frac.toFixed(4)} dur=${durMs}`);
    st = await waitTimelineNear(seekTo, 4500, 15000);
  } else {
    seekHow = 'http_fallback';
    log(`${ctag}_seek no UI scrubber — companion seekTo HTTP fallback (tagged)`);
    await companionPlayback(`seekTo?offset=${seekTo}`, `${ctag}_seek_http`);
    st = await waitTimelineNear(seekTo, 3500, 15000);
  }
  if (!st.ok) {
    log(`${ctag}_seek land miss state=${st.state} time=${st.time} — reseed+HTTP retry once`);
    adv = await ensurePlayingSession(page, itemTitle, detailsUrl, `${ctag}_seek_retry`, waitSec);
    if (!adv.ok) {
      cycleFail(
        cycle,
        total,
        'seek',
        'did_not_land',
        `Expected timeline near offset=${seekTo}ms; got state=${st.state} time=${st.time}; reseed failed how=${seekHow}`
      );
    }
    const uiSeek2 = await uiSeekFraction(page, frac);
    if (!uiSeek2) {
      await companionPlayback(`seekTo?offset=${seekTo}`, `${ctag}_seek2_http`);
      seekHow = 'http_fallback_retry';
    } else {
      seekHow = 'ui_retry';
    }
    st = await waitTimelineNear(seekTo, 3500, 15000);
  }
  if (!st.ok) {
    cycleFail(
      cycle,
      total,
      'seek',
      'did_not_land',
      `Expected timeline near offset=${seekTo}ms; got state=${st.state} time=${st.time} how=${seekHow}`
    );
  }
  log(
    `transition_seek_land_ok cycle=${cycle}/${total} target=${seekTo} time=${st.time} how=${seekHow}`
  );
  // Wait until playing after possible buffering.
  st = await waitTimelineState(['playing'], 12000, `${ctag}_post_seek`);
  if (!st.ok) {
    cycleFail(
      cycle,
      total,
      'seek',
      'not_playing_after_land',
      `After seek land expected playing; got ${st.state}@${st.time}`
    );
  }
  samples = await sampleTimeline(7, 400, `${ctag}_seek_adv`);
  adv = assertTimeAdvancing(samples, `${ctag}_seek`, 300);
  if (!adv.ok) cycleFail(cycle, total, 'seek', 'time_not_advancing_after_seek', adv.detail);
  {
    const uiR = await assertUiMatchesDaemon(page, `${ctag}_seek_ui_clock`);
    if (!uiR.ok && !uiR.softSkip) {
      cycleFail(cycle, total, 'ui_timeline', uiR.reason || 'ui_daemon_skew', uiR.detail || '');
    }
  }
  log(
    `transition_seek_ok cycle=${cycle}/${total} target=${seekTo} time=${adv.time} how=${seekHow}`
  );
  await glassMark(cycle, 'seek_fwd', 'after', {
    picture: 'seek_discontinuity',
    counter: 'advancing',
    state: 'playing',
    time: adv.time,
    note: `EXPECT counter near source frame for ~${seekTo}ms then advances; how=${seekHow}`,
    hold_ms: 2000,
  });
  // Timeline scrub with chrome: user low-res overlay also appears on play+timeline.
  await glassMark(cycle, 'seek_fwd', 'hold', {
    picture: 'play_chrome',
    counter: 'advancing',
    state: 'playing',
    time: adv.time,
    defect_hint: 'play_timeline_overlay_low_res',
    note:
      'CONTROL: playing near seek target. GLASS(parent): if player chrome/timeline drawn on MiSTer, ' +
      'score chrome res (529x240 present). Playwright cannot verify overlay pixels.',
    hold_ms: 2500,
  });

  // ── seek BACKWARD: earlier offset, land, then advance ───────────────────
  {
    const seekBackTo = 2000;
    await glassMark(cycle, 'seek_back', 'before', {
      picture: 'motion',
      counter: 'advancing',
      note: `about to seek back to ${seekBackTo}ms`,
      hold_ms: 400,
    });
    let seekBackHow = 'ui';
    const xmlDurB = await pollDaemonTimeline(nextSuiteCmd());
    const durB = parseInt(xmlAttr(xmlDurB, 'duration') || '0', 10);
    const fracB = durB > 0 ? seekBackTo / durB : 0.02;
    const uiSeekB = await uiSeekFraction(page, fracB);
    let stB;
    if (uiSeekB) {
      log(
        `transition_seek_back_ui selector=${uiSeekB} target_ms=${seekBackTo} frac=${fracB.toFixed(4)}`
      );
      stB = await waitTimelineNear(seekBackTo, 4500, 15000);
    } else {
      seekBackHow = 'http_fallback';
      log(`${ctag}_seek_back no UI scrubber — HTTP seekTo fallback (tagged)`);
      await companionPlayback(`seekTo?offset=${seekBackTo}`, `${ctag}_seek_back_http`);
      stB = await waitTimelineNear(seekBackTo, 3500, 15000);
    }
    if (!stB.ok) {
      await companionPlayback(`seekTo?offset=${seekBackTo}`, `${ctag}_seek_back_http2`);
      seekBackHow = 'http_fallback_retry';
      stB = await waitTimelineNear(seekBackTo, 3500, 12000);
    }
    if (!stB.ok) {
      cycleFail(
        cycle,
        total,
        'seek_back',
        'did_not_land',
        `Expected timeline near offset=${seekBackTo}ms; got state=${stB.state} time=${stB.time} how=${seekBackHow}`
      );
    }
    stB = await waitTimelineState(['playing'], 10000, `${ctag}_post_seek_back`);
    if (!stB.ok) {
      cycleFail(
        cycle,
        total,
        'seek_back',
        'not_playing_after_land',
        `After seek_back expected playing; got ${stB.state}@${stB.time}`
      );
    }
    let samplesB = await sampleTimeline(6, 400, `${ctag}_seek_back_adv`);
    let advB = assertTimeAdvancing(samplesB, `${ctag}_seek_back`, 250);
    if (!advB.ok) {
      cycleFail(cycle, total, 'seek_back', 'time_not_advancing_after_seek', advB.detail);
    }
    // Backward seek should land earlier than the forward target (allow slack).
    if (advB.time > seekTo + 2000) {
      cycleFail(
        cycle,
        total,
        'seek_back',
        'not_earlier_than_fwd',
        `seek_back time=${advB.time} still past fwd target=${seekTo}`
      );
    }
    log(
      `transition_seek_back_ok cycle=${cycle}/${total} target=${seekBackTo} time=${advB.time} how=${seekBackHow}`
    );
    await glassMark(cycle, 'seek_back', 'after', {
      picture: 'seek_discontinuity',
      counter: 'advancing',
      state: 'playing',
      time: advB.time,
      note: `EXPECT counter jump back near ~${seekBackTo}ms then advance`,
      hold_ms: 2000,
    });
  }

  // Ledger end of continuous-play window (still same demux session; before stop).
  await sleep(1100);
  const ledgerEnd = await captureLedger(cfg);
  log(`LEDGER_END cycle=${cycle}/${total} ${formatSnap(ledgerEnd)}`);
  {
    const lr = assertLedgerWindow(ledgerStart, ledgerEnd, `${ctag}_continuous`);
    if (lr.softSkip) {
      log(`LEDGER_SOFT_SKIP cycle=${cycle}/${total} ${lr.detail}`);
    } else if (!lr.ok) {
      cycleFail(cycle, total, 'ledger', lr.reason || 'ledger_fail', lr.detail || '');
    } else {
      log(
        `LEDGER_OK cycle=${cycle}/${total} residual=${lr.residual != null ? lr.residual : 'NA'} ` +
          `session=${lr.session} pid=${lr.pid != null ? lr.pid : ledgerEnd.pid}` +
          (lr.plxd_frames_void ? ' plxd_frames_void=1' : '') +
          (lr.note ? ` note=${lr.note}` : '')
      );
    }
  }
  // Whole-run PID/exe must match baseline (any cycle sees respawn → named fail).
  {
    const pr = assertPidUnchanged(baselineDaemonPid, ledgerEnd, `${ctag}_pid`, {
      baselineExe: baselineDaemonExe,
    });
    if (baselineDaemonPid < 0 && ledgerEnd.pid > 0) {
      baselineDaemonPid = ledgerEnd.pid;
      baselineDaemonExe = ledgerEnd.exe || '';
      log(
        `DAEMON_PID_BASELINE pid=${baselineDaemonPid} exe=${baselineDaemonExe || 'NA'} tag=${ctag}`
      );
    }
    if (pr.softSkip) {
      log(`DAEMON_PID_SOFT_SKIP cycle=${cycle}/${total} ${pr.detail}`);
    } else if (!pr.ok) {
      cycleFail(cycle, total, 'pid', pr.reason || 'daemon_pid_changed', pr.detail || '');
    } else {
      log(
        `DAEMON_PID_OK cycle=${cycle}/${total} pid=${pr.pid || ledgerEnd.pid} ` +
          `exe=${(ledgerEnd.exe || baselineDaemonExe || '').replace(/^.*\//, '')}`
      );
    }
  }

  // ── stop → idle: UI Stop first, HTTP only as tagged fallback ───────────
  const uiStop = await clickStop(page);
  log(`transition_stop_ui ok=${uiStop ? 1 : 0}`);
  await sleep(700);
  samples = await sampleTimeline(5, 350, `${ctag}_stopped`);
  let idle = assertStoppedOrIdle(samples, `${ctag}_stop`);
  if (!idle.ok) {
    log(`${ctag}_stop UI insufficient — forceStopDaemon HTTP fallback (tagged)`);
    await forceStopDaemon(`${ctag}_stop_http`);
    await sleep(700);
    samples = await sampleTimeline(5, 350, `${ctag}_stopped2`);
    idle = assertStoppedOrIdle(samples, `${ctag}_stop2`);
  }
  if (!idle.ok) cycleFail(cycle, total, 'stop', 'not_idle', idle.detail);
  log(
    `transition_stop_ok cycle=${cycle}/${total} state=${idle.state} ui=${uiStop ? 1 : 0}`
  );
  await glassMark(cycle, 'stop', 'after', {
    picture: 'idle_logo',
    counter: 'na',
    state: idle.state,
    time: samples.length ? samples[samples.length - 1].time : -1,
    note: 'EXPECT IDLE_SCREEN=logo static Plex logo; no moving decode (parent conf)',
    hold_ms: 2500,
  });
  // P4: device-side idle (timeline + resources + telemetry playing≠1) — not UI-only.
  await assertP4DeviceIdle(`${ctag}_stop`, samples);

  // ── idle → play (recast exact target) ──────────────────────────────────
  await dismissFullPlayerOverlay(page);
  let ready = await gotoDetailsClean(page, detailsUrl, itemTitle);
  await ensureExactCastSelected(page, itemTitle);
  ready = await waitForDetailsReady(page, itemTitle, 60000);
  await playFromDetails(page, itemTitle, ready.playSel, `${ctag}_replay`);
  let prog = await waitPlayingOnDaemon(waitSec);
  if (prog.playing < 2) {
    await ensureExactCastSelected(page, itemTitle);
    ready = await waitForDetailsReady(page, itemTitle, 60000);
    await playFromDetails(page, itemTitle, ready.playSel, `${ctag}_replay2`);
    prog = await waitPlayingOnDaemon(waitSec);
  }
  if (prog.playing < 2) {
    cycleFail(
      cycle,
      total,
      'play_idle_play',
      'not_playing',
      `samples=${prog.playing} buffering=${prog.buffering || 0}`
    );
  }
  samples = await sampleTimeline(6, 400, `${ctag}_replay_adv`);
  adv = assertTimeAdvancing(samples, `${ctag}_replay`, 400);
  if (!adv.ok) cycleFail(cycle, total, 'play_idle_play', 'time_not_advancing', adv.detail);
  log(
    `transition_replay_ok cycle=${cycle}/${total} samples=${prog.playing} time_max_ms=${prog.maxT} advance_ms=${adv.advance}`
  );
  await glassMark(cycle, 'play', 'after', {
    picture: 'motion',
    counter: 'advancing',
    note: 'stop→play again — EXPECT motion + advancing counter',
    hold_ms: 2000,
  });

  // ── optional HDMI score (parent-filled dir) while playing after replay ─
  const hdmi = await optionalHdmiMotionStage(cycle, total);

  // Leave cycle in a defined idle so N-loop / suite end never leaves mid-play.
  await forceStopDaemon(`${ctag}_cycle_end_idle`).catch(() => false);
  await glassMark(cycle, 'idle', 'after', {
    picture: 'idle_logo',
    counter: 'na',
    note: 'cycle end forced idle — daily driver safe',
    hold_ms: 1000,
  });
  await assertP4DeviceIdle(`${ctag}_cycle_end`);

  return {
    cycle,
    ok: true,
    startTime0: start.time0,
    transitions: [
      'pause',
      'resume',
      'seek_fwd',
      'seek_back',
      'ledger',
      'stop',
      'play_idle_play',
      'idle',
    ],
    ledger: { start: ledgerStart, end: ledgerEnd },
    hdmi,
  };
}

/**
 * Multi-cycle transition stress. Default E2E_TRANSITION_CYCLES=10.
 * Planned N is always attempted when continue_on_fail (default for N>1) so a
 * 1-in-N flake cannot hide behind early abort. PASS requires pass==N fail==0.
 * Failure names WHICH cycle and WHICH transition.
 */

/**
 * Re-open Select Player and re-assert exact MiSTerPlex (cold/mid-run discovery).
 * Parent uses this after daemon restart by re-running suite or E2E_DISCOVERY_RECHECK=1.
 */
async function recheckDiscoveryPicker(page, itemTitle, tag = 'discovery_recheck') {
  const before = await bodyLineSet(page);
  const ctl = await waitForSelectPlayerControl(page, 30000);
  if (ctl.kind !== 'ok') {
    fail(
      'discovery_recheck_no_select_player',
      `${tag}: Select Player control missing on recheck`
    );
  }
  await ctl.el.click({ timeout: 5000 });
  await sleep(1200);
  const target = await assertMisterplexInPickerDiff(page, before);
  const clickedText = ((await target.innerText().catch(() => '')) || '').trim().split('\n')[0].trim();
  const exactNameRe = new RegExp(
    `^${cfg.castName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`,
    'i'
  );
  if (clickedText && !exactNameRe.test(clickedText) && clickedText !== cfg.castName) {
    fail(
      'discovery_recheck_ghost',
      `${tag}: ghost/near-miss ${JSON.stringify(clickedText)}`
    );
  }
  await page.keyboard.press('Escape').catch(() => {});
  await sleep(300);
  await glassMark(0, 'discovery', 'after', {
    picture: 'picker_ui',
    counter: 'na',
    note: `${tag}: MiSTerPlex still in picker (exact)`,
    hold_ms: 800,
  });
  log(`DISCOVERY_RECHECK_OK tag=${tag} exact=${cfg.castName}`);
  return { ok: true, clickedText };
}

async function runTransitionScenarios(page, itemTitle, detailsUrl, _castAlreadySelected) {
  if (!cfg.transitions) {
    log('TRANSITIONS=off (E2E_TRANSITIONS=0)');
    return { enabled: false, cycles: 0, passed: 0 };
  }
  const total = Math.max(1, cfg.transitionCycles || 10);
  const continueOnFail = cfg.transitionContinueOnFail !== false;
  log(
    `TRANSITIONS=on cycles=${total} continue_on_fail=${continueOnFail ? 1 : 0} ` +
      `content=${cfg.contentMode} hdmi=${cfg.hdmiMotion ? 1 : 0} ` +
      `hdmi_every=${cfg.hdmiEveryCycle ? 1 : 0} hdmi_assert=${cfg.hdmiAssertMode} ` +
      `run_id=${runCorr.runId}`
  );
  log(
    'CYCLE_ISOLATION=on each cycle force-stops then plays from beginning ' +
      '(seek@8s residual from prior cycle is cleared and reported via CYCLE_START_STATE)'
  );
  log(
    'BOUNDARY_PLAYWRIGHT: asserts Plex Web control-plane + :3005 session state only. ' +
      'Does NOT prove video pixels, overlay resolution, judder, or lipsync. ' +
      'Only parent HDMI-USB capture settles video claims. Present path 529x240 only. ' +
      'PLXD frames/presents/drops VOID on live RBF c5382bee (frames_done=bank_vsync). ' +
      'No companion /status endpoint.'
  );
  log(
    'GLASS_PAIR: watch GLASS_EXPECT/GLASS_JOIN + PAUSE_OVERLAY_WINDOW_* wall_ms; ' +
      'defect_hint=pause_overlay_low_res|play_timeline_overlay_low_res. ' +
      'E2E_GLASS_HOLD=1 to block suite during hold_ms for concurrent capture.'
  );
  if (cfg.liveConf) log(`E2E_LIVE_CONF=${cfg.liveConf}`);
  if (cfg.liveDaemonId) log(`E2E_LIVE_DAEMON_ID=${cfg.liveDaemonId}`);
  log(
    'LIVE_DAEMON_NOTE: suite does not ssh. Process identity is GET /player/telemetry ' +
      'pid= + exe= (daemon readlink /proc/self/exe). NEVER host pidof/cmdline — ' +
      'flock cmdline contains misterplexd (ERROR 14 false zero). Parent conf resolve: ' +
      'readlink -f /proc/$PID/exe and tr \\\\0 \\\\n </proc/$PID/cmdline with PID from telemetry.'
  );
  log(
    `N_LOOP_RULES planned=${total} majority_pass_is_NOT_pass=1 ` +
      `continue_on_fail=${continueOnFail ? 1 : 0} ` +
      `taxonomy=transition_cycle_<N>_<pause|resume|seek|stop|play_idle_play|ledger|pid|cycle_reset>`
  );

  const results = [];
  const failures = [];
  for (let c = 1; c <= total; c++) {
    log(`════════ TRANSITION_CYCLE ${c}/${total} run_id=${runCorr.runId} ════════`);
    // Controller must still be our Playwright page across all N (leak → iteration 7 class).
    if (!page || page.isClosed()) {
      cycleFail(
        c,
        total,
        'controller',
        'controller_closed_mid_nloop',
        `Playwright page closed before cycle ${c}/${total} — controller leak / crash mid N-loop`
      );
    }
    await captureAndAssertPid(`cycle_${c}_begin`, { hardFail: true });
    await runCorr.mark('cycle_start', { cycle: c });
    try {
      const r = await runOneTransitionCycle(page, itemTitle, detailsUrl, c, total);
      results.push(r);
      await runCorr.mark('cycle_ok', { cycle: c });
      await runCorr.joinTelemetry(`cycle_${c}_ok`);
      // Mid-loop controller health (browser still ours).
      if (page.isClosed()) {
        cycleFail(
          c,
          total,
          'controller',
          'controller_closed_after_cycle',
          `page closed after cycle ${c} body — TEARDOWN cannot be deferred to end only`
        );
      }
      log(
        `TRANSITION_CYCLE_OK ${c}/${total} start_time0_ms=${r.startTime0} ` +
          `run_id=${runCorr.runId} pid=${baselineDaemonPid}`
      );
    } catch (e) {
      if (e instanceof FailError) {
        const failedTransition = e.transition || e.reason || 'unknown';
        const taxReason = e.failReason || e.reason;
        const row = {
          cycle: c,
          ok: false,
          reason: taxReason,
          fullReason: e.reason,
          transition: failedTransition,
          detail: e.detail || e.message || '',
        };
        results.push(row);
        failures.push(row);
        await runCorr
          .mark('cycle_fail', {
            cycle: c,
            transition: failedTransition,
            reason: taxReason,
          })
          .catch(() => {});
        log(
          `TRANSITION_CYCLE_FAIL ${c}/${total} transition=${failedTransition} ` +
            `reason=${taxReason} full=${e.reason} run_id=${runCorr.runId} ` +
            `pid=${baselineDaemonPid} passed_so_far=${results.filter((x) => x.ok).length}`
        );
        if (!continueOnFail) {
          log(
            `TRANSITIONS_SUMMARY planned=${total} attempted=${c} pass=${results.filter((x) => x.ok).length} ` +
              `fail=${failures.length} failed_cycle=${c} failed_transition=${failedTransition} ` +
              `abort_early=1 (E2E_TRANSITION_CONTINUE_ON_FAIL=0)`
          );
          // Re-throw so suite is RED with named cycle.
          throw e;
        }
        log(
          `TRANSITION_CONTINUE after fail cycle=${c}/${total} ` +
            `(will still attempt remaining cycles; aggregate PASS requires 0 fails)`
        );
        // Best-effort stop so next cycle reset is clean.
        await forceStopDaemon(`c${c}_after_fail`).catch(() => false);
        await sleep(500);
        continue;
      }
      throw e;
    }
  }

  const passed = results.filter((r) => r.ok).length;
  const failed = failures.length;
  const hdmiOk = results.filter((r) => r.ok && r.hdmi && r.hdmi.enabled && !r.hdmi.skipped).length;

  // Per-cycle table (always full planned N when continue_on_fail).
  // "9/10 passed" is NOT a pass — each FAIL line names cycle + transition + reason.
  log('──────── TRANSITIONS_PER_CYCLE ────────');
  for (const r of results) {
    if (r.ok) {
      log(
        `  cycle ${r.cycle}/${total} PASS start_time0_ms=${r.startTime0} ` +
          `pid=${baselineDaemonPid} transitions=${(r.transitions || []).join(',')}`
      );
    } else {
      log(
        `  cycle ${r.cycle}/${total} FAIL transition=${r.transition} reason=${r.reason} ` +
          `detail=${String(r.detail || '').replace(/\s+/g, ' ').slice(0, 160)}`
      );
    }
  }
  log(
    `TRANSITIONS_SUMMARY planned=${total} attempted=${results.length} pass=${passed} fail=${failed} ` +
      `hdmi_scored=${hdmiOk} shortened=${results.length < total ? 1 : 0} ` +
      `daemon_pid=${baselineDaemonPid > 0 ? baselineDaemonPid : 'NA'} ` +
      `majority_pass_is_pass=0`
  );
  // Per-cycle distribution (S6) — never collapse to majority-only.
  for (const r of results) {
    if (r.ok) {
      log(
        `TRANSITION_CYCLE_ROW cycle=${r.cycle}/${total} result=PASS ` +
          `start_time0_ms=${r.startTime0 != null ? r.startTime0 : 'NA'} ` +
          `glass=${r.hdmi && r.hdmi.glassOk != null ? (r.hdmi.glassOk ? 1 : 0) : 'NA'}`
      );
    } else {
      log(
        `TRANSITION_CYCLE_ROW cycle=${r.cycle}/${total} result=FAIL ` +
          `transition=${r.transition || '?'} reason=${r.reason || r.fullReason || '?'} ` +
          `detail=${String(r.detail || '')
            .replace(/\s+/g, ' ')
            .slice(0, 120)}`
      );
    }
  }
  log(
    `TRANSITION_DISTRIBUTION pass=${passed} fail=${failed} rate_fail=${
      total > 0 ? (failed / total).toFixed(3) : 'NA'
    } pass_eq_N=${passed === total && failed === 0 ? 1 : 0}`
  );

  if (failed > 0 || passed !== total || results.length !== total) {
    const first = failures[0];
    const named = first
      ? `first_fail cycle=${first.cycle} transition=${first.transition} reason=${first.reason}`
      : `attempted=${results.length} planned=${total}`;
    fail(
      first ? first.fullReason || first.reason : 'transitions_incomplete',
      `TRANSITIONS aggregate RED: pass=${passed}/${total} fail=${failed} ` +
        `(majority is NOT a pass). ${named}\n` +
        failures
          .map(
            (f) =>
              `  - cycle ${f.cycle}/${total}: transition=${f.transition} reason=${f.reason}` +
              (f.detail ? ` | ${String(f.detail).replace(/\s+/g, ' ').slice(0, 120)}` : '')
          )
          .join('\n')
    );
  }

  // Final PID gate after full N (respawn on last cycle must not hide).
  await captureAndAssertPid('nloop_end', { hardFail: true });

  log(
    `TRANSITIONS_OK cycles=${total}/${total} pause resume seek stop play_idle_play ` +
      `hdmi_scored=${hdmiOk} daemon_pid=${baselineDaemonPid} ` +
      `exe=${(baselineDaemonExe || '').replace(/^.*\//, '') || 'NA'}`
  );
  return {
    enabled: true,
    cycles: total,
    passed,
    failed: 0,
    results,
  };
}

(async () => {
  log('test_cast_picker_playwright: BEGIN');
  runCorr.emitBanner();
  await runCorr.mark('suite_begin');
  runCorr.persist(cfg.outDir);
  log(`conf=${cfg.confPath} library=${cfg.libraryName} cast=${cfg.castName}`);
  log(
    `tiers=${(cfg.tiers || []).map((t) => t.name).join(',') || '(none)'} ` +
      `content=${cfg.contentMode} transitions=${cfg.transitions ? 1 : 0} ` +
      `cycles=${cfg.transitionCycles} hdmi=${cfg.hdmiMotion ? 1 : 0} run_id=${runCorr.runId}`
  );
  log(
    'NO_LIPSYNC_ASSERT: suite never gates on av-lock/av_drift_ms; A/V bimodal offset is ' +
      'parent HDMI-only (tools/avsync_measure_hdmi.py).'
  );

  if (cfg.tierResolveError) {
    fail('bad_e2e_tier', cfg.tierResolveError);
  }
  if (cfg.isRealContent) {
    log(
      'CONTENT=real — discover non-fixture non-bank library_media at runtime ' +
        '(or PLEX_RATING_KEY). Never silent fixture fallback. ' +
        `HDMI assert_mode=${cfg.hdmiAssertMode}; rc=77 UNSCORED is hard FAIL when HDMI on.`
    );
  }
  if (!cfg.tiers || !cfg.tiers.length) {
    fail('bad_e2e_tier', 'No tiers resolved — set E2E_TIER=240p|480p|all');
  }

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
    // PLEX_BASE is set but PMS/Web is not usable — UNVERIFIED (rc=2), never PASS.
    // Missing token/chromium stays SKIP(77). Prove path: prove_red_paths.js P2.
    unresolved(
      'PMS_UNREACHABLE',
      `Plex Web unreachable at ${cfg.plexBase}/web/index.html HTTP ${web.status}. ` +
        'CAST_PICKER_E2E_RESULT=UNVERIFIED — cannot claim cast lifecycle without a reachable local PMS.'
    );
  }

  const idn = await pmsIdentity();
  log(
    `pms_identity status=${idn.status} friendlyName=${idn.friendlyName || '?'} machineId=${idn.machineId || '?'}`
  );
  if (idn.status < 200 || idn.status >= 400 || !idn.machineId) {
    unresolved(
      'PMS_IDENTITY_UNVERIFIED',
      `GET ${cfg.plexBase}/identity status=${idn.status} machineId=${idn.machineId || '(empty)'}. ` +
        'Cannot bind details URL or trust companion without PMS identity.'
    );
  }

  // Prefs FriendlyName (identity XML often omits it)
  const prefs = await httpGet(`${cfg.plexBase}/:/prefs`, { 'X-Plex-Token': cfg.token });
  const prefName = (prefs.body.match(/id="FriendlyName"[^>]*value="([^"]*)"/) || [])[1] || '';
  log(`pms_friendlyName_pref=${prefName || '(blank)'}`);

  const baseTl = await pollDaemonTimeline(nextSuiteCmd());
  const daemonUp = baseTl.includes('Timeline') || baseTl.includes('MediaContainer');
  // Default: daemon required for any lifecycle claim (play/pause/seek). Opt out only for
  // picker-only dry runs via E2E_REQUIRE_DAEMON=0 (still never green on play asserts).
  const requireDaemon =
    process.env.E2E_REQUIRE_DAEMON === undefined || process.env.E2E_REQUIRE_DAEMON === ''
      ? true
      : /^(1|true|yes|on)$/i.test(String(process.env.E2E_REQUIRE_DAEMON));
  if (!daemonUp) {
    if (requireDaemon) {
      fail(
        'daemon_unreachable',
        `Companion timeline not reachable at ${daemonBase(cfg)} (no Timeline/MediaContainer). ` +
          'Gate is RED when daemon is down — prove with MISTER_PORT=1 or prove_red_paths.js P1. ' +
          'Set E2E_REQUIRE_DAEMON=0 only for picker-only experiments (playback still fails if down).'
      );
    }
    log(
      `WARN daemon timeline not reachable at ${daemonBase(cfg)} — E2E_REQUIRE_DAEMON=0; ` +
        'picker may still run; playback assert will FAIL if still down'
    );
  } else {
    log(`daemon_ok ${daemonBase(cfg)}`);
    await forceStopDaemon('preflight');
  }

  // Baseline daemon PID before UI work — must stay constant for the whole run.
  await captureAndAssertPid('preflight', { hardFail: false });
  if (baselineDaemonPid > 0) {
    log(`DAEMON_PID_TRACKING=on baseline=${baselineDaemonPid} E2E_REQUIRE_PID=${process.env.E2E_REQUIRE_PID || '1'}`);
  } else {
    log(
      `DAEMON_PID_TRACKING=unprobed (need /player/telemetry pid= from deployed daemon) ` +
        `E2E_REQUIRE_PID=${process.env.E2E_REQUIRE_PID || '1'}`
    );
  }

  // Fail loud on tier/conf before paying for Chromium when probe is required.
  for (const tier of cfg.tiers) {
    assertDaemonTier(tier);
    log(
      `tier_plan name=${tier.name} rk=${tier.ratingKey} title=${JSON.stringify(tier.itemTitle)} ` +
        `arm=${tier.contentArm || '?'} expectDecode=${tier.expectDecode}`
    );
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
  let lastRatingKey = '';
  let lastTierName = '';
  let summaryBits = [];

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

    const serverSeg = idn.machineId || 'auto';

    for (const tier of cfg.tiers) {
      lastTierName = tier.name;
      log(`──────── TIER_BEGIN ${tier.name} ────────`);

      const item = await resolveItemForTier(tier);
      const ratingKey = item.ratingKey;
      lastRatingKey = ratingKey;
      const itemTitle = item.title;
      const metaKey = `/library/metadata/${ratingKey}`;
      const detailsUrl = `${cfg.plexBase}/web/index.html#!/server/${serverSeg}/details?key=${encodeURIComponent(
        metaKey
      )}`;
      log(`item_title=${itemTitle} ratingKey=${ratingKey} tier=${tier.name}`);

      // ── 2. Open test item ─────────────────────────────────────────────────
      log(`goto details key=${metaKey}`);
      await page.goto(detailsUrl, { waitUntil: 'domcontentloaded', timeout: cfg.timeoutMs });
      const picker2 = await dismissUserPicker(page, cfg.webUser);
      if (picker2.shown && picker2.picked) log(`user_picker re-dismissed profile=${picker2.picked}`);
      if (picker2.shown && !picker2.picked) {
        await shot(page, `fail_user_picker_after_details_${tier.name}`);
        fail('plex_home_user_picker_not_dismissed', 'Select User still showing after details navigation.');
      }
      log(`at ${page.url()}`);

      const detailsReady = await waitForDetailsReady(page, itemTitle, Math.max(cfg.timeoutMs, 90000));
      await shot(page, `01_details_${tier.name}`);
      log(`details_ready_ok playSel=${detailsReady.playSel || '-'}`);

      // ── 3. Select Player — BEFORE snapshot, then open, then DIFF ──────────
      const ctl = await waitForSelectPlayerControl(page, 45000);
      if (ctl.kind === 'user_picker') {
        const again = await dismissUserPicker(page, cfg.webUser);
        if (!again.picked && again.shown) {
          await shot(page, `fail_user_picker_before_cast_${tier.name}`);
          fail('plex_home_user_picker_not_dismissed', 'Select User reappeared before cast control.');
        }
      }

      const beforePicker = await bodyLineSet(page);
      log(`body_lines_before_picker=${beforePicker.size}`);
      if (beforePicker.size < 8) {
        await shot(page, `fail_details_empty_before_picker_${tier.name}`);
        fail(
          'details_body_empty_before_picker',
          `Details-ready passed but body had only ${beforePicker.size} lines; cannot trust picker diff.`
        );
      }
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
        await shot(page, `fail_no_select_player_control_${tier.name}`);
        const body = await pageBodyText(page, 400);
        fail(
          'select_player_control_not_found',
          'Could not find Select Player control (a[aria-label="Select Player"] / button[aria-label=...]) on the details page. ' +
            `body_sample=${JSON.stringify(body.slice(0, 200))}`
        );
      }

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
        if (tracker.discovery.length) await page.waitForTimeout(800);
        else await page.waitForTimeout(2500);
      }
      await shot(page, `02_picker_open_${tier.name}`);

      const companion = await assertCompanionServer(tracker);

      const target = await assertMisterplexInPickerDiff(page, beforePicker);
      const clickedText = ((await target.innerText().catch(() => '')) || '').trim().split('\n')[0].trim();
      const exactNameRe = new RegExp(
        `^${cfg.castName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`,
        'i'
      );
      if (clickedText && !exactNameRe.test(clickedText) && clickedText !== cfg.castName) {
        await shot(page, `fail_picker_clicked_ghost_${tier.name}`);
        fail(
          'picker_clicked_non_exact_target',
          `Refusing to click ghost/near-miss label ${JSON.stringify(clickedText)}; want exact ${JSON.stringify(cfg.castName)}`
        );
      }
      await target.click();
      log(
        `selected_cast_target exact=${cfg.castName} clicked_text=${JSON.stringify(clickedText || cfg.castName)}`
      );
      await glassMark(0, 'discovery', 'after', {
        picture: 'picker_ui',
        counter: 'na',
        note: 'Web picker selected exact MiSTerPlex — device glass unchanged until Play',
        hold_ms: 1000,
      });
      await shot(page, `03_target_selected_${tier.name}`);

      // ── 4. Play ───────────────────────────────────────────────────────────
      const afterCast = await waitForDetailsReady(page, itemTitle, 60000);
      const played = await clickPlay(page, afterCast.playSel || detailsReady.playSel);
      if (!played) {
        await shot(page, `fail_no_play_button_${tier.name}`);
        const body = await pageBodyText(page, 400);
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
      await shot(page, `04_play_clicked_${tier.name}`);

      if (!daemonUp) {
        const againTl = await pollDaemonTimeline(nextSuiteCmd());
        if (!(againTl.includes('Timeline') || againTl.includes('MediaContainer'))) {
          await shot(page, `fail_daemon_down_after_play_${tier.name}`);
          fail(
            'daemon_unreachable',
            `Play was clicked in Plex Web but companion at ${daemonBase(cfg)} is unreachable — cannot confirm playing state.`
          );
        }
      }

      let prog = await waitPlayingOnDaemon(cfg.playWaitSec);
      if (prog.playing < 2) {
        log(
          `playing_retry buffering=${prog.buffering || 0} samples=${prog.playing} — ` +
            're-click Play once (cast sticky)'
        );
        await handleResumeDialog(page);
        await clickPlay(page, afterCast.playSel || detailsReady.playSel);
        await handleResumeDialog(page);
        prog = await waitPlayingOnDaemon(cfg.playWaitSec);
      }
      if (prog.playing < 2) {
        await shot(page, `fail_not_playing_${tier.name}`);
        fail(
          'playback_did_not_start',
          `UI play clicked but daemon timeline never stayed in state=playing ` +
            `(playing_samples=${prog.playing} buffering_samples=${prog.buffering || 0} ` +
            `time_max_ms=${prog.maxT}). ` +
            `Picker contained ${cfg.castName}; companion=${(companion.hosts || []).join(',')}; ` +
            'failure is post-select playback.'
        );
      }
      log(
        `playing_ok samples=${prog.playing} advance=${prog.advance} time_max_ms=${prog.maxT} ` +
          `run_id=${runCorr.runId}`
      );
      {
        // Control-plane truthfulness: UI clock vs daemon (parent measured glass ~0:34/6:00).
        const uiR = await assertUiMatchesDaemon(page, `tier_${tier.name}_playing_ui_clock`);
        if (!uiR.ok && !uiR.softSkip) {
          fail(uiR.reason || 'ui_daemon_timeline_skew', uiR.detail || '');
        }
        if (uiR.ok && !uiR.softSkip) {
          log(`UI_TIMELINE_TRUTHFUL=1 tier=${tier.name}`);
        }
      }
      await runCorr.mark('playing_ok', {
        tier: tier.name,
        ratingKey: String(ratingKey),
      });
      await runCorr.joinTelemetry(`tier_${tier.name}_playing_ok`);
      runCorr.persist(cfg.outDir);
      await captureAndAssertPid(`tier_${tier.name}_playing_ok`, { hardFail: true });

      // Optional glass score on parent-provided capture (no grabber). Timeline-only
      // PASS is blind to ~1.5% display loss — when dir set or requireGlass, score it.
      if (cfg.glassCaptureDir) {
        log(
          `GLASS_CAPTURE_DIR=${cfg.glassCaptureDir} max_loss_pct=${cfg.glassMaxLossPct} ` +
            `require=${cfg.requireGlass ? 1 : 0} (w-instr template counter + gap loss%)`
        );
        scoreHdmiCaptureDir(cfg.glassCaptureDir, `glass_provided_${tier.name}`);
      } else if (cfg.requireGlass && !cfg.hdmiMotion) {
        fail(
          'glass_capture_required',
          'E2E_REQUIRE_GLASS=1 but neither E2E_GLASS_CAPTURE_DIR nor E2E_HDMI_MOTION=1 set. ' +
            'Parent must provide a capture dir (suite does not open /dev/video0). ' +
            'Timeline advance alone must not green-wash display-side frame loss.'
        );
      } else if (!cfg.hdmiMotion) {
        log(
          'GLASS_NOT_SCORED=1 — timeline/control-plane only. NOT a pass of glass integrity. ' +
            'Set E2E_GLASS_CAPTURE_DIR or E2E_HDMI_MOTION=1 + parent capture to gate ~1.5% loss class.'
        );
      }


      // ── 4b. Transitions (pause/resume, seek, stop+recast, play→idle→play) ─
      // Per-tier capture base so 240p/480p frames do not mix when E2E_TIER=all.
      const hdmiDirBase = cfg.hdmiCaptureDir;
      if (cfg.hdmiMotion && cfg.tiers.length > 1) {
        cfg.hdmiCaptureDir = `${String(hdmiDirBase).replace(/\/$/, '')}_${tier.name}`;
      }
      // Transitions include multi-cycle stress + per-cycle HDMI (when enabled).
      const tr = await runTransitionScenarios(page, itemTitle, detailsUrl, true);
      // Discovery recheck (picker still lists exact target). Cold-start is the first
      // picker open above; this catches mid-run disappearance. After parent daemon
      // restart, re-run the full suite — suite does not restart the daemon.
      if (/^(1|true|yes|on)$/i.test(String(process.env.E2E_DISCOVERY_RECHECK || '1'))) {
        await dismissFullPlayerOverlay(page);
        await gotoDetailsClean(page, detailsUrl, itemTitle);
        await recheckDiscoveryPicker(page, itemTitle, `tier_${tier.name}_post_transitions`);
      }
      // If transitions off, still allow a single HDMI stage on the playing session.
      let hdmi = { enabled: false };
      if (!tr.enabled && cfg.hdmiMotion) {
        hdmi = await optionalHdmiMotionStage(1, 1);
      } else if (tr.enabled) {
        hdmi = { enabled: !!(tr.results || []).some((r) => r.hdmi && r.hdmi.enabled) };
      }
      cfg.hdmiCaptureDir = hdmiDirBase;

      // ── 4c. Optional long hold for parent multi-capture (session-latched A/V) ─
      // Must run BEFORE final stop so one continuous session is available.
      const hold = await runSessionHold(tier, ratingKey);
      if (hold.enabled) {
        summaryBits.push(`hold=${hold.holdSec}s/session=${hold.session || 'NA'}`);
      }

      // ── 5. Final stop for this tier (UI best-effort + HTTP) ───────────────
      const toggled = await clickPauseOrPlayToggle(page);
      if (toggled) {
        log(`pause_or_toggle ${toggled}`);
        await page.waitForTimeout(800);
        const xml = await pollDaemonTimeline(nextSuiteCmd());
        log(`after_toggle state=${xmlAttr(xml, 'state') || '?'}`);
      } else {
        log('pause_control_not_found (non-fatal)');
      }

      const stopped = await clickStop(page);
      if (!stopped) {
        await forceStopDaemon('tier_stop_fallback');
        log('stop_ui_failed_used_http_fallback');
      }
      await page.waitForTimeout(500);
      const afterStop = await pollDaemonTimeline(nextSuiteCmd());
      log(`after_stop state=${xmlAttr(afterStop, 'state') || '?'}`);
      {
        const p4samples = await sampleTimeline(5, 350, `tier_${tier.name}_p4_stop`);
        await assertP4DeviceIdle(`tier_${tier.name}_stop`, p4samples);
      }
      await shot(page, `05_stopped_${tier.name}`);

      summaryBits.push(
        `tier=${tier.name}/rk=${ratingKey}/play=ok` +
          `/tr=${tr.enabled ? 'ok' : 'off'}` +
          `/cycles=${tr.cycles || 0}/${tr.passed || 0}` +
          `/hdmi=${hdmi.enabled ? 'ok' : 'off'}` +
          `/content=${cfg.contentMode}` +
          `/companion=${(companion.matched || companion.hosts || []).join(',') || 'ok'}`
      );
      log(`TIER_OK ${tier.name} ${summaryBits[summaryBits.length - 1]}`);
    }

    // Always return daemon to idle for daily driver (UI stop may have been last tier only).
    await forceStopDaemon('suite_end_idle').catch(() => false);
    await glassMark(0, 'idle', 'after', {
      picture: 'idle_logo',
      counter: 'na',
      note: 'suite complete — device idle for daily driver',
      hold_ms: 1000,
    });
    await assertP4DeviceIdle('suite_end');

    suitePassed = true;
    log(
      `suite_body_ok ${summaryBits.join(' ')} cast=${cfg.castName} context_requests=${tracker.all.length}`
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
      reason: 'teardown_error',
      state: 'teardown_error',
      err: te.message,
    }));
  }

  if (bodyError) {
    try {
      tlSeries.summary();
    } catch (_) {
      /* ignore */
    }
    process.exit(bodyError.exitCode || EXIT_FAIL);
  }

  if (suitePassed && teardownResult && !teardownResult.ok) {
    console.error('FAIL test_cast_picker_playwright: teardown_controller_not_closed');
    console.error(
      'Suite body passed but OUR Playwright controller was not fully closed.\n' +
        `reason=${teardownResult.reason || '?'} state=${teardownResult.state || '?'} ` +
        `err=${teardownResult.err || ''}\n` +
        'Teardown only requires THIS suite browser gone — not a globally idle daemon ' +
        '(a permanent user Plex Web tab may still poll).'
    );
    process.exit(EXIT_FAIL);
  }
  if (suitePassed && teardownResult && teardownResult.ok) {
    // Final PID check — catch respawn during last cycle / teardown window.
    try {
      await captureAndAssertPid('suite_end', { hardFail: true });
    } catch (pe) {
      if (pe instanceof FailError) {
        console.error(`FAIL test_cast_picker_playwright: ${pe.reason}`);
        if (pe.detail) console.error(pe.detail);
        process.exit(pe.exitCode || EXIT_FAIL);
      }
      throw pe;
    }
    await runCorr.mark('suite_pass').catch(() => {});
    runCorr.persist(cfg.outDir);
    const seriesSum = tlSeries.summary();
    log('CAST_PICKER_E2E_RESULT=PASS');
    log(
      `summary ${summaryBits.join(' ') || 'ok'} teardown=ok cast=${cfg.castName} ` +
        `lastTier=${lastTierName} lastRatingKey=${lastRatingKey} run_id=${runCorr.runId} ` +
        `daemon_pid=${baselineDaemonPid > 0 ? baselineDaemonPid : 'NA'} ` +
        `timeline_samples=${seriesSum.n}`
    );
    log(
      `E2E_RUN_ID=${runCorr.runId} — parent: grep e2e_mark run_id=${runCorr.runId} then origin lines`
    );
    log(
      `TIMELINE_JOIN file=${seriesSum.file || 'NA'} n=${seriesSum.n} ` +
        `fields=host_wall_ms,host_wall_iso,plex_time_ms,state — align to HDMI capture wall windows`
    );
    log(
      `DAEMON_PID_STABLE=1 pid=${baselineDaemonPid > 0 ? baselineDaemonPid : 'NA'} ` +
        `exe=${baselineDaemonExe || 'NA'} ` +
        `(unchanged across full N-loop; identity=telemetry readlink/proc/self/exe; ` +
        `self-exit rc=0 → daemon_pid_changed RED — never host pidof/cmdline)`
    );
    process.exitCode = EXIT_PASS;
    return;
  }
  process.exit(EXIT_FAIL);
})().catch((e) => {
  // fail()/unresolved() before the inner try/finally — honor exitCode (1 or 2), never 77-as-pass.
  if (e instanceof FailError) {
    try {
      tlSeries.summary();
    } catch (_) {
      /* ignore */
    }
    process.exit(e.exitCode || EXIT_FAIL);
  }
  console.error(`UNHANDLED: ${redact(e.message || e)}`);
  try {
    http
      .get(
        `${daemonBase(cfg)}/player/playback/stop?commandID=${SUITE_CMD_BASE + 999}`,
        { timeout: 2000 },
        (res) => res.resume()
      )
      .on('error', () => {});
  } catch (_) {
    /* ignore */
  }
  process.exit(EXIT_SKIP);
});
