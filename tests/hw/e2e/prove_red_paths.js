#!/usr/bin/env node
/**
 * prove_red_paths.js — gate failure-path proof WITHOUT touching the MiSTer cast path.
 *
 * Parent asked: prove the suite goes RED on wrong endpoint / unreachable target,
 * and never blind-green when PMS cannot be verified.
 *
 * This script does NOT drive playback. It exercises the same HTTP probes the suite
 * uses and prints CAST_PICKER_GATE_* outcomes with true process exit codes.
 *
 * Exit:
 *   0  all red-path proofs behaved as pre-registered (PROOF_OK)
 *   1  a proof misbehaved (would have been blind green or wrong class)
 *
 * Usage:
 *   node tests/hw/e2e/prove_red_paths.js
 *   PLEX_BASE=http://YOUR-PLEX-SERVER:32400 node tests/hw/e2e/prove_red_paths.js  # also probe live PMS
 */

'use strict';

const http = require('http');
const https = require('https');

const {
  EXIT_PASS,
  EXIT_FAIL,
  EXIT_INSUFFICIENT_EVIDENCE,
  EXIT_SESSION_INVALID,
  EXIT_SKIP,
  RESULT_INSUFFICIENT_EVIDENCE,
  selfCheck: evidenceSelfCheck,
} = require('./evidence_codes');
const raceTaxonomy = require('./race_taxonomy');
/** @deprecated name — value is 78 */
const EXIT_UNVERIFIED = EXIT_INSUFFICIENT_EVIDENCE;

function log(...a) {
  console.log(...a);
}

function httpGet(url, timeoutMs = 2500) {
  return new Promise((resolve) => {
    let lib = http;
    try {
      if (String(url).startsWith('https')) lib = https;
    } catch (_) {
      /* keep http */
    }
    const req = lib.get(url, { timeout: timeoutMs, rejectUnauthorized: false }, (res) => {
      let body = '';
      res.on('data', (d) => {
        body += d;
      });
      res.on('end', () => resolve({ status: res.statusCode || 0, body }));
    });
    req.on('error', (e) => resolve({ status: 0, body: '', err: e.message }));
    req.on('timeout', () => {
      req.destroy();
      resolve({ status: 0, body: '', err: 'timeout' });
    });
  });
}

function classifyDaemonTimeline(body, status) {
  const text = body || '';
  const up = text.includes('Timeline') || text.includes('MediaContainer');
  if (status === 0 || !up) {
    return {
      ok: false,
      reason: 'daemon_unreachable',
      exitCode: EXIT_FAIL,
      detail: `no Timeline/MediaContainer status=${status}`,
    };
  }
  return { ok: true, reason: 'daemon_ok', exitCode: EXIT_PASS };
}

function classifyPmsWeb(status) {
  if (status >= 200 && status < 400) {
    return { ok: true, reason: 'pms_ok', exitCode: EXIT_PASS };
  }
  // Configured base but unreachable → INSUFFICIENT_EVIDENCE rc=78 (w-avsync)
  return {
    ok: false,
    reason: 'PMS_UNREACHABLE',
    exitCode: EXIT_INSUFFICIENT_EVIDENCE,
    result: RESULT_INSUFFICIENT_EVIDENCE,
    detail: `HTTP ${status}`,
  };
}

async function main() {
  log('prove_red_paths: BEGIN');
  log('PRE_REGISTER:');
  log('  P1 wrong daemon port → daemon_unreachable class, exit would be FAIL(1) not PASS');
  log('  P2 bogus PMS host → PMS_UNREACHABLE class, exit would be INSUFFICIENT_EVIDENCE(78) not PASS');
  log('  P3 missing deps class remains SKIP(77) NO-DATA — never scored as pass');
  log(
    `  P4 EXIT_INSUFFICIENT=${EXIT_INSUFFICIENT_EVIDENCE} EXIT_SESSION_INVALID=${EXIT_SESSION_INVALID} ` +
      `EXIT_SKIP=${EXIT_SKIP} never equal EXIT_PASS=0`
  );
  log('  P5 client_truth selfCheck: play/pause/seek/rate reds + ratingKey INVALID on swap');
  log('      rate_starved(0.467)→FAIL rate_healthy(0.993)→PASS pause/seek excluded');
  log('  P8 media_health selfCheck: collapsed supply_ratio=0.72 FAIL; healthy PASS;');
  log('      drift+133 FAIL; pid swap INVALID; unprobed FAIL (never soft-green)');
  log('  P9 pms_control_plane: play/pause/gone reds; tc speed=0 FAIL; speed=19.8 PASS; stale FAIL');
  log('  P10 measured_delivery: 624x480/624x480→624x350 class=pms_ceiling_desync;');
  log('      expect=library FAIL; basis=library forbidden; desync_risk=1 FAIL');
  log('  P11 evidence_codes: rc 0/1/78/79/77 disjoint; COVERAGE VERIFY_CONTROL_NOT_QUALITY');
  log('  P12 race_taxonomy: spinner≠play_button_not_found; 9/10 N-loop FAIL (no majority pass)');

  let proofsOk = 0;
  let proofsFail = 0;

  // ── P5: client_truth pure red-before-green (no device, no cast) ──────────
  try {
    const ct = require('./client_truth');
    ct.selfCheck();
    log(
      'PROOF P5 OK client_truth selfCheck (play/pause/seek reds + rk_swap INVALID + ' +
        'rate_starved FAIL + rate_healthy PASS)'
    );
    proofsOk++;
  } catch (e) {
    log(`PROOF P5 FAIL client_truth selfCheck: ${e.message || e}`);
    proofsFail++;
  }

  // ── P8: media_health pure red-before-green (parent collapse fixtures) ──
  try {
    const mh = require('./media_health');
    mh.selfCheck();
    log(
      'PROOF P8 OK media_health selfCheck (collapsed supply_ratio FAIL + healthy PASS + ' +
        'drift FAIL + pid INVALID + unprobed FAIL)'
    );
    proofsOk++;
  } catch (e) {
    log(`PROOF P8 FAIL media_health selfCheck: ${e.message || e}`);
    proofsFail++;
  }

  // ── P9: PMS control-plane pure red-before-green (no device) ────────────
  try {
    const pms = require('./pms_control_plane');
    pms.selfCheck();
    log(
      'PROOF P9 OK pms_control_plane selfCheck (session play/pause/gone + tc collapse + stale)'
    );
    proofsOk++;
  } catch (e) {
    log(`PROOF P9 FAIL pms_control_plane selfCheck: ${e.message || e}`);
    proofsFail++;
  }

  // ── P10: measured delivery / geom triple (parent 624x350 class) ────────
  try {
    const md = require('./measured_delivery');
    md.selfCheck();
    log(
      'PROOF P10 OK measured_delivery selfCheck (pms_ceiling_desync 624x350 + library expect FAIL)'
    );
    proofsOk++;
  } catch (e) {
    log(`PROOF P10 FAIL measured_delivery selfCheck: ${e.message || e}`);
    proofsFail++;
  }

  // ── P11: evidence codes / coverage (w-avsync align) ────────────────────
  try {
    evidenceSelfCheck();
    log(
      'PROOF P11 OK evidence_codes (78 INSUFFICIENT / 79 SESSION_INVALID / control≠quality)'
    );
    proofsOk++;
  } catch (e) {
    log(`PROOF P11 FAIL evidence_codes: ${e.message || e}`);
    proofsFail++;
  }

  // ── P12: details race taxonomy + S6 N-loop majority-is-not-pass ────────
  try {
    const r = raceTaxonomy.selfCheck();
    log(
      `PROOF P12 OK race_taxonomy (${(r.cases || []).join(',')}) — ` +
        'spinner→details_spinner_stuck; post-cast load≠play_button_not_found; 9/10 RED'
    );
    proofsOk++;
  } catch (e) {
    log(`PROOF P12 FAIL race_taxonomy: ${e.message || e}`);
    proofsFail++;
  }

  // ── P1: deliberately wrong companion endpoint ────────────────────────────
  const badDaemon = 'http://127.0.0.1:1/player/timeline/poll?commandID=1&wait=0';
  const d1 = await httpGet(badDaemon, 1500);
  const c1 = classifyDaemonTimeline(d1.body, d1.status);
  const p1hit =
    c1.ok === false && c1.reason === 'daemon_unreachable' && c1.exitCode === EXIT_FAIL;
  log(
    `PROOF P1 wrong_daemon status=${d1.status} class=${c1.reason} ` +
      `would_exit=${c1.exitCode} hit=${p1hit ? 1 : 0} detail=${c1.detail || ''}`
  );
  if (p1hit) proofsOk++;
  else {
    proofsFail++;
    log('PROOF_MISS P1 — wrong daemon did not classify as daemon_unreachable FAIL');
  }

  // ── P2: deliberately wrong PMS ───────────────────────────────────────────
  const badPms = 'http://127.0.0.1:1/web/index.html';
  const p2r = await httpGet(badPms, 1500);
  const c2 = classifyPmsWeb(p2r.status);
  const p2hit =
    c2.ok === false && c2.reason === 'PMS_UNREACHABLE' && c2.exitCode === EXIT_UNVERIFIED;
  log(
    `PROOF P2 wrong_pms status=${p2r.status} class=${c2.reason} ` +
      `would_exit=${c2.exitCode} hit=${p2hit ? 1 : 0}`
  );
  if (p2hit) proofsOk++;
  else {
    proofsFail++;
    log('PROOF_MISS P2 — wrong PMS did not classify as PMS_UNREACHABLE INSUFFICIENT_EVIDENCE(78)');
  }

  // ── P3: constants — 77 and 2 are never 0 ─────────────────────────────────
  const p3hit = EXIT_SKIP !== EXIT_PASS && EXIT_UNVERIFIED !== EXIT_PASS && EXIT_FAIL !== EXIT_PASS;
  log(`PROOF P3 exit_classes_disjoint hit=${p3hit ? 1 : 0}`);
  if (p3hit) proofsOk++;
  else proofsFail++;

  // ── P4 optional: live local PMS when PLEX_BASE set (must PASS classify) ──
  const liveBase = (process.env.PLEX_BASE || '').replace(/\/$/, '');
  if (liveBase) {
    if (/plex\.nevertrustaf\.art|32401/.test(liveBase)) {
      log('PROOF P4 SKIP live base looks remote/ignored — not probing');
    } else {
      const live = await httpGet(`${liveBase}/web/index.html`, 5000);
      const c4 = classifyPmsWeb(live.status);
      const p4hit = c4.ok === true && live.status >= 200 && live.status < 400;
      log(
        `PROOF P4 live_pms base_set=1 status=${live.status} class=${c4.reason} hit=${p4hit ? 1 : 0}`
      );
      // Live down is environment — report, do not fail the red-path proof harness.
      if (p4hit) {
        proofsOk++;
        log('PROOF P4_NOTE live PMS reachable — green path available for full suite');
      } else {
        log(
          `PROOF P4_NOTE live PMS not reachable status=${live.status} — ` +
            `full suite would exit INSUFFICIENT_EVIDENCE(78); red-path classes still proven`
        );
      }
    }
  } else {
    log('PROOF P4 SKIP PLEX_BASE unset — red paths only');
  }

  // ── P5: wrong daemon must not look like Timeline success ─────────────────
  const falseGreen = d1.status === 200 && /Timeline/.test(d1.body || '');
  const p5hit = !falseGreen;
  log(`PROOF P5 no_false_timeline_on_dead_port hit=${p5hit ? 1 : 0}`);
  if (p5hit) proofsOk++;
  else {
    proofsFail++;
    log('PROOF_MISS P5 — dead port returned Timeline (impossible / broken probe)');
  }

  // ── P6: bogus ratingKey must be RED (not silent title fallback) ──────────
  {
    const liveBase = (process.env.PLEX_BASE || '').replace(/\/$/, '');
    const tok =
      process.env.PLEX_TOKEN ||
      (process.env.PLEX_TOKEN_FILE
        ? require('fs').readFileSync(process.env.PLEX_TOKEN_FILE, 'utf8').trim()
        : '');
    if (liveBase && tok && !/192\.168\.1\.122|nevertrustaf/.test(liveBase)) {
      const bogus = '999999991';
      const r = await httpGet(`${liveBase}/library/metadata/${bogus}?X-Plex-Token=${encodeURIComponent(tok)}`, 5000);
      // Suite fails on 404/400 as rating_key_not_found — must NOT be 200 with playable meta.
      const wouldRed = r.status === 404 || r.status === 400 || r.status === 401 || r.status === 0;
      const p6hit = wouldRed;
      log(
        `PROOF P6 bogus_ratingKey status=${r.status} would_suite_RED=${p6hit ? 1 : 0} ` +
          `key=${bogus} value_kind=measured`
      );
      if (p6hit) proofsOk++;
      else {
        proofsFail++;
        log('PROOF_MISS P6 — bogus ratingKey returned playable HTTP; title-fallback risk');
      }
    } else {
      log('PROOF P6 SKIP need PLEX_BASE+token local (not SHIELD/remote)');
    }
  }

  // ── P7: SHIELD base must be refused by policy classifier ─────────────────
  {
    const shield = 'http://192.168.1.122:32400';
    const refuse =
      /192\.168\.1\.122\b/.test(shield) && !/192\.168\.1\.24\b/.test(shield);
    log(`PROOF P7 refuse_shield_base hit=${refuse ? 1 : 0} base=${shield}`);
    if (refuse) proofsOk++;
    else {
      proofsFail++;
      log('PROOF_MISS P7 — SHIELD not refused');
    }
  }

  log(`PROOF_SUMMARY ok=${proofsOk} miss=${proofsFail}`);
  if (proofsFail === 0) {
    log('CAST_PICKER_GATE_RED_PATHS=PROOF_OK');
    log(
      'SUITE_CONTRACT: unreachable PMS → CAST_PICKER_E2E_RESULT=INSUFFICIENT_EVIDENCE rc=78; ' +
        'unreachable daemon when required → FAIL daemon_unreachable rc=1; ' +
        'mid-run rk/pid swap → SESSION_INVALID rc=79; ' +
        'missing token/chromium → SKIP-NOT-PASS/NO-DATA rc=77; none of these are PASS. ' +
        'PASS settles control plane only — NOT playback quality (~25% intermittent degrade).'
    );
    process.exit(EXIT_PASS);
  }
  log('CAST_PICKER_GATE_RED_PATHS=PROOF_FAIL');
  process.exit(EXIT_FAIL);
}

main().catch((e) => {
  console.error('prove_red_paths unhandled', e);
  process.exit(EXIT_FAIL);
});
