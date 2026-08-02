'use strict';

/**
 * media_health.js — per-cycle media-path health from daemon media/supply lines.
 *
 * Parent intermittency (identical core/daemon/conf/clip, minutes apart):
 *   COLLAPSED: pfps 12.9 drops 1030 supply_ratio 0.72 drift +133 diverging
 *   HEALTHY:   pfps 23.5 drops 13   supply_ratio 0.99 drift -30 bounded
 *
 * UI advance-only and client rate can still pass while supply collapses.
 * This module scores supply_ratio + drift + pid stability.
 *
 * clock=av-lock: media_player.cpp emits it as an unconditional string literal
 * (ERROR 20). We still require the field when scoring (forward-compat) but mark
 * it NON_DISCRIMINATING — a pure av-lock check cannot fail on live product.
 *
 * supply_ratio sources (first hit wins):
 *   1) explicit supply_ratio=
 *   2) d_presents / expected_frames  (supply_bucket)
 *   3) audio_s / wall_s              (media: line; parent audio_s/wall_s)
 *   4) pfps / (fps_num/fps_den)      (media: pfps + fps=)
 *
 * Tolerance derivation (do not invent loosely):
 *   min_supply_ratio = 0.90
 *     — above collapsed 0.72, at/under healthy 0.99 (parent threshold)
 *   max_abs_drift_ms = 75
 *     — above healthy |−39|…|−23| / |−30|; below collapsed +133
 */

const fs = require('fs');
const http = require('http');

function httpGet(url, timeoutMs = 4000) {
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
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

function num(v, def = NaN) {
  if (v === undefined || v === null || v === '') return def;
  const n = typeof v === 'number' ? v : parseFloat(String(v));
  return Number.isFinite(n) ? n : def;
}

/**
 * Parse one media: / supply_bucket / telemetry blob into health fields.
 */
function parseMediaHealthText(text) {
  const s = String(text || '');
  const out = {
    ok: false,
    source: 'unprobed',
    supply_ratio: null,
    supply_ratio_src: '',
    av_drift_ms: null,
    clock: '',
    clock_literal_nondiscriminating: true, // ERROR 20 — product always prints av-lock
    pfps: null,
    vfps: null,
    audio_s: null,
    wall_s: null,
    drops: null,
    presents: null,
    frames: null,
    pid: null,
    session: null,
    session_epoch: '',
    expected_frames: null,
    d_presents: null,
    supply_gap: null,
    raw: s.slice(0, 400),
    value_kind: 'measured',
  };

  const mClock = s.match(/\bclock=([^\s]+)/);
  if (mClock) out.clock = mClock[1];

  const mDrift = s.match(/\bav_drift_ms=(-?\d+(?:\.\d+)?)/);
  if (mDrift) out.av_drift_ms = num(mDrift[1]);

  const mPfps = s.match(/\bpfps=(\d+(?:\.\d+)?)/);
  if (mPfps) out.pfps = num(mPfps[1]);
  const mVfps = s.match(/\bvfps=(\d+(?:\.\d+)?)/);
  if (mVfps) out.vfps = num(mVfps[1]);

  const mAudio = s.match(/\baudio_s=(\d+(?:\.\d+)?)/);
  if (mAudio) out.audio_s = num(mAudio[1]);
  const mWall = s.match(/\bwall_s=(\d+(?:\.\d+)?)/);
  if (mWall) out.wall_s = num(mWall[1]);

  const mDrops = s.match(/\bdrops=(\d+)/);
  if (mDrops) out.drops = parseInt(mDrops[1], 10);
  const mPres = s.match(/\bpresents=(\d+)/);
  if (mPres) out.presents = parseInt(mPres[1], 10);
  const mFr = s.match(/\bframes=(\d+)/);
  if (mFr) out.frames = parseInt(mFr[1], 10);
  const mPid = s.match(/\bpid=(\d+)/);
  if (mPid) out.pid = parseInt(mPid[1], 10);
  const mSess = s.match(/\bsession=(\d+)/);
  if (mSess) out.session = parseInt(mSess[1], 10);
  const mSe = s.match(/\bsession_epoch=([^\s]+)/);
  if (mSe) out.session_epoch = mSe[1];

  const mExp = s.match(/\bexpected_frames=(\d+(?:\.\d+)?)/);
  if (mExp) out.expected_frames = num(mExp[1]);
  const mDp = s.match(/\bd_presents=(-?\d+)/);
  if (mDp) out.d_presents = parseInt(mDp[1], 10);
  const mGap = s.match(/\bsupply_gap=(-?\d+(?:\.\d+)?)/);
  if (mGap) out.supply_gap = num(mGap[1]);

  // Explicit supply_ratio=
  const mSr = s.match(/\bsupply_ratio=(\d+(?:\.\d+)?)/);
  if (mSr) {
    out.supply_ratio = num(mSr[1]);
    out.supply_ratio_src = 'supply_ratio=';
  } else if (
    out.expected_frames != null &&
    out.expected_frames > 0 &&
    out.d_presents != null &&
    out.d_presents >= 0
  ) {
    out.supply_ratio = out.d_presents / out.expected_frames;
    out.supply_ratio_src = 'd_presents/expected_frames';
  } else if (
    out.audio_s != null &&
    out.wall_s != null &&
    out.wall_s > 0.5
  ) {
    out.supply_ratio = out.audio_s / out.wall_s;
    out.supply_ratio_src = 'audio_s/wall_s';
  } else {
    const mFps = s.match(/\bfps=(\d+)\s*\/\s*(\d+)/);
    if (mFps && out.pfps != null) {
      const fps = parseInt(mFps[1], 10) / Math.max(1, parseInt(mFps[2], 10));
      if (fps > 0) {
        out.supply_ratio = out.pfps / fps;
        out.supply_ratio_src = 'pfps/fps';
      }
    }
  }

  out.ok =
    out.supply_ratio != null ||
    out.av_drift_ms != null ||
    out.pid != null ||
    (out.presents != null && out.drops != null);
  if (/supply_bucket/.test(s)) out.source = 'supply_bucket';
  else if (/media:/.test(s)) out.source = 'media';
  else if (/\bok=1\b/.test(s) || /\bpid=\d+/.test(s)) out.source = 'telemetry';
  else if (out.ok) out.source = 'blob';
  return out;
}

/**
 * Prefer last media: or supply_bucket line from a multi-line log.
 */
function parseMediaHealthFromLogText(text) {
  const lines = String(text || '').split(/\r?\n/);
  let best = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!/supply_bucket|media:|supply_ratio=|av_drift_ms=|audio_s=/.test(line)) continue;
    const h = parseMediaHealthText(line);
    if (h.supply_ratio != null || h.av_drift_ms != null) {
      best = h;
      best.raw = line.slice(0, 400);
      break;
    }
    if (!best && h.ok) best = h;
  }
  return best;
}

async function fetchTelemetryBody(daemonBase) {
  const urls = [`${daemonBase}/player/telemetry`, `${daemonBase}/telemetry`];
  for (const u of urls) {
    const r = await httpGet(u);
    if (r.status === 200 && r.body && !/not found|no_telemetry/i.test(r.body)) {
      return r.body;
    }
  }
  return '';
}

/**
 * Capture media health: telemetry HTTP then E2E_DAEMON_LOG / cfg.daemonLogPath.
 */
async function captureMediaHealth(cfg) {
  const base = `http://${cfg.misterHost}:${cfg.misterPort}`;
  const tel = await fetchTelemetryBody(base);
  if (tel) {
    const h = parseMediaHealthText(tel);
    if (h.ok) {
      h.capture = 'telemetry';
      return h;
    }
  }
  const logPath =
    process.env.E2E_DAEMON_LOG ||
    process.env.E2E_MEDIA_LOG ||
    cfg.daemonLogPath ||
    '';
  if (logPath && fs.existsSync(logPath)) {
    try {
      const text = fs.readFileSync(logPath, 'utf8');
      const slice = text.length > 131072 ? text.slice(-131072) : text;
      const h = parseMediaHealthFromLogText(slice);
      if (h) {
        h.capture = 'log';
        h.log_path = logPath;
        return h;
      }
    } catch (_) {
      /* fall through */
    }
  }
  return {
    ok: false,
    source: 'unprobed',
    capture: 'none',
    supply_ratio: null,
    av_drift_ms: null,
    clock: '',
    pid: null,
    raw: tel ? tel.slice(0, 200) : '',
    detail:
      'No media health fields. Need GET /player/telemetry with av_drift_ms/supply_ratio ' +
      'or E2E_DAEMON_LOG snip containing media:/supply_bucket lines (parent-fed; suite never ssh).',
    value_kind: 'unprobed',
  };
}

/**
 * Assert media health for one cycle sample.
 * @param {object} h captureMediaHealth result
 * @param {string} tag
 * @param {object} opts
 */
function assertMediaHealth(h, tag, opts = {}) {
  const minRatio = opts.minSupplyRatio != null ? opts.minSupplyRatio : 0.9;
  const maxAbsDrift =
    opts.maxAbsDriftMs != null ? opts.maxAbsDriftMs : 75;
  const requireClock = opts.requireClock !== false;
  const requireRatio = opts.requireRatio !== false;
  const requireDrift = opts.requireDrift !== false;

  if (!h || !h.ok) {
    return {
      ok: false,
      reason: 'media_health_unprobed',
      detail:
        `${tag}: ${((h && h.detail) || 'media health unprobed')}. ` +
        `PRE_REGISTER fail: cannot score supply_ratio/drift without telemetry or E2E_DAEMON_LOG. ` +
        `Soft-skip is NOT allowed when E2E_REQUIRE_MEDIA_HEALTH=1.`,
      value_kind: 'unprobed',
    };
  }

  const notes = [];
  // clock=av-lock is a product literal (ERROR 20). Require presence if asked;
  // never claim it proves A/V lock health.
  if (requireClock) {
    if (!h.clock) {
      return {
        ok: false,
        reason: 'media_clock_unprobed',
        detail:
          `${tag}: clock= missing from media/telemetry. ` +
          `NOTE: live product still emits clock=av-lock as a string literal ` +
          `(media_player.cpp) — field presence is scored; value is NON_DISCRIMINATING.`,
        health: h,
        value_kind: 'measured',
      };
    }
    if (h.clock !== 'av-lock') {
      return {
        ok: false,
        reason: 'media_clock_not_av_lock',
        detail:
          `${tag}: clock=${h.clock} (expected av-lock when product emits lock state). ` +
          `value_kind=measured`,
        health: h,
        value_kind: 'measured',
      };
    }
    notes.push('clock=av-lock NON_DISCRIMINATING_LITERAL=1 (ERROR20)');
  }

  if (requireRatio) {
    if (h.supply_ratio == null || !Number.isFinite(h.supply_ratio)) {
      return {
        ok: false,
        reason: 'media_supply_ratio_unprobed',
        detail:
          `${tag}: supply_ratio unprobed (no supply_ratio=/d_presents/expected/audio_s/wall_s/pfps). ` +
          `PRE_REGISTER fail: cannot gate collapsed supply_ratio=0.72 class.`,
        health: h,
        value_kind: 'unprobed',
      };
    }
    if (h.supply_ratio < minRatio) {
      return {
        ok: false,
        reason: 'media_supply_ratio_low',
        detail:
          `${tag}: supply_ratio=${h.supply_ratio.toFixed(3)} < min=${minRatio} ` +
          `(src=${h.supply_ratio_src || 'NA'}). ` +
          `PRE_REGISTER fail: collapsed-class (parent supply_ratio=0.72 pfps=12.9 drops climbing). ` +
          `UI may still show advancing timeline — this gate catches that false pass.`,
        health: h,
        supply_ratio: h.supply_ratio,
        min_supply_ratio: minRatio,
        value_kind: 'measured',
      };
    }
  }

  if (requireDrift) {
    if (h.av_drift_ms == null || !Number.isFinite(h.av_drift_ms)) {
      return {
        ok: false,
        reason: 'media_drift_unprobed',
        detail:
          `${tag}: av_drift_ms unprobed. Need media: av_drift_ms= or telemetry. ` +
          `PRE_REGISTER fail: cannot bound drift (parent collapsed +133 vs healthy −30).`,
        health: h,
        value_kind: 'unprobed',
      };
    }
    const abs = Math.abs(h.av_drift_ms);
    if (abs > maxAbsDrift) {
      return {
        ok: false,
        reason: 'media_drift_unbounded',
        detail:
          `${tag}: |av_drift_ms|=${abs} > max=${maxAbsDrift} (raw=${h.av_drift_ms}). ` +
          `PRE_REGISTER fail: diverging drift class (parent collapsed +133; healthy −30). ` +
          `Derivation: max_abs=75 above |healthy|≤39, below collapsed 133.`,
        health: h,
        av_drift_ms: h.av_drift_ms,
        max_abs_drift_ms: maxAbsDrift,
        value_kind: 'measured',
      };
    }
  }

  return {
    ok: true,
    reason: 'media_health_ok',
    supply_ratio: h.supply_ratio,
    supply_ratio_src: h.supply_ratio_src,
    av_drift_ms: h.av_drift_ms,
    clock: h.clock,
    pid: h.pid,
    notes: notes.join('; '),
    health: h,
    min_supply_ratio: minRatio,
    max_abs_drift_ms: maxAbsDrift,
    value_kind: 'measured',
    derivation:
      'min_supply_ratio=0.90 from parent collapsed 0.72 vs healthy 0.99; ' +
      'max_abs_drift_ms=75 from healthy |−30…−39| vs collapsed +133',
  };
}

/**
 * PID change mid-suite → cycle INVALID (counters re-zeroed).
 */
function assertPidStable(baselinePid, samplePid, tag) {
  if (baselinePid == null || baselinePid < 0) {
    return {
      ok: true,
      note: 'baseline_unset',
      pid: samplePid,
      value_kind: samplePid > 0 ? 'measured' : 'unprobed',
    };
  }
  if (samplePid == null || samplePid < 0) {
    return {
      ok: false,
      invalid: true,
      reason: 'daemon_pid_unprobed',
      detail:
        `${tag}: pid unprobed while baseline=${baselinePid}. ` +
        `Cannot prove session survival — INVALID (not data).`,
      value_kind: 'unprobed',
    };
  }
  if (samplePid !== baselinePid) {
    return {
      ok: false,
      invalid: true,
      reason: 'daemon_pid_changed',
      detail:
        `${tag}: daemon pid ${baselinePid} → ${samplePid} mid-suite. ` +
        `INVALID: supervise CLEAN rc=0 exit + respawn re-zeroes droppedFrames_/presentCount_ ` +
        `(media_player.cpp). Do not average or flattering-score this cycle.`,
      before: baselinePid,
      after: samplePid,
      value_kind: 'measured',
    };
  }
  return { ok: true, pid: samplePid, value_kind: 'measured' };
}

function formatMediaHealth(r) {
  if (!r) return 'null';
  const bits = [
    `ok=${r.ok ? 1 : 0}`,
    `reason=${r.reason || 'NA'}`,
    r.invalid ? 'INVALID=1' : '',
    r.supply_ratio != null && Number.isFinite(r.supply_ratio)
      ? `supply_ratio=${Number(r.supply_ratio).toFixed(3)}`
      : '',
    r.av_drift_ms != null ? `av_drift_ms=${r.av_drift_ms}` : '',
    r.clock ? `clock=${r.clock}` : '',
    r.pid != null ? `pid=${r.pid}` : '',
    r.notes || '',
  ].filter(Boolean);
  return bits.join(' ');
}

function selfCheck() {
  const errs = [];
  // Parent healthy fixture
  const healthyLine =
    'media: frames=500 vfps=23.5 pfps=23.5 audio_s=10.0 wall_s=10.1 audio=on ' +
    'clock=av-lock av_drift_ms=-30 presents=490 drops=13 fps=24/1 session=3';
  const healthy = assertMediaHealth(parseMediaHealthText(healthyLine), 't_healthy', {
    minSupplyRatio: 0.9,
    maxAbsDriftMs: 75,
  });
  if (!healthy.ok) errs.push(`healthy_should_pass ${healthy.reason} ${healthy.detail}`);

  // Parent collapsed fixture (supply_ratio 0.72, drift +133)
  const collapsedLine =
    'media: frames=500 vfps=12.9 pfps=12.9 audio_s=7.2 wall_s=10.0 audio=on ' +
    'clock=av-lock av_drift_ms=133 presents=300 drops=1030 supply_ratio=0.72 fps=24/1 session=3';
  const collapsed = assertMediaHealth(parseMediaHealthText(collapsedLine), 't_collapsed', {
    minSupplyRatio: 0.9,
    maxAbsDriftMs: 75,
  });
  if (collapsed.ok || collapsed.reason !== 'media_supply_ratio_low') {
    errs.push(
      `collapsed_expected_supply_low got ok=${collapsed.ok} reason=${collapsed.reason}`
    );
  }

  // Drift-only collapse (ratio ok via explicit 0.95 but drift diverges)
  const driftLine =
    'media: frames=100 vfps=23 pfps=23 audio_s=5 wall_s=5.1 clock=av-lock ' +
    'av_drift_ms=133 supply_ratio=0.95 fps=24/1';
  const driftBad = assertMediaHealth(parseMediaHealthText(driftLine), 't_drift', {
    minSupplyRatio: 0.9,
    maxAbsDriftMs: 75,
  });
  if (driftBad.ok || driftBad.reason !== 'media_drift_unbounded') {
    errs.push(`drift_expected_unbounded got ${driftBad.reason}`);
  }

  // supply_bucket d_presents/expected
  const bucket =
    'media: supply_bucket wall_s=10 d_wall_s=1 d_frames=24 d_presents=17 ' +
    'expected_frames=24.0 supply_gap=7.0 av_drift_ms=-20 clock=av-lock';
  const b = assertMediaHealth(parseMediaHealthText(bucket), 't_bucket', {
    minSupplyRatio: 0.9,
    maxAbsDriftMs: 75,
  });
  // 17/24 = 0.708 → low
  if (b.ok || b.reason !== 'media_supply_ratio_low') {
    errs.push(`bucket_low_expected got ${b.reason} ratio=${b.supply_ratio}`);
  }

  // PID invalidate
  const pidOk = assertPidStable(100, 100, 't_pid');
  if (!pidOk.ok) errs.push('pid_stable_should_pass');
  const pidBad = assertPidStable(100, 200, 't_pid_swap');
  if (pidBad.ok || !pidBad.invalid || pidBad.reason !== 'daemon_pid_changed') {
    errs.push(`pid_swap_expected_INVALID got ${JSON.stringify(pidBad)}`);
  }

  // Unprobed must fail (never soft-green)
  const un = assertMediaHealth({ ok: false }, 't_un');
  if (un.ok || un.reason !== 'media_health_unprobed') {
    errs.push(`unprobed_expected_fail got ${un.reason}`);
  }

  if (errs.length) {
    const e = new Error(errs.join('; '));
    e.errs = errs;
    throw e;
  }
  return true;
}

module.exports = {
  parseMediaHealthText,
  parseMediaHealthFromLogText,
  captureMediaHealth,
  assertMediaHealth,
  assertPidStable,
  formatMediaHealth,
  selfCheck,
};

if (require.main === module) {
  try {
    selfCheck();
    console.log('media_health.js selfCheck OK');
    console.log(
      'PRE_REGISTER: collapsed supply_ratio=0.72 FAIL; healthy 0.99 PASS; ' +
        'drift +133 FAIL; pid swap INVALID; unprobed FAIL'
    );
    process.exit(0);
  } catch (e) {
    console.error('media_health.js selfCheck FAIL', e.message);
    process.exit(1);
  }
}
