'use strict';
/**
 * Machine-readable UI/session state markers for parent HDMI alignment.
 *
 * Suite drives Plex Web + asserts :3005 control-plane effects.
 * Parent owns HDMI-USB capture and pixel scoring (w-osd-hires overlay res,
 * chevron geometry, etc.). These markers are the join key — no frame grab here.
 *
 * Line formats (stable for grepping / jsonl join):
 *   UI_STATE run_id=… wall_ms=… wall_iso=… state=playing|paused|overlay_visible|idle|seeking|…
 *   UI_STATE_JSON {...}
 *
 * value_kind: measured (daemon/UI sample) | caller_contract (expectation for glass)
 */

const fs = require('fs');
const path = require('path');

function wallNow() {
  const ms = Date.now();
  return { ms, iso: new Date(ms).toISOString() };
}

/**
 * @param {object} opts
 * @param {string} opts.runId
 * @param {string} [opts.outDir]
 * @param {Function} [opts.log]
 */
function createStateMarker(opts = {}) {
  const log = opts.log || console.log;
  const runId = opts.runId || process.env.E2E_RUN_ID || '';
  const outDir = opts.outDir || process.env.E2E_OUT || '';
  let seq = 0;
  const rows = [];

  function jsonlPath() {
    if (!outDir) return '';
    try {
      fs.mkdirSync(outDir, { recursive: true });
    } catch (_) {
      /* ignore */
    }
    return path.join(outDir, 'ui_state_marks.jsonl');
  }

  /**
   * @param {string} state  playing|paused|overlay_visible|idle|seeking|discovery|stopped
   * @param {object} [extra]
   */
  function mark(state, extra = {}) {
    seq += 1;
    const w = wallNow();
    const row = {
      seq,
      run_id: runId || null,
      wall_ms: w.ms,
      wall_iso: w.iso,
      state: String(state),
      phase: extra.phase != null ? String(extra.phase) : 'enter',
      cycle: extra.cycle != null ? extra.cycle : null,
      daemon_state: extra.daemon_state != null ? String(extra.daemon_state) : null,
      daemon_time_ms:
        extra.daemon_time_ms != null && Number.isFinite(Number(extra.daemon_time_ms))
          ? Number(extra.daemon_time_ms)
          : null,
      ui_time_ms:
        extra.ui_time_ms != null && Number.isFinite(Number(extra.ui_time_ms))
          ? Number(extra.ui_time_ms)
          : null,
      rating_key: extra.rating_key != null ? String(extra.rating_key) : null,
      defect_hint: extra.defect_hint != null ? String(extra.defect_hint) : null,
      glass_expect: extra.glass_expect != null ? String(extra.glass_expect) : null,
      hold_ms:
        extra.hold_ms != null && Number.isFinite(Number(extra.hold_ms))
          ? Number(extra.hold_ms)
          : null,
      note: extra.note != null ? String(extra.note).slice(0, 200) : null,
      // Parent pixel domain — suite never scores these.
      pixels: 'parent_hdmi_only',
      chevron: 'not_asserted_suite_parent_verified_f3aa2443',
      overlay_res: 'parent_w_osd_hires',
      value_kind: extra.value_kind || 'measured',
    };
    rows.push(row);

    const line =
      `UI_STATE run_id=${row.run_id || 'NA'} seq=${seq} wall_ms=${row.wall_ms} wall_iso=${row.wall_iso} ` +
      `state=${row.state} phase=${row.phase} ` +
      `cycle=${row.cycle != null ? row.cycle : 'NA'} ` +
      `daemon_state=${row.daemon_state != null ? row.daemon_state : 'NA'} ` +
      `daemon_time_ms=${row.daemon_time_ms != null ? row.daemon_time_ms : 'NA'} ` +
      `ui_time_ms=${row.ui_time_ms != null ? row.ui_time_ms : 'NA'} ` +
      `rating_key=${row.rating_key != null ? row.rating_key : 'NA'} ` +
      (row.defect_hint ? `defect_hint=${row.defect_hint} ` : '') +
      (row.glass_expect ? `glass_expect=${row.glass_expect} ` + '' : '') +
      (row.hold_ms != null ? `hold_ms=${row.hold_ms} ` : '') +
      `pixels=parent_hdmi_only overlay_res=parent_w_osd_hires ` +
      `value_kind=${row.value_kind}`;
    log(line);
    log(`UI_STATE_JSON ${JSON.stringify(row)}`);

    const jp = jsonlPath();
    if (jp) {
      try {
        fs.appendFileSync(jp, JSON.stringify(row) + '\n');
      } catch (_) {
        /* non-fatal */
      }
    }
    return row;
  }

  return {
    mark,
    rows: () => rows.slice(),
    path: jsonlPath,
  };
}

module.exports = {
  createStateMarker,
  wallNow,
};
