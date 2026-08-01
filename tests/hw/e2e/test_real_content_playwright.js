#!/usr/bin/env node
/**
 * test_real_content_playwright.js — P7 real-content cast gate
 *
 * Discovers a NON-FIXTURE title on LOCAL PMS, casts it to MiSTerPlex via the
 * real Plex Web UI, asserts timeline advance, prints the geometry chain, and
 * holds for parent HDMI capture. Never silently falls back to lab fixtures.
 *
 * Exit: 0 PASS | 1 FAIL | 77 SKIP-NOT-PASS (missing deps/env only)
 *
 *   E2E_CONTENT is implied real. LOCAL PLEX_BASE only.
 *   Ignore SHIELD / plex.nevertrustaf.art.
 */

'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { spawnSync } = require('child_process');
const { loadConfig, daemonBase, redact, ROOT, parentConfCommands, normalizeDecode } =
  require('./conf');
const {
  discoverRealTitle,
  geometryChain,
  isFixtureMeta,
  isBankGeometry,
  mediaInfo,
} = require('./discover_real');

const EXIT_PASS = 0;
const EXIT_FAIL = 1;
const EXIT_SKIP = 77;

// Force real-content mode for conf defaults that key off E2E_CONTENT.
if (!process.env.E2E_CONTENT && !process.env.E2E_CONTENT_MODE) {
  process.env.E2E_CONTENT = 'real';
}
// Discovery suite: transitions off by default (parent holds for pixels).
if (process.env.E2E_TRANSITIONS === undefined) process.env.E2E_TRANSITIONS = '0';

const cfg = loadConfig();

function log(...a) {
  console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : x)));
}

function skip(reason) {
  console.error(`SKIP-NOT-PASS test_real_content_playwright: ${reason}`);
  process.exit(EXIT_SKIP);
}

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
  console.error(`FAIL test_real_content_playwright: ${reason}`);
  if (detail) console.error(detail);
  throw new FailError(reason, detail);
}

function ensureOutDir() {
  fs.mkdirSync(cfg.outDir, { recursive: true });
}

async function shot(page, name) {
  try {
    ensureOutDir();
    const pth = path.join(cfg.outDir, `${name}.png`);
    await page.screenshot({ path: pth, fullPage: true });
    log(`screenshot ${pth}`);
    return pth;
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

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
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

const SUITE_CMD_BASE = 52000 + (process.pid % 400) * 20;
let suiteCmdSeq = 0;
function nextSuiteCmd() {
  return SUITE_CMD_BASE + (suiteCmdSeq++ % 500);
}

async function pollDaemonTimeline(cmdId) {
  const r = await httpGet(
    `${daemonBase(cfg)}/player/timeline/poll?commandID=${cmdId}&wait=0`,
    {},
    4000
  );
  return r.body || '';
}

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

async function closeBrowserController(page, context, browser) {
  let closed = true;
  try {
    if (page && !page.isClosed()) {
      await page.goto('about:blank', { waitUntil: 'domcontentloaded', timeout: 5000 }).catch(() => {});
      await page.close({ runBeforeUnload: false }).catch(() => {});
    }
  } catch (_) {
    closed = false;
  }
  try {
    if (context) await context.close();
  } catch (_) {
    closed = false;
  }
  try {
    if (browser) await browser.close();
  } catch (_) {
    closed = false;
  }
  log(`browser_controller_closed ok=${closed ? 1 : 0}`);
  return closed;
}

async function hardTeardown(page, context, browser) {
  await unsubscribeDaemon('teardown').catch(() => false);
  const stopOk = await forceStopDaemon('teardown').catch(() => false);
  const browserClosed = await closeBrowserController(page, context, browser);
  await sleep(800);
  await forceStopDaemon('teardown_post_browser').catch(() => false);
  if (!browserClosed) {
    log('TEARDOWN_DIRTY reason=browser_not_closed');
    return { ok: false, reason: 'browser_not_closed', stopOk };
  }
  log(`TEARDOWN_OK controller=closed browser=closed stop_ok=${stopOk ? 1 : 0}`);
  return { ok: true, stopOk };
}

async function pmsIdentity() {
  const r = await httpGet(`${cfg.plexBase}/identity`, { Accept: 'application/xml' });
  const machineId = xmlAttr(r.body, 'machineIdentifier') || '';
  const friendlyName = xmlAttr(r.body, 'friendlyName') || '';
  return { status: r.status, machineId, friendlyName, body: r.body };
}

/** Explicit ratingKey path — still reject fixtures. */
async function resolveExplicitRealItem(ratingKey) {
  const headers = { 'X-Plex-Token': cfg.token, Accept: 'application/json' };
  const rk = String(ratingKey).replace(/^\/library\/metadata\//, '');
  const meta = await httpGet(`${cfg.plexBase}/library/metadata/${rk}`, headers);
  if (meta.status !== 200) {
    fail('real_content_rating_key_unreachable', `HTTP ${meta.status} metadata/${rk}`);
  }
  let j;
  try {
    j = JSON.parse(meta.body);
  } catch (_) {
    fail('real_content_metadata_bad_json', rk);
  }
  const m = (j.MediaContainer?.Metadata || [])[0];
  if (!m) fail('real_content_metadata_empty', rk);
  const sectionTitle = m.librarySectionTitle || '';
  if (isFixtureMeta(m, sectionTitle)) {
    fail(
      'real_content_is_fixture',
      `ratingKey=${rk} title=${JSON.stringify(m.title)} section=${JSON.stringify(sectionTitle)} ` +
        'is a lab fixture. P7 requires genuine library content — refuse fixture fallback.'
    );
  }
  const mi = mediaInfo(m);
  const allowBank = /^(1|true|yes|on)$/i.test(String(process.env.E2E_REAL_ALLOW_BANK_GEOM || ''));
  if (!allowBank && isBankGeometry(mi.width, mi.height)) {
    fail(
      'real_content_bank_geometry',
      `ratingKey=${rk} title=${JSON.stringify(m.title)} library_media=${mi.width}x${mi.height} ` +
        'is bank-sized (320x240 or 624x480). P7 requires non-bank geometry so scale/AR paths run. ' +
        'Override only with E2E_REAL_ALLOW_BANK_GEOM=1.'
    );
  }
  if (!allowBank && (!mi.width || !mi.height)) {
    fail(
      'real_content_unknown_geometry',
      `ratingKey=${rk} has no library_media width/height — cannot prove non-bank geometry.`
    );
  }
  return {
    ratingKey: rk,
    title: String(m.title || ''),
    sectionTitle,
    sectionKey: String(m.librarySectionID || ''),
    ...mi,
    score: 0,
  };
}

// ── minimal Playwright helpers (same traps as cast-picker suite) ──────────

async function pageBodyText(page, n = 800) {
  try {
    const t = await page.locator('body').innerText({ timeout: 5000 });
    return String(t).slice(0, n);
  } catch (_) {
    return '';
  }
}

async function bodyLineSet(page) {
  const t = await pageBodyText(page, 12000);
  return new Set(
    t
      .split('\n')
      .map((l) => l.trim())
      .filter(Boolean)
  );
}

async function dismissUserPicker(page, preferred) {
  // Reuse strategy: click avatar ~40px above profile label.
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    const body = await pageBodyText(page, 400);
    if (/select user/i.test(body) || (await page.locator('text=Select User').count().catch(() => 0))) {
      const names = [];
      const labels = page.locator('[class*="User"], button, a').filter({ hasText: /.+/ });
      // Prefer named profile via mouse above text
      const target = preferred || '';
      if (target) {
        const loc = page.getByText(target, { exact: true }).first();
        try {
          if (await loc.isVisible({ timeout: 1500 })) {
            const box = await loc.boundingBox();
            if (box) {
              await page.mouse.click(box.x + box.width / 2, box.y - 40);
              log(`user_picker click_method=mouse_avatar_dy40 picked=${target}`);
              await sleep(2000);
              return { shown: true, picked: target, phase: 'shell' };
            }
          }
        } catch (_) {
          /* fall through */
        }
      }
      // first visible profile-like text
      try {
        await page.locator('text=Select User').first().waitFor({ state: 'visible', timeout: 1000 });
      } catch (_) {
        return { shown: false, phase: 'shell' };
      }
      const cand = page.locator('div,button,a').filter({ hasText: /^[A-Za-z][A-Za-z0-9 _.-]{1,24}$/ });
      const n = await cand.count();
      for (let i = 0; i < Math.min(n, 20); i++) {
        const el = cand.nth(i);
        const tx = ((await el.innerText().catch(() => '')) || '').trim().split('\n')[0];
        if (!tx || /select user|sign out|admin/i.test(tx)) continue;
        names.push(tx);
        const box = await el.boundingBox().catch(() => null);
        if (box && box.y > 80) {
          await page.mouse.click(box.x + box.width / 2, box.y - 40);
          log(`user_picker click_method=mouse_avatar_dy40 picked=${tx}`);
          await sleep(2000);
          return { shown: true, picked: tx, phase: 'shell', names };
        }
      }
      return { shown: true, picked: '', phase: 'picker', names };
    }
    // shell already?
    if (await page.locator('a[aria-label="Select Player"], button[aria-label="Select Player"]').count()) {
      return { shown: false, phase: 'shell' };
    }
    await sleep(500);
  }
  return { shown: false, phase: 'timeout' };
}

const PLAY_SELECTORS = [
  '[data-testid="preplay-play"]',
  'button[aria-label="Play"]',
  'button[data-testid="play-button"]',
  'button:has-text("Play")',
];

async function waitForDetailsReady(page, itemTitle, maxMs = 90000) {
  const deadline = Date.now() + maxMs;
  let sawTitle = false;
  let playSel = '';
  while (Date.now() < deadline) {
    const body = await pageBodyText(page, 2000);
    if (itemTitle && body.includes(itemTitle.split('(')[0].trim().slice(0, 24))) sawTitle = true;
    for (const sel of PLAY_SELECTORS) {
      const loc = page.locator(sel).first();
      try {
        if (await loc.isVisible({ timeout: 400 })) {
          playSel = sel;
          log(`details_ready title=${sawTitle ? 1 : 0} play_selector=${sel}`);
          return { sawTitle, playSel };
        }
      } catch (_) {
        /* next */
      }
    }
    await sleep(400);
  }
  fail(
    'details_never_rendered',
    `Item details never ready for title~${JSON.stringify(itemTitle)}`
  );
}

async function waitForSelectPlayerControl(page, maxMs = 60000) {
  const sels = [
    'a[aria-label="Select Player"]',
    'button[aria-label="Select Player"]',
    '[aria-label="Select Player"]',
  ];
  const deadline = Date.now() + maxMs;
  while (Date.now() < deadline) {
    for (const sel of sels) {
      const el = page.locator(sel).first();
      try {
        if (await el.isVisible({ timeout: 300 })) return { kind: 'ok', sel, el };
      } catch (_) {
        /* next */
      }
    }
    await sleep(300);
  }
  return { kind: 'missing' };
}

async function assertMisterplexInPickerDiff(page, beforeSet) {
  const after = await bodyLineSet(page);
  const added = [...after].filter((l) => !beforeSet.has(l));
  log(`picker_added_line_count=${added.length}`);
  for (const l of added.slice(0, 12)) log(`  picker+ ${l.slice(0, 80)}`);
  const exactName = cfg.castName;
  const exactRe = new RegExp(`^${exactName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'i');
  const exactLines = added.filter((l) => exactRe.test(l.trim()));
  const ghosts = added.filter(
    (l) => /misterplex/i.test(l) && !exactRe.test(l.trim()) && !/^cast/i.test(l.trim())
  );
  if (ghosts.length) log(`picker_ghost_labels=${ghosts.join(' | ')}`);
  log(
    `MISTERPLEX_IN_PICKER=${exactLines.length > 0} hitExact=${exactLines.length > 0} exact_lines=${exactLines.join('|') || '(none)'}`
  );
  if (!exactLines.length) {
    await shot(page, 'fail_picker_no_misterplex');
    fail(
      'picker_did_not_contain_MiSTerPlex',
      `Select Player opened but exact ${JSON.stringify(exactName)} not in BEFORE/AFTER diff.\n` +
        `Added sample: ${added.slice(0, 8).join(' | ')}`
    );
  }
  // Prefer getByText exact
  const target = page.getByText(exactName, { exact: true }).first();
  await target.waitFor({ state: 'visible', timeout: 5000 });
  log(`picker_click how=getByText exact text=${JSON.stringify(exactName)}`);
  return target;
}

async function clickPlay(page, preferSel) {
  const order = preferSel ? [preferSel, ...PLAY_SELECTORS.filter((s) => s !== preferSel)] : PLAY_SELECTORS;
  for (const sel of order) {
    const loc = page.locator(sel).first();
    try {
      if (await loc.isVisible({ timeout: 800 })) {
        await loc.click({ timeout: 5000 });
        log(`play_button selector=${sel}`);
        return sel;
      }
    } catch (_) {
      /* next */
    }
  }
  return '';
}

async function handleResumeDialog(page) {
  for (const label of ['Resume', 'Play from beginning', 'Start over']) {
    const loc = page.getByRole('button', { name: label }).first();
    try {
      if (await loc.isVisible({ timeout: 800 })) {
        // Prefer start over for deterministic GEOM from t=0
        if (/beginning|start over/i.test(label)) {
          await loc.click();
          log(`resume_dialog clicked=${label}`);
          return;
        }
      }
    } catch (_) {
      /* next */
    }
  }
  // If only Resume is offered, take it.
  try {
    const r = page.getByRole('button', { name: 'Resume' }).first();
    if (await r.isVisible({ timeout: 400 })) {
      await r.click();
      log('resume_dialog clicked=Resume');
    }
  } catch (_) {
    /* none */
  }
}

async function waitPlayingOnDaemon(seconds) {
  const deadline = Date.now() + seconds * 1000;
  let playing = 0;
  let advance = 0;
  let prev = -1;
  let maxT = 0;
  while (Date.now() < deadline) {
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    const state = xmlAttr(xml, 'state');
    const t = parseInt(xmlAttr(xml, 'time') || '-1', 10);
    log(`  timeline state=${state || '?'} time=${xmlAttr(xml, 'time') || '?'}`);
    if (state === 'playing') {
      playing++;
      if (t > prev && prev >= 0) advance++;
      if (t > maxT) maxT = t;
    }
    if (t >= 0) prev = t;
    await sleep(1000);
  }
  return { playing, advance, maxT };
}

function parentHdmiCaptureCmd(dir) {
  const n = Math.max(40, cfg.hdmiWarmupSkip + 30);
  return (
    `mkdir -p ${JSON.stringify(dir)} && rm -f ${JSON.stringify(dir)}/f_*.png && ` +
    `ffmpeg -y -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 ` +
    `-i ${cfg.hdmiVideoDev} -frames:v ${n} ${JSON.stringify(path.join(dir, 'f_%04d.png'))}`
  );
}

function sessionWallThresholdMs() {
  const v = parseInt(process.env.E2E_SESSION_WALL_MS || process.env.E2E_SESSION_TIME_MS || '3000', 10);
  return Number.isFinite(v) && v > 0 ? v : 3000;
}

/**
 * Wait until daemon session is established enough for a non-idle capture.
 * Uses timeline time (proxy for wall_s without SSH). Failures are RED, not skip.
 */
async function waitSessionEstablished(thresholdMs, timeoutSec) {
  const deadline = Date.now() + Math.max(5, timeoutSec) * 1000;
  let maxT = 0;
  let playingHits = 0;
  let lastState = '';
  while (Date.now() < deadline) {
    const xml = await pollDaemonTimeline(nextSuiteCmd());
    const state = xmlAttr(xml, 'state') || '';
    const t = parseInt(xmlAttr(xml, 'time') || '-1', 10);
    lastState = state;
    if (state === 'playing') playingHits++;
    if (t > maxT) maxT = t;
    log(
      `  session_probe state=${state || '?'} time=${xmlAttr(xml, 'time') || '?'} ` +
        `threshold_ms=${thresholdMs} max_t=${maxT}`
    );
    if (state === 'playing' && t >= thresholdMs) {
      return { ok: true, timeMs: t, playingHits, maxT, state };
    }
    await sleep(1000);
  }
  return { ok: false, timeMs: maxT, playingHits, maxT, state: lastState };
}

const {
  resolveMeasuredDelivery,
  assertMeasuredDelivery,
  parseMeasuredDeliveryText,
} = require('./measured_delivery');

/** Parse parent-provided daemon log for MEASURED_DELIVERY / legacy DELIVERED_GEOM. */
function parseDeliveredFromLogText(text, correlationId, ratingKey) {
  const lines = String(text || '').split(/\r?\n/);
  const hits = {
    delivered: null,
    geom: null,
    stream: null,
    wall: null,
    desync_risk: null,
    session_epoch: null,
    correlLines: [],
  };
  const md = parseMeasuredDeliveryText(text);
  if (md && md.delivered_geom) hits.delivered = md.delivered_geom.text;
  if (md) {
    hits.desync_risk = md.desync_risk;
    hits.session_epoch = md.session_epoch;
    if (md.line) hits.geom = md.line;
  }
  const delivRe = /DELIVERED_GEOM\s+stream=(\d+x\d+)/i;
  const geomFullRe = /(?:misterplexd: )?GEOM\s+(.+)/i;
  const streamRe = /Stream\s+#0:0[^\n]*?(\d{2,5})x(\d{2,5})/i;
  const wallRe = /wall_s=([0-9.]+)/i;
  for (const line of lines) {
    if (correlationId && line.includes(correlationId)) hits.correlLines.push(line.slice(0, 240));
    if (ratingKey && line.includes(String(ratingKey)) && /GEOM|playMedia|DELIVERED|MEASURED/i.test(line)) {
      hits.correlLines.push(line.slice(0, 240));
    }
    let m = line.match(delivRe);
    if (m) hits.delivered = hits.delivered || m[1];
    m = line.match(streamRe);
    if (m) hits.stream = `${m[1]}x${m[2]}`;
    m = line.match(wallRe);
    if (m) hits.wall = m[1];
    if (geomFullRe.test(line) && !hits.geom) hits.geom = line.trim().slice(0, 400);
  }
  return hits;
}

async function resolveDeliveredGeometry(correlationId, ratingKey) {
  // Shared resolver: env → E2E_DAEMON_LOG MEASURED_DELIVERY → telemetry.
  const md = await resolveMeasuredDelivery(cfg);
  if (md.ok && md.delivered_geom) {
    log(
      `DELIVERED_GEOM_SOURCE=${md.source} stream=${md.delivered_geom.text} ` +
        `desync_risk=${md.desync_risk != null ? md.desync_risk : 'NA'} ` +
        `session_epoch=${md.session_epoch || 'NA'} value_kind=${md.value_kind || 'measured'}`
    );
    if (md.desync_risk === 1 || md.pipe_desync) {
      fail(
        'pipe_desync_risk',
        `desync_risk=1 delivered=${md.delivered_geom.text} raw=${String(md.raw || '').slice(0, 200)}`
      );
    }
    return {
      ok: true,
      stream: md.delivered_geom.text,
      source: md.source,
      desync_risk: md.desync_risk,
      session_epoch: md.session_epoch,
      md,
    };
  }
  // Legacy correl scrape for parent diagnostics only.
  const logPath = process.env.E2E_DAEMON_LOG || process.env.E2E_DAEMON_LOG_SNIPPET || '';
  if (logPath && fs.existsSync(logPath)) {
    const text = fs.readFileSync(logPath, 'utf8');
    const hits = parseDeliveredFromLogText(text, correlationId, ratingKey);
    log(
      `DELIVERED_GEOM_LOG path=${logPath} delivered=${hits.delivered || '-'} ` +
        `stream=${hits.stream || '-'} wall_s=${hits.wall || '-'} correl_hits=${hits.correlLines.length}`
    );
    for (const c of hits.correlLines.slice(0, 5)) log(`  correl_line: ${c}`);
    const stream = hits.delivered || hits.stream;
    if (stream) return { ok: true, stream, source: 'daemon_log', hits };
    return { ok: false, stream: '', source: 'daemon_log_empty', hits };
  }
  return { ok: false, stream: '', source: md.source || 'unprobed', md };
}

function printParentLogClearRecipe(correlationId) {
  log('──────── PARENT_LOG_CORRELATE (do before/while cast) ────────');
  log(`CAST_CORRELATION_ID=${correlationId}`);
  log('PARENT_LOG_CLEAR_CMD=# on MiSTer — clear BEFORE suite play so GEOM lines are ours:');
  log('#   pid=$(pidof misterplexd | awk "{print \\$1}")');
  log('#   conf=$(tr "\\0" " " < /proc/$pid/cmdline | sed -n "s/.*--conf[= ]\\([^ ]*\\).*/\\1/p")');
  log('#   # Prefer truncating the live log the supervisor uses, e.g.:');
  log('#   : > /media/fat/misterplex/misterplexd.log   # or journal path parent uses');
  log('#   : > /media/usb0/misterplex-lab/logs/ffmpeg.err');
  log('#   date -Is > /tmp/p7-cast-window-start.txt');
  log('# After HOLD, copy log slice for suite assert:');
  log('#   grep -E "GEOM|DELIVERED_GEOM|playMedia|wall_s" /path/to/misterplexd.log | tail -80 \\');
  log('#     > /path/on/host/p7_daemon_snip.txt');
  log('#   export E2E_DAEMON_LOG=/path/on/host/p7_daemon_snip.txt');
  log('#   # or export E2E_DELIVERED_GEOM=1440x1080 after reading media: DELIVERED_GEOM stream=');
  log('NOTE: user long-lived Plex Web tab may also cast — cleared log + correlation ID required.');
  log('──────────────────────────────────────────────────────────');
}

function printParentRecipe(item, geom, correlationId, holdSec, session) {
  const capDir = path.join(String(cfg.hdmiCaptureDir).replace(/\/$/, ''), 'real_p7');
  log('──────── PARENT_RECIPE P7 real-content pixel gate ────────');
  log(`CAST_CORRELATION_ID=${correlationId}`);
  log(`CAST_TITLE=${JSON.stringify(item.title)}`);
  log(`CAST_RATING_KEY=${item.ratingKey}`);
  log(`CAST_LIBRARY_MEDIA=${geom.library_media}`);
  log(`CAST_EXPECT_DECODE_BANK=${geom.expect_decode_bank}`);
  log(`CAST_EXPECTED_DELIVERY=${geom.expected_delivery}  # REQUEST only — not measured`);
  log(`CAST_PATH_GUESS=${geom.path_guess}`);
  log(`CAST_ARM_RESCALE_EXPECTED=${geom.arm_rescale_expected}`);
  log(
    `SESSION_ESTABLISHED time_ms=${session.timeMs} playing_hits=${session.playingHits} ` +
      `threshold_ms=${sessionWallThresholdMs()}`
  );
  log(`HOLD_SEC=${holdSec} — playback held for HDMI grab (session already established)`);
  log(
    'CAPTURE_GATE=ARMED — only capture NOW (not before session). ' +
      'rc=77 UNSCORED from racing idle/pre-play is a parent process error, not a product pass.'
  );
  log(`PARENT_HDMI_CAPTURE_CMD=${parentHdmiCaptureCmd(capDir)}`);
  log(
    `PARENT_HDMI_SCORE_CMD=python3 tools/hdmi_motion_instrument.py ${JSON.stringify(capDir)} ` +
      `--warmup-skip ${cfg.hdmiWarmupSkip} --source-fps ${cfg.hdmiSourceFps} ` +
      `--capture-fps ${cfg.hdmiCaptureFps} --json; echo "true rc=$?"`
  );
  log(
    `PARENT_DAEMON_GEOM_GREP=# correlate ONLY lines after CAST window / cleared log:\n` +
      `#   grep -E "GEOM|DELIVERED_GEOM|playMedia|${item.ratingKey}|wall_s" LIVE_LOG | tail -40\n` +
      `# Expect soon after PLAY_ISSUED:\n` +
      `#   misterplexd: GEOM ... library_media=${geom.library_media} ...\n` +
      `#   media: DELIVERED_GEOM stream=WxH source=ffmpeg.err  (measured; requires daemon with -loglevel info)\n` +
      `#   media: frames=... wall_s=>${(sessionWallThresholdMs() / 1000).toFixed(1)} ...`
  );
  log('FALSIFIABLE_PIXEL_CRITERIA (any one = FAIL):');
  log('  1. WRAP: left/right edges show mirrored or wrapped columns (horizontal wrap)');
  log('  2. H_DUP: frame shows side-by-side duplicated panels / repeated vertical strips');
  log('  3. CHROMA_MAGENTA: flesh/sky tinted magenta-green UV swap or solid green cast');
  log('  4. PILLAR_WRONG: active picture width is ~half or wrong AR vs library_media aspect');
  log('  5. FULLWIDTH_CORRUPT: image stretched to panel with obvious AR smash');
  log('  6. FREEZE: two captures ≥2s apart are pixel-identical while timeline time advances');
  log('PASS hint: recognizable motion + detail from the title; AR consistent with');
  log(`  library_media=${geom.library_media} letterboxed/pillarboxed into the bank`);
  log(`  decode=${geom.expect_decode_bank} without wrap/dup/chroma fail signatures above.`);
  log('NOTE: tools/hdmi_motion_instrument.py counter MOTION_OK will not apply (no TREK overlay).');
  log('  COLOR_FAIL rc=2 / STRUCTURE_FAIL rc=3 / FREEZE rc=1 = hard FAIL.');
  log('  rc=77 UNSCORED on real content = hard FAIL if this gate expected a scored burst');
  log('  (idle/chevron race) — re-capture only after SESSION_ESTABLISHED.');
  log('──────────────────────────────────────────────────────────');
}

async function probeDirectPlayDecision(item) {
  // Best-effort PMS decision probe (does not cast). Helps direct-play scoping.
  if (!item.ratingKey) return null;
  const headers = { 'X-Plex-Token': cfg.token, Accept: 'application/xml' };
  const pathKey = encodeURIComponent(`/library/metadata/${item.ratingKey}`);
  const url =
    `${cfg.plexBase}/video/:/transcode/universal/decision?hasMDE=1&path=${pathKey}` +
    `&mediaIndex=0&partIndex=0&protocol=http&fastSeek=1&directPlay=1&directStream=1` +
    `&videoQuality=100&subtitleSize=100&audioBoost=100&location=lan`;
  const r = await httpGet(url, headers, 10000);
  const body = r.body || '';
  const directPlay =
    /directPlay\s*=\s*"1"|decision\s*=\s*"directplay"|generalDecision="directplay"/i.test(body);
  const transcode = /decision\s*=\s*"transcode"|generalDecision="transcode"/i.test(body);
  log(
    `DIRECTPLAY_PROBE status=${r.status} directPlay_hint=${directPlay ? 1 : 0} ` +
      `transcode_hint=${transcode ? 1 : 0} body_len=${body.length}`
  );
  return { status: r.status, directPlay, transcode, bodyLen: body.length };
}

(async () => {
  log('test_real_content_playwright: BEGIN');
  log(`conf=${cfg.confPath} content=${cfg.contentMode} cast=${cfg.castName}`);
  if (cfg.liveConf) log(`E2E_LIVE_CONF=${cfg.liveConf}`);
  if (cfg.liveDaemonId) log(`E2E_LIVE_DAEMON_ID=${cfg.liveDaemonId}`);
  log(
    'LIVE_DAEMON_NOTE: resolve live conf via /proc/$(pidof misterplexd)/cmdline --conf ' +
      '(two install roots). Suite does not ssh.'
  );

  if (!cfg.plexBase) skip('PLEX_BASE missing');
  if (!cfg.token) skip('PLEX_TOKEN missing');
  if (/plex\.nevertrustaf\.art|32401|shield/i.test(cfg.plexBase)) {
    fail(
      'refusing_non_local_pms',
      `PLEX_BASE=${cfg.plexBase} looks remote/SHIELD. Local PMS only.`
    );
  }

  const web = await httpGet(`${cfg.plexBase}/web/index.html`);
  if (web.status < 200 || web.status >= 400) {
    skip(`Plex Web unreachable HTTP ${web.status}`);
  }

  const idn = await pmsIdentity();
  log(
    `pms_identity status=${idn.status} friendlyName=${idn.friendlyName || '?'} machineId=${idn.machineId || '?'}`
  );

  const tier = (cfg.tiers && cfg.tiers[0]) || {
    name: '240p',
    expectDecode: process.env.E2E_DAEMON_DECODE || '320x240',
  };
  // Emit parent conf for tier (suite never applies).
  const pc = parentConfCommands(tier, cfg.misterHost);
  for (const line of pc.applyText.split('\n')) log(line);
  if (tier.requireDaemonTier || process.env.E2E_DAEMON_DECODE) {
    const reported = normalizeDecode(process.env.E2E_DAEMON_DECODE || tier.daemonDecodeReported || '');
    const expect = normalizeDecode(tier.expectDecode);
    if (tier.requireDaemonTier && !reported) {
      fail(
        'daemon_tier_unprobed',
        `Export E2E_DAEMON_DECODE=${expect} after parent applies conf.\n${pc.applyText}`
      );
    }
    if (reported && expect && reported !== expect) {
      fail('daemon_tier_mismatch', `reported=${reported} expect=${expect}`);
    }
    if (reported) log(`DAEMON_TIER_OK decode=${reported}`);
  }

  // ── Discover or validate explicit real item (NO fixture fallback) ───────
  let item;
  const explicitRk = process.env.PLEX_RATING_KEY || process.env.PLEX_KEY || '';
  if (explicitRk) {
    log(`real_item_source=explicit_rating_key ${explicitRk}`);
    item = await resolveExplicitRealItem(explicitRk);
  } else {
    log('real_item_source=discover');
    const disc = await discoverRealTitle(cfg, { expectDecode: tier.expectDecode });
    if (!disc.ok) {
      log(`discover_scanned=${disc.scanned} sections=${JSON.stringify(disc.sections || [])}`);
      if (disc.rejectedFixtures?.length) {
        log(
          `discover_rejected_fixtures_sample=${disc.rejectedFixtures
            .slice(0, 5)
            .map((f) => `${f.ratingKey}:${f.title}`)
            .join(' | ')}`
        );
      }
      fail(disc.reason || 'real_content_library_empty', disc.detail || '');
    }
    item = disc.item;
    log(
      `discover_ok scanned=${disc.scanned} rejected_fixtures=${disc.rejectedFixtures} ` +
        `chosen_score=${item.score} alternates=${(disc.alternates || [])
          .map((a) => a.ratingKey)
          .join(',')}`
    );
  }

  log(
    `REAL_ITEM ratingKey=${item.ratingKey} title=${JSON.stringify(item.title)} ` +
      `section=${JSON.stringify(item.sectionTitle || '')} ` +
      `library_media=${item.width}x${item.height} codec=${item.videoCodec} ` +
      `profile=${item.videoProfile || '?'} container=${item.container} ` +
      `bitrate=${item.bitrate} duration_ms=${item.durationMs} fps=${item.frameRate || '?'}`
  );

  const geom = geometryChain(item, tier);
  log(`GEOM_CHAIN ${JSON.stringify(geom)}`);

  const dp = await probeDirectPlayDecision(item);
  if (dp) {
    log(
      `GEOM_CHAIN_DIRECTPLAY_SCOPE path_guess=${geom.path_guess} ` +
        `pms_decision_direct=${dp.directPlay ? 1 : 0} pms_decision_transcode=${dp.transcode ? 1 : 0}`
    );
  }

  const correlationId = `p7-${Date.now()}-rk${item.ratingKey}`;
  log(`CAST_CORRELATION_ID=${correlationId} (mark daemon log window)`);
  printParentLogClearRecipe(correlationId);
  const tWallStart = Date.now();
  log(`CAST_WINDOW_START_UNIX_MS=${tWallStart} iso=${new Date(tWallStart).toISOString()}`);

  const baseTl = await pollDaemonTimeline(nextSuiteCmd());
  const daemonUp = baseTl.includes('Timeline') || baseTl.includes('MediaContainer');
  if (!daemonUp) {
    log(`WARN daemon not reachable at ${daemonBase(cfg)}`);
  } else {
    await forceStopDaemon('preflight');
  }

  const playwright = loadPlaywright();
  const { chromium } = playwright;
  let browser;
  try {
    const launchOpts = {
      headless: cfg.headless,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (cfg.chromiumPath) launchOpts.executablePath = cfg.chromiumPath;
    browser = await chromium.launch(launchOpts);
  } catch (e) {
    skip(`chromium launch failed: ${e.message}`);
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
  await context.addCookies([{ name: 'X-Plex-Token', value: cfg.token, url: cfg.plexBase }]);
  await context.addInitScript((tok) => {
    try {
      window.localStorage.setItem('myPlexAccessToken', tok);
      window.localStorage.setItem('myPlexAuthToken', tok);
    } catch (_) {
      /* ignore */
    }
  }, cfg.token);

  const page = await context.newPage();
  page.setDefaultTimeout(cfg.timeoutMs);

  let suitePassed = false;
  let teardownResult = null;
  let bodyError = null;
  const holdSec = parseInt(process.env.E2E_REAL_HOLD_SEC || process.env.E2E_HDMI_HOLD_SEC || '45', 10);

  try {
    const home = `${cfg.plexBase}/web/index.html`;
    log(`goto ${home}`);
    await page.goto(home, { waitUntil: 'domcontentloaded', timeout: cfg.timeoutMs });
    await sleep(2000);
    if (/signin|login/i.test(page.url())) {
      await page.goto(`${home}#?X-Plex-Token=${encodeURIComponent(cfg.token)}`, {
        waitUntil: 'domcontentloaded',
        timeout: cfg.timeoutMs,
      });
      await sleep(3000);
    }
    if (/signin|login/i.test(page.url())) {
      fail('plex_web_signin_required', 'token did not establish session');
    }

    const ug = await dismissUserPicker(page, cfg.webUser);
    log(`user_gate phase=${ug.phase || '?'} picked=${ug.picked || '-'}`);
    if (ug.shown && !ug.picked) fail('plex_home_user_picker_not_dismissed', 'Select User blocked shell');

    const serverSeg = idn.machineId || 'auto';
    const metaKey = `/library/metadata/${item.ratingKey}`;
    const detailsUrl = `${cfg.plexBase}/web/index.html#!/server/${serverSeg}/details?key=${encodeURIComponent(metaKey)}`;
    log(`goto details ${metaKey} correlation=${correlationId}`);
    await page.goto(detailsUrl, { waitUntil: 'domcontentloaded', timeout: cfg.timeoutMs });
    await dismissUserPicker(page, cfg.webUser);

    const detailsReady = await waitForDetailsReady(page, item.title, Math.max(cfg.timeoutMs, 90000));
    await shot(page, 'real_01_details');

    const ctl = await waitForSelectPlayerControl(page, 45000);
    if (ctl.kind !== 'ok') {
      await shot(page, 'real_fail_no_select_player');
      fail('select_player_control_not_found', 'Select Player missing on real-item details');
    }
    const beforePicker = await bodyLineSet(page);
    await ctl.el.click({ timeout: 5000 });
    await sleep(1200);
    await shot(page, 'real_02_picker');
    const target = await assertMisterplexInPickerDiff(page, beforePicker);
    const clickedText = ((await target.innerText().catch(() => '')) || '').trim().split('\n')[0];
    const exactRe = new RegExp(`^${cfg.castName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'i');
    if (clickedText && !exactRe.test(clickedText)) {
      fail('picker_clicked_non_exact_target', `got ${clickedText}`);
    }
    await target.click();
    log(`selected_cast_target exact=${cfg.castName}`);

    const afterCast = await waitForDetailsReady(page, item.title, 60000);
    const played = await clickPlay(page, afterCast.playSel || detailsReady.playSel);
    if (!played) {
      await shot(page, 'real_fail_no_play');
      fail('play_button_not_found', 'Play missing after cast select');
    }
    await handleResumeDialog(page);
    await shot(page, 'real_03_play_clicked');
    log(`PLAY_ISSUED correlation=${correlationId} ratingKey=${item.ratingKey} t_wall_ms=${Date.now()}`);

    const prog = await waitPlayingOnDaemon(cfg.playWaitSec);
    if (prog.playing < 2) {
      await shot(page, 'real_fail_not_playing');
      fail(
        'playback_did_not_start',
        `Real title cast but timeline not playing (samples=${prog.playing} max_t=${prog.maxT}). ` +
          `correlation=${correlationId}`
      );
    }
    if (prog.advance < 1 && prog.maxT < 500) {
      fail(
        'playback_time_not_advancing',
        `playing samples=${prog.playing} but time not advancing (max_t=${prog.maxT})`
      );
    }
    log(
      `playing_ok samples=${prog.playing} advance=${prog.advance} time_max_ms=${prog.maxT} ` +
        `correlation=${correlationId}`
    );

    // Gate capture on established session (timeline time ≥ threshold). Prevents
    // parent HDMI grabs that race idle chevron / pre-play (rc=77 UNSCORED).
    const thr = sessionWallThresholdMs();
    const sessTimeout = Math.max(cfg.playWaitSec, 25);
    log(`SESSION_GATE begin threshold_ms=${thr} timeout_s=${sessTimeout}`);
    const session = await waitSessionEstablished(thr, sessTimeout);
    if (!session.ok) {
      await shot(page, 'real_fail_session_not_established');
      fail(
        'session_not_established',
        `Daemon never reached playing with time>=${thr}ms ` +
          `(max_t=${session.maxT} state=${session.state} playing_hits=${session.playingHits}). ` +
          `Do NOT capture HDMI yet — would race idle. correlation=${correlationId}`
      );
    }
    log(
      `SESSION_ESTABLISHED time_ms=${session.timeMs} max_t=${session.maxT} ` +
        `correlation=${correlationId}`
    );

    // Emit capture recipe ONLY after session is established.
    printParentRecipe(item, geom, correlationId, holdSec, session);

    // Optional: parent-fed delivered geometry (cleared log / E2E_DELIVERED_GEOM).
    // expected_delivery is a REQUEST — assert measured when provided.
    const requireDelivered = /^(1|true|yes|on)$/i.test(
      String(process.env.E2E_REQUIRE_DELIVERED_GEOM || '0')
    );
    let delivered = await resolveDeliveredGeometry(correlationId, item.ratingKey);
    if (!delivered.ok && requireDelivered) {
      fail(
        'delivered_geom_unprobed',
        'E2E_REQUIRE_DELIVERED_GEOM=1 but neither E2E_DELIVERED_GEOM nor a parseable ' +
          'E2E_DAEMON_LOG with media: DELIVERED_GEOM / Stream #0:0 WxH was provided. ' +
          'Clear log before cast, copy snip after PLAY, re-export path.'
      );
    }
    if (delivered.ok) {
      log(`DELIVERED_GEOM_MEASURED stream=${delivered.stream} source=${delivered.source}`);
      log(
        `GEOM_CHAIN_MEASURED library_media=${geom.library_media} ` +
          `expected_delivery_request=${geom.expected_delivery} ` +
          `delivered_stream=${delivered.stream} decode_bank=${geom.expect_decode_bank}`
      );
    } else {
      log(
        `DELIVERED_GEOM_PENDING source=${delivered.source} — parent should export ` +
          `E2E_DELIVERED_GEOM or E2E_DAEMON_LOG after reading media: DELIVERED_GEOM ` +
          `(daemon needs -loglevel info rebuild). Not a silent pass of delivery size.`
      );
    }

    // Hold for parent capture — do not open /dev/video0.
    log(`REAL_CONTENT_HOLD_BEGIN sec=${holdSec} correlation=${correlationId}`);
    const holdEnd = Date.now() + Math.max(5, holdSec) * 1000;
    while (Date.now() < holdEnd) {
      const xml = await pollDaemonTimeline(nextSuiteCmd());
      const tHold = parseInt(xmlAttr(xml, 'time') || '-1', 10);
      log(
        `  hold state=${xmlAttr(xml, 'state') || '?'} time=${xmlAttr(xml, 'time') || '?'} ` +
          `correlation=${correlationId}`
      );
      if (!delivered.ok) {
        const again = await resolveDeliveredGeometry(correlationId, item.ratingKey);
        if (again.ok) {
          delivered = again;
          log(`DELIVERED_GEOM_MEASURED_LATE stream=${delivered.stream} source=${delivered.source}`);
        }
      }
      if (xmlAttr(xml, 'state') !== 'playing' && tHold >= 0 && tHold < thr) {
        log('WARN hold saw non-playing / low time — capture may race idle');
      }
      await sleep(2000);
    }
    log(`REAL_CONTENT_HOLD_END correlation=${correlationId}`);
    log(`CAST_WINDOW_END_UNIX_MS=${Date.now()} iso=${new Date().toISOString()}`);

    if (requireDelivered) {
      delivered = await resolveDeliveredGeometry(correlationId, item.ratingKey);
      if (!delivered.ok) {
        fail(
          'delivered_geom_missing_after_hold',
          'Session held but delivered geometry still unmeasured. ' +
            'Deploy daemon with media -loglevel info + DELIVERED_GEOM, clear log, re-run.'
        );
      }
    }

    // Optional: parent dropped PNGs during HOLD. Real content: rc=77 is hard FAIL.
    if (cfg.hdmiMotion) {
      const capDir = path.join(String(cfg.hdmiCaptureDir).replace(/\/$/, ''), 'real_p7');
      const n = fs.existsSync(capDir)
        ? fs.readdirSync(capDir).filter((f) => /\.png$/i.test(f)).length
        : 0;
      log(`hdmi_png_count=${n} dir=${capDir}`);
      if (n >= 3) {
        const tool = path.join(ROOT, 'tools', 'hdmi_motion_instrument.py');
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
        for (const line of out.split('\n').filter(Boolean).slice(-25)) {
          log(`  instrument: ${line.slice(0, 240)}`);
        }
        const rc = typeof res.status === 'number' ? res.status : 99;
        log(`hdmi_instrument true rc=${rc}`);
        if (rc === 3) fail('hdmi_motion_structure_fail', out.slice(-400));
        if (rc === 2) fail('hdmi_motion_color_fail', out.slice(-400));
        if (rc === 1) fail('hdmi_motion_freeze', out.slice(-400));
        if (rc === 77) {
          fail(
            'hdmi_motion_unscored',
            'instrument rc=77 UNSCORED after SESSION_ESTABLISHED — hard FAIL ' +
              '(likely idle/chevron or warm-up). Re-capture during HOLD only.\n' +
              out.slice(-400)
          );
        }
        if (rc === 0) log('HDMI_MOTION_OK (counter present on real title — unexpected but PASS)');
        else if (rc !== 0) fail('hdmi_motion_instrument_failed', `rc=${rc}\n${out.slice(-400)}`);
      } else {
        log(
          'HDMI_MOTION=on but no PNGs in cap dir yet — parent must run PARENT_HDMI_CAPTURE_CMD ' +
            'during HOLD after SESSION_ESTABLISHED (suite never opens /dev/video0)'
        );
      }
    }

    suitePassed = true;
    log(
      `REAL_CONTENT_E2E_RESULT=PASS ratingKey=${item.ratingKey} library_media=${geom.library_media} ` +
        `delivered=${delivered.ok ? delivered.stream : 'unprobed'} ` +
        `tier=${geom.requested_tier} correlation=${correlationId} ` +
        `session_time_ms=${session.timeMs}`
    );
  } catch (e) {
    suitePassed = false;
    if (e instanceof FailError) bodyError = e;
    else {
      console.error('FAIL test_real_content_playwright: unhandled_error');
      console.error(redact(e.stack || e.message || String(e)));
      bodyError = new FailError('unhandled_error', redact(e.stack || e.message || String(e)));
    }
  } finally {
    teardownResult = await hardTeardown(page, context, browser).catch((te) => ({
      ok: false,
      reason: te.message,
    }));
  }

  if (bodyError) process.exit(bodyError.exitCode || EXIT_FAIL);
  if (suitePassed && teardownResult && !teardownResult.ok) {
    console.error('FAIL test_real_content_playwright: teardown_controller_not_closed');
    process.exit(EXIT_FAIL);
  }
  if (suitePassed && teardownResult && teardownResult.ok) {
    log('summary real_content=PASS teardown=ok');
    process.exitCode = EXIT_PASS;
    return;
  }
  process.exit(EXIT_FAIL);
})().catch((e) => {
  if (e instanceof FailError) process.exit(e.exitCode || EXIT_FAIL);
  console.error(`UNHANDLED: ${redact(e.message || e)}`);
  process.exit(EXIT_SKIP);
});
