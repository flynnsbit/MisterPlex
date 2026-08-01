'use strict';

/**
 * Frame ledger capture for transition cycles.
 *
 * Daemon emits (1 Hz media line + /player/telemetry when deployed):
 *   frames presents drops publish_misses residual lifetime_* session=
 *
 * LIVE RBF c5382bee field derivations (parent fleet; name+derivation required):
 *   frames_done  = PLXD[63:48] = vsync counter, NOT bank swaps
 *                  (stale-detector blind: freeze looks "live")
 *   presents     = ARM publish/present call returned, NOT glass
 *   drops        = ARM-supply accounting, NOT display
 *   residual     = frames - presents - drops (ARM identity)
 *   unaccounted  = residual printed twice (media_player.cpp) ≡ publish_misses
 * Until a new RBF lands, residual/presents/drops/frames_done are VOID as video
 * evidence (E2E_PLXD_FRAMES_VOID=1 default). Suite gates pid/exe/session/playing only.
 *
 * session must not change mid-cycle during continuous play (daemon self-exit
 * respawn resets counters — false pass without this check).
 * Companion has NO /status endpoint — only /resources, timeline, telemetry.
 *
 * Glass vertical row ceiling (parent push_frame even/odd solid invert, std=0) is
 * NOT observed by any ledger field — only HDMI capture.
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
  // Numeric fields.
  const re = /([A-Za-z_][A-Za-z0-9_]*)=(-?\d+(?:\.\d+)?)/g;
  let m;
  while ((m = re.exec(s)) !== null) {
    const k = m[1];
    const v = m[2].includes('.') ? parseFloat(m[2]) : parseInt(m[2], 10);
    out[k] = v;
  }
  // String fields (exe path from readlink /proc/self/exe).
  const exeM = s.match(/\bexe=([^\s]+)/);
  if (exeM) out.exe = exeM[1];
  const decM = s.match(/\bdecode=(\d+x\d+)/i);
  if (decM) out.decode = decM[1];
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
  const exe = raw.exe != null ? String(raw.exe) : '';
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
    // pid/exe come from the live companion process (not host pidof/cmdline).
    pid: intOr(raw.pid, -1),
    playing: intOr(raw.playing, -1),
    exe,
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
  // No /status on companion :3005 (parent). Prefer telemetry only.
  const urls = [`${daemonBase}/player/telemetry`, `${daemonBase}/telemetry`];
  for (const u of urls) {
    const r = await httpGet(u);
    if (
      r.status === 200 &&
      r.body &&
      /frames=|session=|presents=|pid=|playing=/.test(r.body)
    ) {
      const kv = parseKv(r.body);
      kv._line = r.body.trim().split('\n')[0];
      const snap = normalizeSnap(kv, 'http');
      // Accept pid/session-only snaps when frames void / missing.
      if (snap.ok || snap.session >= 0 || snap.pid > 0) return snap;
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
    exe: '',
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
 * Live RBF packs bank_vsync into frames_done — residual/presents/drops are not
 * video evidence. Default void=1. Set E2E_PLXD_FRAMES_VOID=0 only after a new
 * RBF where frames_done is a real frame counter again.
 */
function plxdFramesVoid() {
  const v = process.env.E2E_PLXD_FRAMES_VOID;
  if (v === undefined || v === null || v === '') return true;
  return /^(1|true|yes|on)$/i.test(String(v));
}

/**
 * Assert session/pid stability across a continuous-play window.
 * Residual identity is VOID by default (E2E_PLXD_FRAMES_VOID=1) on live RBF.
 * @returns {{ ok:true } | { ok:false, reason, detail }}
 */
function assertLedgerWindow(start, end, tag) {
  if (!start || !end) {
    return { ok: false, reason: 'ledger_missing', detail: `${tag}: null snapshot` };
  }

  // Prefer pid/session path when frames are void or unprobed.
  const identityOk =
    (start.pid > 0 && end.pid > 0) ||
    (start.session >= 0 && end.session >= 0) ||
    (start.ok && end.ok);

  if (!identityOk) {
    if (requireLedger()) {
      return {
        ok: false,
        reason: 'ledger_unprobed',
        detail:
          `${tag}: ledger unprobed (source start=${start.source} end=${end.source}). ` +
          `Need GET /player/telemetry with pid= and/or session=. ` +
          `Set E2E_REQUIRE_LEDGER=0 to soft-skip (not a pass).`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: ledger unprobed — E2E_REQUIRE_LEDGER=0 soft-skip (NOT a pass)`,
    };
  }

  // Process PID must not change (supervise CLEAN rc=0 exit + respawn).
  if (start.pid > 0 && end.pid > 0 && start.pid !== end.pid) {
    return {
      ok: false,
      reason: 'daemon_pid_changed',
      detail:
        `${tag}: daemon pid ${start.pid} → ${end.pid} mid-window ` +
        `exe_start=${start.exe || '?'} exe_end=${end.exe || '?'} ` +
        `(self-exit rc=0 / respawn — counters reset; soak invalid)`,
    };
  }
  if (start.exe && end.exe && start.exe !== end.exe) {
    return {
      ok: false,
      reason: 'daemon_exe_changed',
      detail:
        `${tag}: daemon exe changed while pid stable? ${start.exe} → ${end.exe} ` +
        `(unexpected binary replace mid-window)`,
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

  // Lifetime must not regress (process restart) — only when field is real.
  if (
    !plxdFramesVoid() &&
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

  // ── residual / frames / presents / drops ──────────────────────────────
  if (plxdFramesVoid()) {
    return {
      ok: true,
      residual: end.residual,
      session: end.session,
      pid: end.pid,
      note:
        'plxd_frames_void: residual/presents/drops NOT evidence ' +
        '(live RBF frames_done=bank_vsync_count; parent c5382bee). ' +
        'pid+session only. Set E2E_PLXD_FRAMES_VOID=0 after fixed RBF.',
      plxd_frames_void: true,
    };
  }

  if (!start.ok || !end.ok) {
    if (requireLedger()) {
      return {
        ok: false,
        reason: 'ledger_unprobed',
        detail: `${tag}: frames/presents/drops incomplete with E2E_PLXD_FRAMES_VOID=0`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: frame ledger incomplete — soft-skip`,
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

  let slack = parseInt(process.env.E2E_LEDGER_RESIDUAL_SLACK || '2', 10);
  if (!Number.isFinite(slack) || slack < 0) slack = 2;

  if (residual === 0) {
    return { ok: true, residual: 0, session: end.session, pid: end.pid };
  }

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
  const exeShort = s.exe ? s.exe.replace(/^.*\//, '') : '?';
  return (
    `src=${s.source} pid=${s.pid} exe=${exeShort} playing=${s.playing} frames=${s.frames} presents=${s.presents} ` +
    `drops=${s.drops} pub_miss=${s.publish_misses} residual=${s.residual} session=${s.session} ` +
    `life_f=${s.lifetime_frames}`
  );
}

/**
 * Whole-run process identity. Baseline from first successful telemetry (pid +
 * exe from the companion process itself via getpid + readlink /proc/self/exe).
 * Never use host pidof/cmdline — flock contains "misterplexd" (ERROR 14).
 */
function requirePid() {
  return /^(1|true|yes|on)$/i.test(String(process.env.E2E_REQUIRE_PID || '1'));
}

/**
 * @param {number} baselinePid
 * @param {{pid?:number,exe?:string}} snap
 * @param {string} tag
 * @param {{baselineExe?: string}} [opts]
 */
function assertPidUnchanged(baselinePid, snap, tag, opts = {}) {
  const baselineExe = opts.baselineExe || '';
  if (!snap || snap.pid === undefined || snap.pid < 0) {
    if (requirePid()) {
      return {
        ok: false,
        reason: 'daemon_pid_unprobed',
        detail:
          `${tag}: telemetry missing pid= (deploy daemon with pid+exe in /player/telemetry). ` +
          `Identity is self-reported by the HTTP process (readlink /proc/self/exe) — ` +
          `not host pidof/cmdline. Set E2E_REQUIRE_PID=0 to soft-skip (NOT a pass).`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: pid unprobed — E2E_REQUIRE_PID=0 soft-skip`,
    };
  }
  if (baselinePid == null || baselinePid < 0) {
    return {
      ok: true,
      pid: snap.pid,
      exe: snap.exe || '',
      note: 'baseline_set',
    };
  }
  if (snap.pid !== baselinePid) {
    return {
      ok: false,
      reason: 'daemon_pid_changed',
      detail:
        `${tag}: daemon pid changed ${baselinePid} → ${snap.pid} ` +
        `exe_was=${baselineExe || '?'} exe_now=${snap.exe || '?'} ` +
        `(supervise CLEAN exit rc=0 + respawn; droppedFrames_/presentCount_ reset per stream — ` +
        `media_player.cpp present/drop counters; N-loop stats invalid if averaged over respawn)`,
    };
  }
  if (baselineExe && snap.exe && baselineExe !== snap.exe) {
    return {
      ok: false,
      reason: 'daemon_exe_changed',
      detail:
        `${tag}: pid=${snap.pid} stable but exe changed ${baselineExe} → ${snap.exe} ` +
        `(binary replaced under same pid? or bad baseline)`,
    };
  }
  // Soft warn if exe does not look like misterplexd (mis-wired handler).
  if (snap.exe && !/misterplexd/i.test(snap.exe) && snap.exe !== 'UNKNOWN') {
    return {
      ok: false,
      reason: 'daemon_exe_not_misterplexd',
      detail:
        `${tag}: telemetry exe=${snap.exe} does not contain "misterplexd" ` +
        `(refusing flock/wrapper false identity — ERROR 14 class). ` +
        `exe must be readlink(/proc/self/exe) of the real daemon.`,
    };
  }
  return { ok: true, pid: snap.pid, exe: snap.exe || baselineExe || '' };
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
  plxdFramesVoid,
};
