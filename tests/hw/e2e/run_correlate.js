'use strict';
/**
 * Per-run correlation key for joining UI-driven e2e to daemon session-origin
 * records (first_audio_pcm, A/V audio_release, first_video_present,
 * pcm_silence_head_ms) without relying on a bare `tail` of a shared log.
 *
 * Does NOT assert lipsync — only emits join keys. Lip-sync ground truth is
 * parent-only via tools/avsync_measure_hdmi.py.
 */

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const crypto = require('crypto');

function wallNow() {
  const ms = Date.now();
  return { ms, iso: new Date(ms).toISOString() };
}

function makeRunId(prefix = 'e2e') {
  const env = process.env.E2E_RUN_ID && String(process.env.E2E_RUN_ID).trim();
  if (env) return env;
  const { ms } = wallNow();
  const rnd = crypto.randomBytes(4).toString('hex');
  return `${prefix}-${ms}-${rnd}`;
}

function httpGet(url, timeoutMs = 4000) {
  return new Promise((resolve) => {
    const lib = url.startsWith('https') ? https : http;
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

/**
 * @param {{ misterHost: string, misterPort?: number|string, outDir?: string, log?: Function }} opts
 */
function createRunCorrelation(opts) {
  const log = opts.log || console.log;
  const host = opts.misterHost || process.env.MISTER_HOST || '127.0.0.1';
  const port = opts.misterPort || process.env.MISTER_PORT || 3005;
  const base = `http://${host}:${port}`;
  const runId = makeRunId('cast');
  const begin = wallNow();
  const events = [];

  function record(event, extra = {}) {
    const w = wallNow();
    const row = {
      run_id: runId,
      event,
      host_wall_ms: w.ms,
      host_wall_iso: w.iso,
      ...extra,
    };
    events.push(row);
    return row;
  }

  function emitBanner() {
    log('──────── E2E_RUN_CORRELATION ────────');
    log(`E2E_RUN_ID=${runId}`);
    log(`E2E_RUN_BEGIN_HOST_WALL_MS=${begin.ms}`);
    log(`E2E_RUN_BEGIN_HOST_WALL_ISO=${begin.iso}`);
    log(
      'JOIN: parent greps misterplexd.log for `e2e_mark run_id=' +
        runId +
        '` then the following origin lines in the SAME session window: ' +
        'first_audio_pcm | A/V audio_release | first_video_present | pcm_silence_head_ms'
    );
    log(
      'JOIN: do NOT attribute a bare tail of a shared log to this run without the run_id mark ' +
        '(ERROR 12 class). Prefer e2e_mark lines + session= from /player/telemetry.'
    );
    log(
      'LIPSYNC: this suite does NOT assert A/V offset. av-lock/av_drift_ms are blind. ' +
        'Only tools/avsync_measure_hdmi.py on parent capture is valid.'
    );
  }

  function persist(outDir) {
    if (!outDir) return '';
    try {
      fs.mkdirSync(outDir, { recursive: true });
      const p = path.join(outDir, 'e2e_run_id.txt');
      const payload =
        `E2E_RUN_ID=${runId}\n` +
        `E2E_RUN_BEGIN_HOST_WALL_MS=${begin.ms}\n` +
        `E2E_RUN_BEGIN_HOST_WALL_ISO=${begin.iso}\n` +
        events.map((e) => JSON.stringify(e)).join('\n') +
        (events.length ? '\n' : '');
      fs.writeFileSync(p, payload);
      const j = path.join(outDir, 'e2e_run_events.jsonl');
      fs.writeFileSync(j, events.map((e) => JSON.stringify(e)).join('\n') + (events.length ? '\n' : ''));
      log(`E2E_RUN_ID_FILE=${p}`);
      return p;
    } catch (e) {
      log(`E2E_RUN_ID_FILE_WRITE_FAIL ${e.message}`);
      return '';
    }
  }

  /**
   * Stamp daemon log via companion GET /player/e2e_mark (no castBound).
   * Soft if daemon old (no endpoint) — still emit host-side keys.
   */
  async function mark(event, extra = {}) {
    const row = record(event, extra);
    const q = new URLSearchParams({
      run_id: runId,
      event: String(event),
      host_wall_ms: String(row.host_wall_ms),
      host_wall_iso: row.host_wall_iso,
    });
    if (extra.cycle != null) q.set('cycle', String(extra.cycle));
    if (extra.tier) q.set('tier', String(extra.tier));
    if (extra.ratingKey) q.set('ratingKey', String(extra.ratingKey));
    if (extra.session != null) q.set('session', String(extra.session));
    if (extra.transition) q.set('transition', String(extra.transition));
    if (extra.reason) q.set('reason', String(extra.reason).slice(0, 80));
    if (extra.selector) q.set('selector', String(extra.selector).slice(0, 80));
    const url = `${base}/player/e2e_mark?${q.toString()}`;
    const res = await httpGet(url);
    const ok = res.status === 200 && /ok=1|e2e_mark/.test(res.body || '');
    log(
      `E2E_MARK event=${event} run_id=${runId} host_wall_ms=${row.host_wall_ms} ` +
        `daemon_http=${res.status} stamped=${ok ? 1 : 0}` +
        (extra.cycle != null ? ` cycle=${extra.cycle}` : '') +
        (!ok && res.body ? ` body=${String(res.body).slice(0, 120).replace(/\s+/g, ' ')}` : '')
    );
    if (!ok && res.status === 0) {
      log(
        `E2E_MARK_NOTE daemon unreachable for mark — host keys still valid; ` +
          `parent must join by host_wall window + cleared log or deploy e2e_mark endpoint`
      );
    } else if (!ok && res.status > 0) {
      log(
        `E2E_MARK_NOTE endpoint missing or old daemon (HTTP ${res.status}) — ` +
          `deploy companion with GET /player/e2e_mark or join via host_wall + telemetry session only`
      );
    }
    return { row, stamped: ok, status: res.status, body: res.body };
  }

  /** Poll /player/telemetry and emit JOIN line with session= for this run. */
  async function joinTelemetry(tag = 'post_play') {
    const url = `${base}/player/telemetry`;
    const res = await httpGet(url);
    const body = res.body || '';
    const session = (body.match(/\bsession=(\d+)/) || [])[1] || '';
    const frames = (body.match(/\bframes=(\d+)/) || [])[1] || '';
    const playing = (body.match(/\bplaying=(\d+)/) || [])[1] || '';
    const w = wallNow();
    log(
      `E2E_JOIN tag=${tag} run_id=${runId} host_wall_ms=${w.ms} host_wall_iso=${w.iso} ` +
        `telemetry_http=${res.status} session=${session || 'NA'} frames=${frames || 'NA'} ` +
        `playing=${playing || 'NA'}`
    );
    if (session) {
      log(
        `E2E_JOIN_GREP run_id=${runId} session=${session} — match daemon lines after ` +
          `e2e_mark run_id=${runId} until next session start; origin keys: ` +
          `first_audio_pcm A/V_audio_release first_video_present pcm_silence_head_ms`
      );
    }
    record('telemetry_join', {
      tag,
      session: session || null,
      frames: frames || null,
      telemetry_http: res.status,
    });
    return { session, frames, playing, status: res.status, body };
  }

  return {
    runId,
    begin,
    events,
    emitBanner,
    persist,
    mark,
    joinTelemetry,
    wallNow,
  };
}

module.exports = {
  createRunCorrelation,
  makeRunId,
  wallNow,
};
