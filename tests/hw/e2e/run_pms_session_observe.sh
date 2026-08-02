#!/usr/bin/env bash
# run_pms_session_observe.sh — host-side PMS delivery poller (no device, no Playwright).
#
# Parent casts (or suite casts); this prints independent PMS view:
#   session exists, hasTranscodeSession, delivered_geom, videoDecision, /transcode/sessions count
#
# Corroborates device ffmpeg ladder WITHOUT reading daemon logs:
#   request=397  → often 312x240 + hasTS=0
#   request=2000 → often 624x480 + hasTS=? 
#
# CANNOT prove pixels. Exit:
#   0  observed matching expects (or observe-only with at least one sample)
#   1  FAIL mismatch / never saw session when required
#  78  INSUFFICIENT_EVIDENCE — PMS unreachable
#  77  SKIP-NOT-PASS — missing env
#
# Env: PLEX_BASE PLEX_TOKEN|PLEX_TOKEN_FILE
# Optional: E2E_CAST_NAME E2E_CLIENT_RATING_KEY E2E_PMS_EXPECT_GEOM
#           E2E_PMS_EXPECT_HAS_TRANSCODE E2E_OBSERVE_SEC E2E_OBSERVE_REQUIRE_SESSION=1
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 77

if [[ -z "${PLEX_BASE:-}" ]]; then
  echo "SKIP-NOT-PASS: PLEX_BASE unset"
  exit 77
fi

export E2E_OBSERVE_SEC="${E2E_OBSERVE_SEC:-90}"
export E2E_OBSERVE_INTERVAL_MS="${E2E_OBSERVE_INTERVAL_MS:-2000}"
export E2E_CAST_NAME="${E2E_CAST_NAME:-MiSTerPlex}"

echo "PMS_SESSION_OBSERVE begin sec=${E2E_OBSERVE_SEC} cast=${E2E_CAST_NAME} rk=${E2E_CLIENT_RATING_KEY:-any}"
echo "BOUNDARY: PMS session document only — NOT pixels on glass. INSUFFICIENT_EVIDENCE for picture claims."
echo "PRE_REGISTER: print hasTS + delivered_geom each tick; FAIL if expect geom/TS mismatches when set."

node <<'NODE'
'use strict';
const fs = require('fs');
const {
  fetchStatusSessions,
  fetchTranscodeSessions,
  assertPmsDeliveryObservation,
  formatPmsDeliveryLine,
  BOUNDARY_BANNER,
} = require('./pms_control_plane');
const { EXIT_PASS, EXIT_FAIL, EXIT_INSUFFICIENT_EVIDENCE, EXIT_SKIP } = require('./evidence_codes');

function token() {
  if (process.env.PLEX_TOKEN) return String(process.env.PLEX_TOKEN).trim();
  const f = process.env.PLEX_TOKEN_FILE || '';
  if (f && fs.existsSync(f)) return fs.readFileSync(f, 'utf8').replace(/\r?\n/g, '').trim();
  for (const p of ['/tmp/local_tok.txt', require('path').join(require('os').homedir(), '.config/misterplex/plex_token')]) {
    try {
      if (fs.existsSync(p)) {
        const t = fs.readFileSync(p, 'utf8').replace(/\r?\n/g, '').trim();
        if (t) return t;
      }
    } catch (_) {}
  }
  return '';
}

function parseExpectHasTs() {
  const v = process.env.E2E_PMS_EXPECT_HAS_TRANSCODE;
  if (v === undefined || v === null || v === '') return null;
  if (/^(1|true|yes|on)$/i.test(String(v))) return true;
  if (/^(0|false|no|off)$/i.test(String(v))) return false;
  return null;
}

(async () => {
  console.log(BOUNDARY_BANNER);
  const base = String(process.env.PLEX_BASE || '').replace(/\/$/, '');
  const tok = token();
  if (!base || !tok) {
    console.error('SKIP-NOT-PASS missing PLEX_BASE or token');
    process.exit(EXIT_SKIP);
  }
  if (/192\.168\.1\.122|nevertrustaf/i.test(base)) {
    console.error('FAIL refusing SHIELD/remote PMS');
    process.exit(EXIT_FAIL);
  }

  const sec = Math.max(5, parseInt(process.env.E2E_OBSERVE_SEC || '90', 10) || 90);
  const interval = Math.max(500, parseInt(process.env.E2E_OBSERVE_INTERVAL_MS || '2000', 10) || 2000);
  const cast = process.env.E2E_CAST_NAME || 'MiSTerPlex';
  const rk = process.env.E2E_CLIENT_RATING_KEY || process.env.PLEX_RATING_KEY || '';
  const expectGeom = process.env.E2E_PMS_EXPECT_GEOM || '';
  const expectHasTs = parseExpectHasTs();
  const requireSession = /^(1|true|yes|on)$/i.test(String(process.env.E2E_OBSERVE_REQUIRE_SESSION || '0'));
  const deadline = Date.now() + sec * 1000;
  let saw = 0;
  let lastOk = null;
  let failDetail = '';

  // Reachability
  const probe = await fetchStatusSessions(base, tok);
  if (!probe.ok && probe.http_status === 0) {
    console.error('INSUFFICIENT_EVIDENCE PMS unreachable');
    process.exit(EXIT_INSUFFICIENT_EVIDENCE);
  }

  while (Date.now() < deadline) {
    const st = await fetchStatusSessions(base, tok);
    const tc = await fetchTranscodeSessions(base, tok);
    const obs = assertPmsDeliveryObservation(st, tc, 'observe', {
      castName: cast,
      ratingKey: rk,
      expectGeom,
      expectHasTranscode: expectHasTs,
      requireGeom: !!expectGeom,
    });
    const ts = new Date().toISOString();
    if (obs.ok) {
      saw++;
      lastOk = obs;
      console.log(`${ts} ${formatPmsDeliveryLine(obs, 'PMS_DELIVERY')}`);
    } else if (obs.reason === 'pms_delivery_no_session' || obs.reason === 'pms_delivery_unprobed') {
      console.log(
        `${ts} PMS_DELIVERY waiting session cast=${cast} rk=${rk || '*'} ` +
          `status_count=${st.count != null ? st.count : 'NA'} reason=${obs.reason}`
      );
    } else {
      console.error(`${ts} PMS_DELIVERY FAIL ${obs.reason}: ${obs.detail}`);
      failDetail = obs.detail || obs.reason;
      process.exit(EXIT_FAIL);
    }
    await new Promise((r) => setTimeout(r, interval));
  }

  if (lastOk) {
    console.log(
      `PMS_SESSION_OBSERVE_RESULT=PASS samples=${saw} last_delivered=${lastOk.report.delivered_geom || 'NO-DATA'} ` +
        `hasTS=${lastOk.report.hasTranscodeSession ? 1 : 0} NOT_pixels`
    );
    process.exit(EXIT_PASS);
  }
  if (requireSession) {
    console.error(
      `PMS_SESSION_OBSERVE_RESULT=FAIL no session for ${cast} in ${sec}s (require_session=1)`
    );
    process.exit(EXIT_FAIL);
  }
  console.error(
    `PMS_SESSION_OBSERVE_RESULT=INSUFFICIENT_EVIDENCE samples=0 sec=${sec} — no cast session observed. NOT a pass.`
  );
  process.exit(EXIT_INSUFFICIENT_EVIDENCE);
})().catch((e) => {
  console.error('UNHANDLED', e.message || e);
  process.exit(1);
});
NODE
