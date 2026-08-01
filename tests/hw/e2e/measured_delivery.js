'use strict';

/**
 * MEASURED_DELIVERY + session_epoch parsing (daemon media lines / telemetry).
 *
 * Parent fact: PMS can deliver a third geometry matching neither request nor
 * library_media (e.g. request 624x480, library 320x240 → delivered 426x240).
 * Asserting the *request* proves nothing. Gate on measured delivery only.
 *
 * Log forms (both accepted):
 *   media: MEASURED_DELIVERY delivered_geom=426x240 src=ffmpeg_banner bytes=… desync_risk=0 …
 *   media: MEASURED_DELIVERY 426x240 bytes=… coded_bytes=… identity_skip=0 desync_risk=0
 * 1 Hz media / telemetry:
 *   measured_delivery=426x240 desync_risk=0 delivery_verified=1 session_epoch=1.3
 *
 * desync_risk=1 / PIPE_DESYNC_RISK → hard FAIL.
 * Suite never treats unprobed delivery as PASS when require=1.
 */

const fs = require('fs');
const http = require('http');

function truthy(v, def = false) {
  if (v === undefined || v === null || v === '') return def;
  return /^(1|true|yes|on)$/i.test(String(v));
}

function parseWxH(s) {
  const m = String(s || '')
    .trim()
    .match(/^(\d+)\s*[x×]\s*(\d+)$/i);
  if (!m) return null;
  return { w: parseInt(m[1], 10), h: parseInt(m[2], 10), text: `${m[1]}x${m[2]}` };
}

/**
 * Parse one line / blob for measured delivery fields.
 * @returns {null | object}
 */
function parseMeasuredDeliveryText(text) {
  const s = String(text || '');
  if (!s.trim()) return null;

  let best = null;
  const lines = s.split(/\r?\n/);
  // Prefer last MEASURED_DELIVERY_FINAL, else last MEASURED_DELIVERY, else last measured_delivery=.
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let hit = null;

    // Explicit MEASURED_DELIVERY banner (preferred).
    let m = line.match(
      /MEASURED_DELIVERY(?:_FINAL)?\s+delivered_geom=(\d+x\d+|NO-DATA)/i
    );
    if (m) {
      hit = {
        kind: /FINAL/i.test(line) ? 'MEASURED_DELIVERY_FINAL' : 'MEASURED_DELIVERY',
        delivered_geom: m[1] === 'NO-DATA' ? null : parseWxH(m[1]),
        line: line.trim().slice(0, 400),
      };
    }
    if (!hit) {
      // Parent shorthand: MEASURED_DELIVERY 426x240 bytes=…
      m = line.match(/MEASURED_DELIVERY(?:_FINAL)?\s+(\d+x\d+)\b/i);
      if (m) {
        hit = {
          kind: /FINAL/i.test(line) ? 'MEASURED_DELIVERY_FINAL' : 'MEASURED_DELIVERY',
          delivered_geom: parseWxH(m[1]),
          line: line.trim().slice(0, 400),
        };
      }
    }
    if (!hit && /\bmeasured_delivery=/.test(line)) {
      m = line.match(/\bmeasured_delivery=(\d+x\d+|pending|NO-DATA)\b/i);
      if (m) {
        const g = m[1];
        hit = {
          kind: 'measured_delivery_kv',
          delivered_geom: /pending|NO-DATA/i.test(g) ? null : parseWxH(g),
          line: line.trim().slice(0, 400),
        };
      }
    }
    // Legacy DELIVERED_GEOM stream=
    if (!hit) {
      m = line.match(/DELIVERED_GEOM\s+stream=(\d+x\d+)/i);
      if (m) {
        hit = {
          kind: 'DELIVERED_GEOM',
          delivered_geom: parseWxH(m[1]),
          line: line.trim().slice(0, 400),
        };
      }
    }
    // Stream #0:0 … 426x240
    if (!hit) {
      m = line.match(/Stream\s+#0:0[^\n]*?(\d{2,5})x(\d{2,5})/i);
      if (m) {
        hit = {
          kind: 'ffmpeg_stream_banner',
          delivered_geom: parseWxH(`${m[1]}x${m[2]}`),
          line: line.trim().slice(0, 400),
        };
      }
    }
    // PIPE_DESYNC_RISK measured=WxH (hard product fail line)
    if (!hit && /PIPE_DESYNC/i.test(line)) {
      m = line.match(/measured=(\d+x\d+)/i) || line.match(/\b(\d{2,5}x\d{2,5})\b/);
      hit = {
        kind: 'PIPE_DESYNC',
        delivered_geom: m ? parseWxH(m[1]) : null,
        line: line.trim().slice(0, 400),
        pipe_desync: true,
      };
    }

    if (!hit) continue;

    const riskM = line.match(/\bdesync_risk=([01])\b/);
    hit.desync_risk = riskM ? parseInt(riskM[1], 10) : null;
    const idM = line.match(/\bidentity_skip=([01])\b/);
    hit.identity_skip = idM ? parseInt(idM[1], 10) : null;
    const verM = line.match(/\bdelivery_verified=([01])\b/);
    hit.delivery_verified = verM ? parseInt(verM[1], 10) : null;
    const bytesM = line.match(/\bbytes=(\d+)\b/);
    hit.bytes = bytesM ? parseInt(bytesM[1], 10) : null;
    const codedM = line.match(/\bcoded_bytes=(\d+)\b/);
    hit.coded_bytes = codedM ? parseInt(codedM[1], 10) : null;
    const seM = line.match(/\bsession_epoch=([^\s]+)/);
    hit.session_epoch = seM ? seM[1] : null;
    const pipe = /PIPE_DESYNC/i.test(line);
    hit.pipe_desync = pipe;
    hit.line_index = i;
    best = hit;
  }

  // Whole-blob session_epoch / desync if last line lacked them.
  if (best) {
    if (best.session_epoch == null) {
      const se = s.match(/\bsession_epoch=([^\s]+)/);
      if (se) best.session_epoch = se[1];
    }
    if (best.desync_risk == null) {
      const r = s.match(/\bdesync_risk=([01])\b/);
      if (r) best.desync_risk = parseInt(r[1], 10);
    }
    if (/PIPE_DESYNC/i.test(s)) best.pipe_desync = true;
  }
  return best;
}

function parseSessionEpochText(text) {
  const s = String(text || '');
  // Prefer last session_epoch=
  let last = null;
  const re = /\bsession_epoch=([^\s]+)/g;
  let m;
  while ((m = re.exec(s)) !== null) last = m[1];
  return last;
}

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

/**
 * Resolve measured delivery from env, daemon log, or HTTP telemetry.
 * @param {{misterHost?:string,misterPort?:number,daemonLogPath?:string}} cfg
 */
async function resolveMeasuredDelivery(cfg = {}) {
  // 1) Explicit env (parent already measured).
  const envGeom = String(process.env.E2E_DELIVERED_GEOM || process.env.E2E_MEASURED_DELIVERY || '').trim();
  if (envGeom) {
    const g = parseWxH(envGeom);
    const riskEnv = process.env.E2E_DESYNC_RISK;
    return {
      ok: !!g,
      source: 'env',
      delivered_geom: g,
      desync_risk:
        riskEnv !== undefined && riskEnv !== '' ? parseInt(String(riskEnv), 10) : null,
      delivery_verified: 1,
      session_epoch: process.env.E2E_SESSION_EPOCH || null,
      raw: `E2E_DELIVERED_GEOM=${envGeom}`,
      value_kind: 'caller-supplied',
    };
  }

  // 2) Daemon log file (parent-cleared snip — preferred when telemetry 404).
  const logPath =
    process.env.E2E_DAEMON_LOG ||
    process.env.E2E_DAEMON_LOG_SNIPPET ||
    process.env.E2E_LEDGER_LOG ||
    cfg.daemonLogPath ||
    '';
  if (logPath && fs.existsSync(logPath)) {
    let text = '';
    try {
      text = fs.readFileSync(logPath, 'utf8');
    } catch (_) {
      text = '';
    }
    const slice = text.length > 262144 ? text.slice(-262144) : text;
    const hit = parseMeasuredDeliveryText(slice);
    if (hit && hit.delivered_geom) {
      return {
        ok: true,
        source: 'daemon_log',
        path: logPath,
        delivered_geom: hit.delivered_geom,
        desync_risk: hit.desync_risk,
        delivery_verified: hit.delivery_verified,
        identity_skip: hit.identity_skip,
        bytes: hit.bytes,
        coded_bytes: hit.coded_bytes,
        session_epoch: hit.session_epoch || parseSessionEpochText(slice),
        pipe_desync: !!hit.pipe_desync,
        kind: hit.kind,
        raw: hit.line,
        value_kind: 'measured',
      };
    }
    // desync-only / pipe error without geom still reportable
    if (hit && (hit.desync_risk === 1 || hit.pipe_desync)) {
      return {
        ok: false,
        source: 'daemon_log',
        path: logPath,
        delivered_geom: hit.delivered_geom,
        desync_risk: hit.desync_risk,
        pipe_desync: !!hit.pipe_desync,
        kind: hit.kind,
        raw: hit.line,
        reason: 'desync_without_geom',
        value_kind: 'measured',
      };
    }
    return {
      ok: false,
      source: 'daemon_log_empty',
      path: logPath,
      delivered_geom: null,
      desync_risk: null,
      reason: 'no_MEASURED_DELIVERY_in_log',
      value_kind: 'measured',
    };
  }

  // 3) HTTP telemetry (may 404 on older deploys — not a soft pass).
  const host = cfg.misterHost || process.env.MISTER_HOST || '192.168.1.183';
  const port = parseInt(cfg.misterPort || process.env.MISTER_PORT || '3005', 10);
  const base = `http://${host}:${port}`;
  for (const path of ['/player/telemetry', '/telemetry']) {
    const r = await httpGet(`${base}${path}`);
    if (r.status === 200 && r.body) {
      const hit = parseMeasuredDeliveryText(r.body);
      const se = (hit && hit.session_epoch) || parseSessionEpochText(r.body);
      if (hit && hit.delivered_geom) {
        return {
          ok: true,
          source: 'http_telemetry',
          path: `${base}${path}`,
          delivered_geom: hit.delivered_geom,
          desync_risk: hit.desync_risk,
          delivery_verified: hit.delivery_verified,
          session_epoch: se,
          pipe_desync: !!hit.pipe_desync,
          kind: hit.kind || 'telemetry',
          raw: String(r.body).trim().slice(0, 400),
          value_kind: 'measured',
        };
      }
      // telemetry without measured_delivery yet
      if (/\bmeasured_delivery=pending\b/i.test(r.body) || /delivery_verified=0/.test(r.body)) {
        return {
          ok: false,
          source: 'http_telemetry_pending',
          path: `${base}${path}`,
          delivered_geom: null,
          desync_risk: hit ? hit.desync_risk : null,
          session_epoch: se,
          reason: 'measured_delivery_pending',
          raw: String(r.body).trim().slice(0, 400),
          value_kind: 'measured',
        };
      }
    }
  }

  return {
    ok: false,
    source: 'unprobed',
    delivered_geom: null,
    desync_risk: null,
    session_epoch: null,
    reason:
      'no E2E_DELIVERED_GEOM / E2E_DAEMON_LOG MEASURED_DELIVERY / telemetry measured_delivery',
    value_kind: 'unprobed',
  };
}

/**
 * Assert measured delivery is present and healthy.
 * @returns {{ok:true, ...}|{ok:false, reason, detail}}
 */
function assertMeasuredDelivery(md, opts = {}) {
  const tag = opts.tag || 'measured_delivery';
  const require = opts.require != null ? !!opts.require : truthy(process.env.E2E_REQUIRE_MEASURED_DELIVERY, false);
  const expectGeom = opts.expectGeom ? parseWxH(opts.expectGeom) : null;
  // Optional: fail if delivered equals bank identity when testing non-bank assets.
  const rejectBank = opts.rejectBankGeom ? parseWxH(opts.rejectBankGeom) : null;

  if (!md || !md.ok || !md.delivered_geom) {
    if (require) {
      return {
        ok: false,
        reason: 'measured_delivery_unprobed',
        detail:
          `${tag}: MEASURED_DELIVERY required but unprobed ` +
          `(source=${md && md.source ? md.source : 'null'} reason=${md && md.reason ? md.reason : 'n/a'}). ` +
          `Remediation: clear daemon log before cast; after PLAY copy lines matching ` +
          `MEASURED_DELIVERY|measured_delivery=|desync_risk=|session_epoch= to a host file; ` +
          `export E2E_DAEMON_LOG=/path/to/snip OR E2E_DELIVERED_GEOM=WxH E2E_DESYNC_RISK=0. ` +
          `Asserting request/library geometry is NOT a substitute (PMS may deliver a third size).`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: measured delivery unprobed — NOT a pass of geometry (require=0)`,
      md,
    };
  }

  if (md.pipe_desync || md.desync_risk === 1) {
    return {
      ok: false,
      reason: 'pipe_desync_risk',
      detail:
        `${tag}: desync_risk=1 or PIPE_DESYNC ` +
        `delivered=${md.delivered_geom.text} identity_skip=${md.identity_skip != null ? md.identity_skip : 'NA'} ` +
        `bytes=${md.bytes != null ? md.bytes : 'NA'} coded_bytes=${md.coded_bytes != null ? md.coded_bytes : 'NA'} ` +
        `source=${md.source} raw=${String(md.raw || '').slice(0, 200)}`,
    };
  }

  if (expectGeom) {
    if (
      md.delivered_geom.w !== expectGeom.w ||
      md.delivered_geom.h !== expectGeom.h
    ) {
      return {
        ok: false,
        reason: 'measured_delivery_mismatch',
        detail:
          `${tag}: delivered ${md.delivered_geom.text} != expect ${expectGeom.text} ` +
          `(source=${md.source} value_kind=${md.value_kind || 'measured'})`,
      };
    }
  }

  if (
    rejectBank &&
    md.delivered_geom.w === rejectBank.w &&
    md.delivered_geom.h === rejectBank.h
  ) {
    return {
      ok: false,
      reason: 'measured_delivery_bank_identity',
      detail:
        `${tag}: delivered ${md.delivered_geom.text} equals bank ${rejectBank.text} — ` +
        `real-geom arm expected crop/pad/scale path (identity is the favourable fixture case)`,
    };
  }

  return {
    ok: true,
    delivered: md.delivered_geom.text,
    desync_risk: md.desync_risk != null ? md.desync_risk : 0,
    source: md.source,
    session_epoch: md.session_epoch || null,
    value_kind: md.value_kind || 'measured',
    md,
  };
}

/**
 * Session epoch must not change across a continuous-play window.
 * stop→play may bump stream_seq (new epoch) — do not use this across stop.
 */
function assertSessionEpochUnchanged(startEpoch, endEpoch, tag = 'session_epoch', opts = {}) {
  const a = startEpoch == null || startEpoch === '' ? null : String(startEpoch);
  const b = endEpoch == null || endEpoch === '' ? null : String(endEpoch);
  // Default soft when unprobed — callers with cfg.requireSessionEpoch hard-fail.
  const require =
    opts.require != null
      ? !!opts.require
      : truthy(process.env.E2E_REQUIRE_SESSION_EPOCH, false);

  if (a == null && b == null) {
    if (require) {
      return {
        ok: false,
        reason: 'session_epoch_unprobed',
        detail:
          `${tag}: session_epoch missing on both ends. Need media/supply_bucket/telemetry ` +
          `session_epoch= (process_epoch.stream_seq). Export E2E_DAEMON_LOG snip or deploy ` +
          `telemetry with session_epoch. Set E2E_REQUIRE_SESSION_EPOCH=0 only to soft-skip (NOT a pass).`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: session_epoch unprobed — E2E_REQUIRE_SESSION_EPOCH=0 soft-skip (NOT a pass)`,
    };
  }
  if (a == null || b == null) {
    if (require) {
      return {
        ok: false,
        reason: 'session_epoch_partial',
        detail: `${tag}: session_epoch partial start=${a || 'NA'} end=${b || 'NA'}`,
      };
    }
    return {
      ok: true,
      softSkip: true,
      detail: `${tag}: session_epoch partial — soft-skip`,
    };
  }
  if (a !== b) {
    return {
      ok: false,
      reason: 'session_epoch_changed',
      detail:
        `${tag}: session_epoch ${a} → ${b} mid continuous-play window ` +
        `(daemon self-exit/respawn or stream restart — drops/presents re-zeroed; ` +
        `any spanning assert is invalid). media_player session_epoch=process_epoch.stream_seq`,
    };
  }
  return { ok: true, session_epoch: a, value_kind: 'measured' };
}

/** Default real BBB / non-fixture keys parent named. */
const DEFAULT_REAL_GEOM_KEYS = ['29', '30', '31', '32'];

function resolveRealGeomKeys(env = process.env) {
  const raw = String(env.E2E_REAL_GEOM_KEYS || env.E2E_REAL_RKS || '').trim();
  if (!raw) return DEFAULT_REAL_GEOM_KEYS.slice();
  return raw
    .split(/[,\s]+/)
    .map((s) => s.replace(/^\/library\/metadata\//, '').trim())
    .filter((s) => /^\d+$/.test(s));
}

/** Library notes — informational only; never asserted as delivered. */
const REAL_GEOM_NOTES = {
  '29': { library_note: '624x352', interest: 'non-bank crop/pad (interesting)' },
  '30': { library_note: '624x480', interest: 'BBB bank-sized real content' },
  '31': { library_note: '640x480', interest: 'non-624 width' },
  '32': { library_note: '720x480', interest: 'non-bank scale path (interesting)' },
};

function selfCheck() {
  const samples = [
    'media: MEASURED_DELIVERY delivered_geom=426x240 src=ffmpeg_banner bytes=153360 coded_bytes=449280 identity_skip=0 desync_risk=0 delivery_verified=1',
    'media: MEASURED_DELIVERY 426x240 bytes=153360 coded_bytes=449280 identity_skip=0 desync_risk=0',
    'media: frames=10 measured_delivery=624x352 desync_risk=0 session_epoch=12.3 delivery_verified=1',
    'ERROR media: PIPE_DESYNC_RISK measured=426x240 identity_skip=1 desync_risk=1',
  ];
  const a = parseMeasuredDeliveryText(samples[0]);
  if (!a || !a.delivered_geom || a.delivered_geom.text !== '426x240' || a.desync_risk !== 0) {
    throw new Error('selfCheck fail sample0 ' + JSON.stringify(a));
  }
  const b = parseMeasuredDeliveryText(samples[1]);
  if (!b || b.delivered_geom.text !== '426x240') throw new Error('selfCheck fail sample1');
  const c = parseMeasuredDeliveryText(samples[2]);
  if (!c || c.delivered_geom.text !== '624x352' || c.session_epoch !== '12.3') {
    throw new Error('selfCheck fail sample2 ' + JSON.stringify(c));
  }
  const d = parseMeasuredDeliveryText(samples[3]);
  if (!d || d.desync_risk !== 1 || !d.pipe_desync) throw new Error('selfCheck fail sample3');
  const ar = assertMeasuredDelivery(
    {
      ok: true,
      delivered_geom: a.delivered_geom,
      desync_risk: 0,
      source: 't',
      raw: samples[0],
    },
    { require: true, tag: 't' }
  );
  if (!ar.ok) throw new Error('selfCheck assert ok fail');
  const bad = assertMeasuredDelivery(
    {
      ok: true,
      delivered_geom: parseWxH('426x240'),
      desync_risk: 1,
      pipe_desync: true,
      source: 't',
      raw: samples[3],
    },
    { require: true, tag: 't' }
  );
  if (bad.ok || bad.reason !== 'pipe_desync_risk') throw new Error('selfCheck desync fail');
  const se = assertSessionEpochUnchanged('1.2', '1.2', 't');
  if (!se.ok) throw new Error('selfCheck se same');
  const se2 = assertSessionEpochUnchanged('1.2', '1.3', 't');
  if (se2.ok || se2.reason !== 'session_epoch_changed') throw new Error('selfCheck se change');
  return true;
}

if (require.main === module) {
  try {
    selfCheck();
    console.log('measured_delivery.js selfCheck OK');
    process.exit(0);
  } catch (e) {
    console.error('measured_delivery.js selfCheck FAIL', e.message);
    process.exit(1);
  }
}

module.exports = {
  parseWxH,
  parseMeasuredDeliveryText,
  parseSessionEpochText,
  resolveMeasuredDelivery,
  assertMeasuredDelivery,
  assertSessionEpochUnchanged,
  resolveRealGeomKeys,
  REAL_GEOM_NOTES,
  DEFAULT_REAL_GEOM_KEYS,
  selfCheck,
};
