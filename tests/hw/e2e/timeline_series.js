'use strict';
/**
 * Wallclock-correlated Plex/daemon timeline samples for three-way join:
 *   host wall clock  ↔  Plex-reported position  ↔  parent HDMI capture window
 *
 * Does NOT score lipsync. Labels every field as measured (HTTP/UI) vs N/A.
 */

const fs = require('fs');
const path = require('path');

function wallNow() {
  const ms = Date.now();
  return { ms, iso: new Date(ms).toISOString() };
}

/**
 * @param {object} opts
 * @param {string} [opts.outDir]
 * @param {string} [opts.runId]
 * @param {Function} [opts.log]
 */
function createTimelineSeries(opts = {}) {
  const log = opts.log || console.log;
  const runId = opts.runId || process.env.E2E_RUN_ID || '';
  const rows = [];
  let outDir = opts.outDir || '';
  let filePath = '';

  function setOutDir(dir) {
    outDir = dir || '';
    filePath = '';
  }

  function ensureFile() {
    if (!outDir) return '';
    if (filePath) return filePath;
    try {
      fs.mkdirSync(outDir, { recursive: true });
      filePath = path.join(outDir, 'plex_timeline_series.jsonl');
      return filePath;
    } catch (_) {
      return '';
    }
  }

  /**
   * @param {object} sample
   * @param {string} sample.tag
   * @param {string} sample.source  ui | daemon_timeline | daemon_telemetry
   * @param {number} [sample.plex_time_ms]  measured media position
   * @param {number} [sample.plex_duration_ms]
   * @param {string} [sample.state]
   * @param {number} [sample.ui_time_ms]
   * @param {number} [sample.ui_duration_ms]
   * @param {number} [sample.skew_ms]
   * @param {string} [sample.ui_raw]
   * @param {object} [sample.extra]
   */
  function emit(sample) {
    const w = wallNow();
    const row = {
      run_id: runId || null,
      host_wall_ms: w.ms,
      host_wall_iso: w.iso,
      tag: sample.tag || '',
      source: sample.source || 'unknown',
      // measured from companion Timeline XML or UI clock — never DEFAULT_ASSUMED
      plex_time_ms:
        sample.plex_time_ms != null && Number.isFinite(sample.plex_time_ms)
          ? Math.trunc(sample.plex_time_ms)
          : null,
      plex_duration_ms:
        sample.plex_duration_ms != null && Number.isFinite(sample.plex_duration_ms)
          ? Math.trunc(sample.plex_duration_ms)
          : null,
      state: sample.state != null ? String(sample.state) : null,
      ui_time_ms:
        sample.ui_time_ms != null && Number.isFinite(sample.ui_time_ms)
          ? Math.trunc(sample.ui_time_ms)
          : null,
      ui_duration_ms:
        sample.ui_duration_ms != null && Number.isFinite(sample.ui_duration_ms)
          ? Math.trunc(sample.ui_duration_ms)
          : null,
      skew_ms:
        sample.skew_ms != null && Number.isFinite(sample.skew_ms)
          ? Math.trunc(sample.skew_ms)
          : null,
      ui_raw: sample.ui_raw != null ? String(sample.ui_raw).slice(0, 80) : null,
      value_kind: 'measured',
      ...(sample.extra || {}),
    };
    rows.push(row);

    const line =
      `PLEX_TIMELINE_SAMPLE run_id=${runId || 'NA'} ` +
      `wall_ms=${row.host_wall_ms} wall_iso=${row.host_wall_iso} ` +
      `tag=${row.tag} src=${row.source} ` +
      `plex_time_ms=${row.plex_time_ms != null ? row.plex_time_ms : 'NA'} ` +
      `plex_duration_ms=${row.plex_duration_ms != null ? row.plex_duration_ms : 'NA'} ` +
      `state=${row.state || 'NA'} ` +
      (row.ui_time_ms != null ? `ui_time_ms=${row.ui_time_ms} ` : '') +
      (row.skew_ms != null ? `skew_ms=${row.skew_ms} ` : '') +
      `value_kind=measured`;
    log(line);

    const fp = ensureFile();
    if (fp) {
      try {
        fs.appendFileSync(fp, JSON.stringify(row) + '\n');
      } catch (e) {
        log(`PLEX_TIMELINE_SERIES_WRITE_FAIL ${e.message}`);
      }
    }
    return row;
  }

  function summary() {
    const fp = ensureFile();
    if (fp) log(`PLEX_TIMELINE_SERIES_FILE=${fp} n=${rows.length}`);
    log(
      `PLEX_TIMELINE_SERIES_SUMMARY n=${rows.length} run_id=${runId || 'NA'} ` +
        `join=host_wall_ms↔plex_time_ms↔parent_HDMI_window (no lipsync score)`
    );
    return { n: rows.length, file: fp || '', rows };
  }

  return {
    emit,
    summary,
    setOutDir,
    rows,
    wallNow,
  };
}

module.exports = {
  createTimelineSeries,
  wallNow,
};
