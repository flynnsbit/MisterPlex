'use strict';

/**
 * P7 cast correlation + HDMI capture window markers.
 *
 * ERROR 12 class: never attribute a bare `tail` of a shared daemon log to this
 * cast. Require either:
 *   (a) log cleared before CAST_WINDOW_OPEN, snip after CLOSE containing only
 *       lines in [open_ms, close_ms], OR
 *   (b) lines stamped with e2e_mark run_id= / CAST_CORRELATION_ID=
 *
 * Suite does not open /dev/video0. Parent fires HDMI during CAPTURE_WINDOW_*.
 * Warm-up: grabber discards ~15 frames — window is a duration, not an instant.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function wall() {
  const ms = Date.now();
  return { ms, iso: new Date(ms).toISOString() };
}

function makeCorrelationId(ratingKey) {
  const env = process.env.E2E_CAST_CORRELATION_ID || process.env.E2E_RUN_ID || '';
  if (env && String(env).trim()) return String(env).trim();
  const rnd = crypto.randomBytes(3).toString('hex');
  return `p7-${Date.now()}-rk${ratingKey || 'x'}-${rnd}`;
}

/**
 * @param {{ outDir: string, log?: Function, runId?: string }} opts
 */
function createP7Window(opts) {
  const log = opts.log || console.log;
  const outDir = opts.outDir || '';
  const runId = opts.runId || '';
  const state = {
    correlationId: '',
    item: null,
    windowOpen: null,
    windowClose: null,
    captureOpen: null,
    captureClose: null,
    geomLines: [],
    measured: null,
    events: [],
  };

  function emit(event, extra = {}) {
    const w = wall();
    const row = { event, wall_ms: w.ms, wall_iso: w.iso, correlation_id: state.correlationId, ...extra };
    state.events.push(row);
    log(
      `P7_EVENT event=${event} wall_ms=${w.ms} wall_iso=${w.iso} ` +
        `correlation_id=${state.correlationId || 'NA'}` +
        (extra.note ? ` note=${extra.note}` : '')
    );
    return row;
  }

  function bindItem(item, source) {
    state.item = item;
    state.correlationId = makeCorrelationId(item && item.ratingKey);
    const w = item.width || 0;
    const h = item.height || 0;
    log('──────── P7_SELECTED_ITEM (API measured — not DOM title guess) ────────');
    log(`P7_ITEM_SOURCE=${source} value_kind=measured`);
    log(`P7_RATING_KEY=${item.ratingKey} value_kind=measured`);
    log(`P7_TITLE=${JSON.stringify(item.title || '')} value_kind=measured`);
    log(`P7_SECTION=${JSON.stringify(item.sectionTitle || '')} value_kind=measured`);
    log(`P7_LIBRARY_MEDIA=${w}x${h} value_kind=measured`);
    log(`P7_FRAME_RATE=${item.frameRate || 'NA'} value_kind=measured`);
    log(`P7_DURATION_MS=${item.durationMs || 'NA'} value_kind=measured`);
    log(`P7_VIDEO_CODEC=${item.videoCodec || 'NA'} value_kind=measured`);
    log(`P7_CONTAINER=${item.container || 'NA'} value_kind=measured`);
    log(`P7_BITRATE=${item.bitrate || 'NA'} value_kind=measured`);
    log(`P7_FILE=${JSON.stringify(item.file || '')} value_kind=measured`);
    log(
      'P7_NOTE library_media is PMS metadata only — delivered geometry may differ ' +
        '(parent observed request 624x480 → measured 624x350). Assert MEASURED_DELIVERY separately.'
    );
    log(`CAST_CORRELATION_ID=${state.correlationId}`);
    if (runId) log(`E2E_RUN_ID=${runId}`);
    emit('item_bound', {
      rating_key: String(item.ratingKey),
      title: item.title,
      library_media: `${w}x${h}`,
      frame_rate: item.frameRate || '',
    });
    return state.correlationId;
  }

  /** Print BEFORE play — parent must clear log now or correlation is invalid. */
  function printLogClearRecipe() {
    const id = state.correlationId || 'UNBOUND';
    log('──────── P7_LOG_CLEAR_RECIPE (do BEFORE play — ERROR 12 class) ────────');
    log('RULE: a GEOM/measured= line is evidence for THIS cast only if:');
    log('  (1) daemon log was cleared/truncated after this recipe and before PLAY_ISSUED, AND');
    log('  (2) snip is taken after CAST_WINDOW_CLOSE, AND');
    log('  (3) every kept line has wall time in [CAST_WINDOW_OPEN_MS, CAST_WINDOW_CLOSE_MS]');
    log('     OR contains CAST_CORRELATION_ID / e2e_mark run_id for this run.');
    log('FORBIDDEN: bare `tail` of a shared log (long-lived Plex tab may own those lines).');
    log(`CAST_CORRELATION_ID=${id}`);
    log('PARENT_LOG_CLEAR_CMD=# on device, BEFORE suite reaches PLAY:');
    log('#   # resolve LIVE log path from telemetry pid or supervisor — not a guess');
    log('#   : > /path/to/LIVE/misterplexd.log');
    log(`#   date -Is | tee /tmp/p7-clear-${id}.txt`);
    log('PARENT_LOG_SNIP_CMD=# AFTER CAST_WINDOW_CLOSE:');
    log(
      `#   grep -E "MEASURED_DELIVERY|measured_delivery=|desync_risk=|session_epoch=|GEOM |e2e_mark|${id}" \\`
    );
    log('#     LIVE_LOG | tail -200 > HOST_SNIP.txt');
    log('#   export E2E_DAEMON_LOG=HOST_SNIP.txt');
    log('#   # optional single-shot if already read:');
    log('#   export E2E_DELIVERED_GEOM=WxH E2E_DESYNC_RISK=0 E2E_SESSION_EPOCH=P.S');
    log('──────────────────────────────────────────────────────────');
    emit('log_clear_recipe_printed');
  }

  function openCastWindow(extra = {}) {
    const w = wall();
    state.windowOpen = w;
    log(`CAST_WINDOW_OPEN wall_ms=${w.ms} wall_iso=${w.iso} correlation_id=${state.correlationId}`);
    log(`CAST_WINDOW_OPEN_MS=${w.ms}`);
    log(`CAST_WINDOW_OPEN_ISO=${w.iso}`);
    emit('cast_window_open', extra);
    return w;
  }

  function closeCastWindow(extra = {}) {
    const w = wall();
    state.windowClose = w;
    log(`CAST_WINDOW_CLOSE wall_ms=${w.ms} wall_iso=${w.iso} correlation_id=${state.correlationId}`);
    log(`CAST_WINDOW_CLOSE_MS=${w.ms}`);
    log(`CAST_WINDOW_CLOSE_ISO=${w.iso}`);
    if (state.windowOpen) {
      log(`CAST_WINDOW_DURATION_MS=${w.ms - state.windowOpen.ms}`);
    }
    emit('cast_window_close', extra);
    return w;
  }

  /**
   * HDMI capture window for parent grabber.
   * @param {{ holdSec?: number, warmupFrames?: number, captureFps?: number, tag?: string }} o
   */
  function openCaptureWindow(o = {}) {
    const holdSec = Number.isFinite(o.holdSec) ? o.holdSec : parseFloat(process.env.E2E_P7_HOLD_SEC || '45');
    const warmupFrames = Number.isFinite(o.warmupFrames)
      ? o.warmupFrames
      : parseInt(process.env.E2E_HDMI_WARMUP_SKIP || '15', 10) || 15;
    const captureFps = Number.isFinite(o.captureFps)
      ? o.captureFps
      : parseFloat(process.env.E2E_HDMI_CAPTURE_FPS || '30') || 30;
    const warmupSec = warmupFrames / captureFps;
    const totalSec = holdSec + warmupSec;
    const w = wall();
    state.captureOpen = w;
    const endMs = w.ms + Math.round(totalSec * 1000);
    const tag = o.tag || 'p7_main';
    log('──────── P7_CAPTURE_WINDOW (parent HDMI — suite does not grab) ────────');
    log(`CAPTURE_WINDOW_OPEN tag=${tag} wall_ms=${w.ms} wall_iso=${w.iso}`);
    log(`CAPTURE_WINDOW_OPEN_MS=${w.ms}`);
    log(`CAPTURE_WINDOW_OPEN_ISO=${w.iso}`);
    log(`CAPTURE_WINDOW_CLOSE_DEADLINE_MS=${endMs}`);
    log(`CAPTURE_WINDOW_CLOSE_DEADLINE_ISO=${new Date(endMs).toISOString()}`);
    log(
      `CAPTURE_WINDOW_HOLD_SEC=${holdSec} warmup_frames=${warmupFrames} ` +
        `capture_fps=${captureFps} (${process.env.E2E_HDMI_CAPTURE_FPS ? 'caller-supplied' : 'DEFAULT_ASSUMED'}) ` +
        `warmup_sec=${warmupSec.toFixed(3)} total_window_sec=${totalSec.toFixed(3)}`
    );
    log(
      'CAPTURE_INSTRUCTIONS: start grabber NOW; discard first warmup_frames; ' +
        'score only frames inside open..deadline. Window is a duration — not an instant.'
    );
    log(
      `PARENT_HDMI_CAPTURE_CMD=ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 ` +
        `-i \${E2E_HDMI_VIDEO_DEV:-/dev/video0} -frames:v ${Math.ceil(totalSec * captureFps) + 5} ` +
        `-y build/e2e-p7-capture/f_%04d.png; echo "true rc=$?"`
    );
    log(
      `PARENT_HDMI_SCORE_CMD=python3 tools/hdmi_motion_instrument.py build/e2e-p7-capture ` +
        `--warmup-skip ${warmupFrames} --source-fps \${E2E_HDMI_SOURCE_FPS:-24} ` +
        `--capture-fps ${captureFps} --json; echo "true rc=$?"`
    );
    log(
      `GLASS_EXPECT picture=motion counter=content_dependent tag=${tag} ` +
        `correlation_id=${state.correlationId} — Playwright PASS ≠ viewed pixels OK`
    );
    emit('capture_window_open', {
      tag,
      hold_sec: holdSec,
      warmup_frames: warmupFrames,
      capture_fps: captureFps,
      deadline_ms: endMs,
    });
    return {
      open: w,
      deadlineMs: endMs,
      holdSec,
      warmupFrames,
      captureFps,
      totalSec,
      tag,
    };
  }

  function closeCaptureWindow(tag = 'p7_main') {
    const w = wall();
    state.captureClose = w;
    log(`CAPTURE_WINDOW_CLOSE tag=${tag} wall_ms=${w.ms} wall_iso=${w.iso}`);
    log(`CAPTURE_WINDOW_CLOSE_MS=${w.ms}`);
    log(`CAPTURE_WINDOW_CLOSE_ISO=${w.iso}`);
    if (state.captureOpen) {
      log(`CAPTURE_WINDOW_ELAPSED_MS=${w.ms - state.captureOpen.ms}`);
    }
    emit('capture_window_close', { tag });
    return w;
  }

  function recordMeasured(md) {
    state.measured = md;
    if (!md) {
      log('P7_MEASURED_DELIVERY=unprobed value_kind=unprobed');
      return;
    }
    const g = md.delivered_geom ? md.delivered_geom.text : md.stream || 'NA';
    log(
      `P7_MEASURED_DELIVERY delivered=${g} desync_risk=${md.desync_risk != null ? md.desync_risk : 'NA'} ` +
        `source=${md.source || 'NA'} session_epoch=${md.session_epoch || 'NA'} ` +
        `value_kind=${md.value_kind || 'measured'} correlation_id=${state.correlationId}`
    );
    if (md.raw) log(`P7_MEASURED_RAW ${String(md.raw).slice(0, 300)}`);
    emit('measured_delivery', {
      delivered: g,
      desync_risk: md.desync_risk,
      source: md.source,
      session_epoch: md.session_epoch || '',
    });
  }

  /**
   * Attribute GEOM/measured lines only if inside cast window or bearing correlation id.
   * @returns {{ ok:boolean, kept:string[], rejected:string[], reason?:string }}
   */
  function filterCorrelatedLogLines(text) {
    const openMs = state.windowOpen && state.windowOpen.ms;
    const closeMs = state.windowClose && state.windowClose.ms;
    const id = state.correlationId;
    const lines = String(text || '').split(/\r?\n/);
    const kept = [];
    const rejected = [];
    for (const line of lines) {
      if (!line.trim()) continue;
      if (!/GEOM|MEASURED_DELIVERY|measured_delivery=|desync_risk=|session_epoch=|e2e_mark|PIPE_DESYNC/i.test(line)) {
        continue;
      }
      const hasId = id && line.includes(id);
      // Optional host timestamp in line (iso or unix ms)
      let inWindow = false;
      if (openMs && closeMs) {
        const msM = line.match(/\b(1[6-9]\d{11}|1[6-9]\d{12})\b/); // loose unix ms
        if (msM) {
          const t = parseInt(msM[1], 10);
          if (t >= openMs - 2000 && t <= closeMs + 2000) inWindow = true;
        }
        const isoM = line.match(/\b(20\d{2}-\d{2}-\d{2}T[0-9:.+Z-]+)/);
        if (isoM) {
          const t = Date.parse(isoM[1]);
          if (Number.isFinite(t) && t >= openMs - 2000 && t <= closeMs + 2000) inWindow = true;
        }
      }
      // If parent cleared log before open, entire snip is attributed (no foreign timestamps).
      const clearedSnip = /^(1|true|yes|on)$/i.test(String(process.env.E2E_LOG_CLEARED_BEFORE_CAST || ''));
      if (hasId || inWindow || clearedSnip) {
        kept.push(line.slice(0, 400));
      } else {
        rejected.push(line.slice(0, 200));
      }
    }
    log(
      `P7_LOG_CORRELATE kept=${kept.length} rejected=${rejected.length} ` +
        `window_ms=${openMs || 'NA'}..${closeMs || 'NA'} correlation_id=${id} ` +
        `cleared_flag=${/^(1|true|yes|on)$/i.test(String(process.env.E2E_LOG_CLEARED_BEFORE_CAST || '')) ? 1 : 0}`
    );
    if (rejected.length) {
      log(
        `P7_LOG_REJECT_SAMPLE ${rejected.slice(0, 3).join(' || ')} ` +
          `(unattributed — may be long-lived tab / prior cast; ERROR 12 class)`
      );
    }
    for (const k of kept.slice(0, 12)) log(`P7_LOG_KEPT ${k}`);
    state.geomLines = kept;
    if (!kept.length) {
      return {
        ok: false,
        kept,
        rejected,
        reason:
          'no_correlated_geom_lines — clear log before PLAY, set E2E_LOG_CLEARED_BEFORE_CAST=1, ' +
          'or ensure snip lines fall in CAST_WINDOW / contain correlation id',
      };
    }
    return { ok: true, kept, rejected };
  }

  function persist() {
    if (!outDir) return '';
    try {
      fs.mkdirSync(outDir, { recursive: true });
      const manifest = {
        p7: true,
        correlation_id: state.correlationId,
        run_id: runId || null,
        item: state.item
          ? {
              ratingKey: state.item.ratingKey,
              title: state.item.title,
              sectionTitle: state.item.sectionTitle || '',
              library_media:
                state.item.width && state.item.height
                  ? `${state.item.width}x${state.item.height}`
                  : '',
              frameRate: state.item.frameRate || '',
              durationMs: state.item.durationMs || 0,
              videoCodec: state.item.videoCodec || '',
              container: state.item.container || '',
              bitrate: state.item.bitrate || 0,
              file: state.item.file || '',
            }
          : null,
        cast_window: {
          open_ms: state.windowOpen && state.windowOpen.ms,
          open_iso: state.windowOpen && state.windowOpen.iso,
          close_ms: state.windowClose && state.windowClose.ms,
          close_iso: state.windowClose && state.windowClose.iso,
        },
        capture_window: {
          open_ms: state.captureOpen && state.captureOpen.ms,
          open_iso: state.captureOpen && state.captureOpen.iso,
          close_ms: state.captureClose && state.captureClose.ms,
          close_iso: state.captureClose && state.captureClose.iso,
        },
        measured_delivery: state.measured
          ? {
              delivered:
                (state.measured.delivered_geom && state.measured.delivered_geom.text) ||
                state.measured.stream ||
                null,
              desync_risk: state.measured.desync_risk,
              source: state.measured.source,
              session_epoch: state.measured.session_epoch || null,
              value_kind: state.measured.value_kind || 'measured',
            }
          : null,
        correlated_log_lines: state.geomLines,
        events: state.events,
        boundary:
          'Playwright asserts control-plane + correlated daemon telemetry only. ' +
          'Viewed pixels are parent HDMI only. Green P7 Playwright ≠ P7 closed.',
      };
      const p = path.join(outDir, 'p7_cast_manifest.json');
      fs.writeFileSync(p, JSON.stringify(manifest, null, 2));
      const e = path.join(outDir, 'p7_events.jsonl');
      fs.writeFileSync(e, state.events.map((x) => JSON.stringify(x)).join('\n') + '\n');
      log(`P7_MANIFEST=${p}`);
      log(`P7_EVENTS_JSONL=${e}`);
      return p;
    } catch (err) {
      log(`P7_MANIFEST_WRITE_FAIL ${err.message}`);
      return '';
    }
  }

  return {
    state,
    bindItem,
    printLogClearRecipe,
    openCastWindow,
    closeCastWindow,
    openCaptureWindow,
    closeCaptureWindow,
    recordMeasured,
    filterCorrelatedLogLines,
    persist,
    get correlationId() {
      return state.correlationId;
    },
  };
}

module.exports = {
  createP7Window,
  makeCorrelationId,
};
