'use strict';

/**
 * Frame ledger capture for transition cycles.
 *
 * Daemon emits (1 Hz media line + /player/telemetry when deployed):
 *   frames presents drops publish_misses residual lifetime_* session=
 *
 * Identity: residual == frames - presents - drops
 * Parent gate: residual == 0 (or residual == publish_misses when misses counted).
 * session must not change mid-cycle during continuous play (daemon self-exit
 * respawn resets counters — false pass without this check).
 */

const http = require('http');
const fs = require('fs');

function httpGet(url, timeoutMs = 4000) {
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
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

function parseKv(text) {
  const out = {};
  const s = String(text || '');
  const re = /([A-Za-z_][A-Za-z0-9_]*)=(-?\d+(?:\.\d+)?)/g;
  let m;
  while ((m = re.exec(s)) !== null) {
    const k = m[1];
    const v = m[2].includes('.') ? parseFloat(m[2]) : parseInt(m[2], 10);
    out[k] = v;
  }
  return out;
}

function normalizeSnap(raw, source) {
  const frames = intOr(raw.frames, -1);
  const presents = intOr(raw.presents, -1);
  const drops = intOr(raw.drops, -1);
  const publish_misses = intOr(raw.publish_misses, raw.publishMisses, 0);
  let residual = intOr(raw.residual, NaN);
  if (!Number.isFinite(residual) && frames >= 0 && presents >= 0 && drops >= 0) {
    residual = frames - presents - drops;
  }
  return {
    ok: frames >= 0 && presents >= 0 && drops >= 0,
    source,
    frames,
    presents,
    drops,
    publish_misses: Number.isFinite(publish_misses) ? publish_misses : 0,
    residual: Number.isFinite(residual) ? residual : null,
    lifetime_frames: intOr(raw.lifetime_frames, -1),
    lifetime_presents: intOr(raw.lifetime_presents, -1),
    lifetime_drops: intOr(raw.lifetime_drops, -1),
    lifetime_publish_misses: intOr(raw.lifetime_publish_misses, -1),
    session: intOr(raw.session, -1),
    // Process identity — supervise CLEAN rc=0 exits respawn and re-zero counters.
    pid: intOr(raw.pid, -1),
    raw: String(raw._line || '').slice(0, 300),
  };
}

function intOr(...vals) {
  for (const v of vals) {
    if (v === undefined || v === null || v === '') continue;
    if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v);
    const n = parseInt(String(v), 10);
    if (Number.isFinite(n)) return n;
  }
  return vals[vals.length - 1];
}

/** Parse last media:/telemetry line from a log blob. */
function parseLedgerFromLogText(text) {
  const lines = String(text || '').split(/\r?\n/);
  let best = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!/frames=\d+/.test(line)) continue;
    if (!/presents=\d+|drops=\d+|session=\d+/.test(line) && !/media:/.test(line)) continue;
    const kv = parseKv(line);
    kv._line = line;
    const snap = normalizeSnap(kv, 'log');
    if (snap.ok || snap.session >= 0) {
      best = snap;
      break;
    }
  }
  return best;
}

async function fetchLedgerHttp(daemonBase) {
  const urls = [
    `${daemonBase}/player/telemetry`,
    `${daemonBase}/telemetry`,
    `${daemonBase}/player/status`,
  ];
  for (const u of urls) {
    const r = await httpGet(u);
    if (r.status === 200 && r.body && /frames=|session=|presents=/.test(r.body)) {
      const kv = parseKv(r.body);
      kv._line = r.body.trim().split('\n')[0];
      const snap = normalizeSnap(kv, 'http');
      if (snap.ok || snap.session >= 0) return snap;
    }
  }
  return null;
}

function fetchLedgerFromLogFile(path) {
  if (!path || !fs.existsSync(path)) return null;
  try {
    const text = fs.readFileSync(path, 'utf8');
    // Prefer last 64KB for large tails.
    const slice = text.length > 65536 ? text.slice(-65536) : text;
    return parseLedgerFromLogText(slice);
  } catch (_) {
    return null;
  }
}

/**
 * Capture ledger snapshot. Prefer HTTP telemetry; fall back to E2E_DAEMON_LOG.
 */
async function captureLedger(cfg) {
  const base = `http://${cfg.misterHost}:${cfg.misterPort}`;
  const httpSnap = await fetchLedgerHttp(base);
  if (httpSnap) return httpSnap;
  const logPath =
    process.env.E2E_DAEMON_LOG ||
    process.env.E2E_LEDGER_LOG ||
    cfg.daemonLogPath ||
    '';
  const logSnap = fetchLedgerFromLogFile(logPath);
  if (logSnap) return logSnap;
  return {
    ok: false,
    source: 'unprobed',
    frames: -1,
    presents: -1,
    drops: -1,
    publish_misses: 0,
    residual: null,
    lifetime_frames: -1,
    lifetime_presents: -1,
    lifetime_drops: -1,
    lifetime_publish_misses: -1,
    session: -1,
    pid: -1,
    raw: '',
  };
}

function requireLedger() {
  return /^(1|true|yes|on)$/i.test(String(process.env.E2E_REQUIRE_LEDGER || '1'));
}

function allowPublishMissResidual() {
  return /^(1|true|yes|on)$/i.test(String(process.env.E2E_LEDGER_ALLOW_PUBLISH_MISS || '1'));
}

/**
 * Assert residual identity and session stability across a continuous-play window.
 * @returns {{ ok:true } | { ok:false, reason, detail }}
 */
function assertLedgerWindow(start, end, tag) {
  if (!start || !end) {
    return { ok: false, reason: 'ledger_missing', detail: `${tag}: null snapshot` };
  }
  if (!start.ok || !end.ok) {
    if (requireLedger()) {
      return {
        ok: false,
        reason: 'ledger_unprobed',
        detail:
          `${tag}: ledger unprobed (source start=${start.source} end=${end.source}). ` +
          `Deploy daemon with GET /player/telemetry or export E2E_DAEMON_LOG with media lines ` +
          `containing frames/presents/drops/session. Set E2E_REQUIRE_LEDGER=0 to soft-skip (not a pass).`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: ledger unprobed — E2E_REQUIRE_LEDGER=0 soft-skip (NOT a pass of residual)`,
    };
  }

  // Process PID must not change (supervise CLEAN rc=0 exit + respawn).
  if (start.pid > 0 && end.pid > 0 && start.pid !== end.pid) {
    return {
      ok: false,
      reason: 'daemon_pid_changed',
      detail:
        `${tag}: daemon pid ${start.pid} → ${end.pid} mid-window ` +
        `(self-exit rc=0 / respawn — droppedFrames_/presentCount_ reset; soak counters invalid)`,
    };
  }

  // Session must not change mid continuous-play (daemon respawn / self-exit).
  if (start.session >= 0 && end.session >= 0 && start.session !== end.session) {
    return {
      ok: false,
      reason: 'ledger_session_changed',
      detail:
        `${tag}: session changed mid-cycle ${start.session} → ${end.session} ` +
        `(daemon may have self-exited rc=0 and respawned; counters reset — false pass risk)`,
    };
  }

  // Lifetime must not regress (process restart).
  if (
    start.lifetime_frames >= 0 &&
    end.lifetime_frames >= 0 &&
    end.lifetime_frames < start.lifetime_frames
  ) {
    return {
      ok: false,
      reason: 'ledger_lifetime_regressed',
      detail:
        `${tag}: lifetime_frames ${start.lifetime_frames} → ${end.lifetime_frames} ` +
        `(process restart mid-cycle)`,
    };
  }

  const residual = end.residual;
  if (residual === null || residual === undefined) {
    return {
      ok: false,
      reason: 'ledger_residual_unknown',
      detail: `${tag}: cannot compute residual from end snap`,
    };
  }

  // Recompute identity from components (detect bad telemetry).
  const recomputed = end.frames - end.presents - end.drops;
  if (recomputed !== residual) {
    return {
      ok: false,
      reason: 'ledger_residual_mismatch',
      detail:
        `${tag}: residual field ${residual} != frames-presents-drops ${recomputed} ` +
        `(frames=${end.frames} presents=${end.presents} drops=${end.drops})`,
    };
  }

  // Parent gate: residual == frames - presents - drops == 0 (accounted).
  // Live mid-play may have 0..slack frames in the present pipeline; unexplained
  // gap above slack (after publish_misses) is a real ledger hole / respawn glitch.
  let slack = parseInt(process.env.E2E_LEDGER_RESIDUAL_SLACK || '2', 10);
  if (!Number.isFinite(slack) || slack < 0) slack = 2;

  if (residual === 0) {
    return { ok: true, residual: 0, session: end.session, pid: end.pid };
  }

  // residual == publish_misses is the product identity when publishes fail.
  if (allowPublishMissResidual() && residual === end.publish_misses) {
    return {
      ok: true,
      residual,
      publish_misses: end.publish_misses,
      session: end.session,
      pid: end.pid,
      note: 'residual_equals_publish_misses',
    };
  }

  const unexplained = residual - (allowPublishMissResidual() ? end.publish_misses : 0);
  if (unexplained >= 0 && unexplained <= slack) {
    return {
      ok: true,
      residual,
      session: end.session,
      pid: end.pid,
      note: `residual_within_slack=${slack}`,
    };
  }

  return {
    ok: false,
    reason: 'ledger_residual_nonzero',
    detail:
      `${tag}: residual=${residual} unexplained=${unexplained} ` +
      `(frames=${end.frames} presents=${end.presents} drops=${end.drops} ` +
      `publish_misses=${end.publish_misses}) — want residual==0` +
      (allowPublishMissResidual() ? ' or residual==publish_misses' : '') +
      ` or unexplained<=${slack}`,
  };
}

function formatSnap(s) {
  if (!s) return '(null)';
  return (
    `src=${s.source} pid=${s.pid} frames=${s.frames} presents=${s.presents} drops=${s.drops} ` +
    `pub_miss=${s.publish_misses} residual=${s.residual} session=${s.session} ` +
    `life_f=${s.lifetime_frames}`
  );
}

/**
 * Whole-run PID stability. baselinePid from first successful telemetry; each
 * later snap must match. Missing pid with E2E_REQUIRE_PID=1 → fail.
 */
function requirePid() {
  return /^(1|true|yes|on)$/i.test(String(process.env.E2E_REQUIRE_PID || '1'));
}

function assertPidUnchanged(baselinePid, snap, tag) {
  if (!snap || snap.pid === undefined || snap.pid < 0) {
    if (requirePid()) {
      return {
        ok: false,
        reason: 'daemon_pid_unprobed',
        detail:
          `${tag}: telemetry missing pid= (deploy daemon with pid in /player/telemetry). ` +
          `Set E2E_REQUIRE_PID=0 to soft-skip (NOT a pass of process stability).`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: pid unprobed — E2E_REQUIRE_PID=0 soft-skip`,
    };
  }
  if (baselinePid == null || baselinePid < 0) {
    return { ok: true, pid: snap.pid, note: 'baseline_set' };
  }
  if (snap.pid !== baselinePid) {
    return {
      ok: false,
      reason: 'daemon_pid_changed',
      detail:
        `${tag}: daemon pid changed ${baselinePid} → ${snap.pid} ` +
        `(supervise CLEAN exit rc=0 + respawn; counters reset — soak/UI stats invalid)`,
    };
  }
  return { ok: true, pid: snap.pid };
}

module.exports = {
  captureLedger,
  assertLedgerWindow,
  assertPidUnchanged,
  requirePid,
  parseLedgerFromLogText,
  parseKv,
  formatSnap,
  requireLedger,
};
