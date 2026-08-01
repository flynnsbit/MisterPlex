'use strict';
/**
 * Per-transition glass expectations for parent HDMI capture alignment.
 *
 * Playwright asserts control-plane; parent scores pixels. These markers are the
 * join key: host_wall_ms + run_id + what the glass MUST show at that instant.
 *
 * Suite never opens /dev/video0. Does not claim lipsync.
 */

function wallNow() {
  const ms = Date.now();
  return { ms, iso: new Date(ms).toISOString() };
}

/**
 * @typedef {object} GlassExpect
 * @property {string} transition  pause|resume|seek_fwd|seek_back|stop|play|idle|discovery
 * @property {string} phase       before|after|hold
 * @property {number} [cycle]
 * @property {string} picture     motion|frozen|pause_overlay|play_chrome|idle_logo|seek_discontinuity|picker_ui|unknown
 * @property {string} counter     advancing|pinned|na  (TREK/PLEX burned-in n=)
 * @property {string} [daemon_state]
 * @property {number} [daemon_time_ms]
 * @property {number} [ui_time_ms]
 * @property {number} [ui_pct]
 * @property {number} [hold_ms]   recommended capture hold after marker
 * @property {string} [note]
 * @property {string} [defect_hint]  parent-scored defect class (e.g. pause_overlay_low_res)
 */

/**
 * @param {GlassExpect} exp
 * @param {{ runId?: string, log?: Function, mark?: Function }} ctx
 */
async function emitGlassExpect(exp, ctx = {}) {
  const log = ctx.log || console.log;
  const w = wallNow();
  const runId = ctx.runId || process.env.E2E_RUN_ID || '';
  const hold = exp.hold_ms != null ? exp.hold_ms : defaultHoldMs(exp.transition, exp.phase);
  const line =
    `GLASS_EXPECT run_id=${runId || 'NA'} wall_ms=${w.ms} wall_iso=${w.iso} ` +
    `cycle=${exp.cycle != null ? exp.cycle : 'NA'} transition=${exp.transition} phase=${exp.phase} ` +
    `picture=${exp.picture} counter=${exp.counter} ` +
    `daemon_state=${exp.daemon_state != null ? exp.daemon_state : 'NA'} ` +
    `daemon_time_ms=${exp.daemon_time_ms != null ? exp.daemon_time_ms : 'NA'} ` +
    `ui_time_ms=${exp.ui_time_ms != null ? exp.ui_time_ms : 'NA'} ` +
    `ui_pct=${exp.ui_pct != null ? exp.ui_pct : 'NA'} ` +
    `hold_ms=${hold} ` +
    `see=${glassSeeSummary(exp)} ` +
    (exp.defect_hint ? `defect_hint=${exp.defect_hint} ` : '') +
    (exp.note ? `note=${JSON.stringify(String(exp.note).slice(0, 160))} ` : '') +
    `boundary=playwright_control_plane_only_pixels_are_parent ` +
    `value_kind=caller_contract`;
  log(line);
  // Machine-join line for w-instr / parent capture scorer (same wall_ms).
  log(
    `GLASS_JOIN run_id=${runId || 'NA'} wall_ms=${w.ms} wall_iso=${w.iso} ` +
      `transition=${exp.transition} phase=${exp.phase} picture=${exp.picture} ` +
      `daemon_state=${exp.daemon_state != null ? exp.daemon_state : 'NA'} ` +
      `daemon_time_ms=${exp.daemon_time_ms != null ? exp.daemon_time_ms : 'NA'} ` +
      `ui_time_ms=${exp.ui_time_ms != null ? exp.ui_time_ms : 'NA'} ` +
      `hold_ms=${hold}`
  );

  if (typeof ctx.mark === 'function') {
    await ctx.mark(`glass_${exp.transition}_${exp.phase}`, {
      cycle: exp.cycle,
      transition: exp.transition,
      reason: exp.picture,
    }).catch(() => {});
  }
  return { ...exp, host_wall_ms: w.ms, host_wall_iso: w.iso, hold_ms: hold, run_id: runId };
}

function defaultHoldMs(transition, phase) {
  if (phase === 'hold') return 3000;
  // Pause overlay is the user's low-res chrome defect window — longer hold.
  if (transition === 'pause' && phase === 'after') {
    const envH = parseInt(process.env.E2E_PAUSE_OVERLAY_HOLD_MS || '', 10);
    return Number.isFinite(envH) && envH > 0 ? envH : 4000;
  }
  if (transition === 'pause_overlay') return 4000;
  if (transition === 'stop' && phase === 'after') return 2000; // idle logo
  if (transition === 'seek_fwd' || transition === 'seek_back') return 2000;
  if (transition === 'discovery') return 1500;
  return 1500;
}

function glassSeeSummary(exp) {
  switch (exp.picture) {
    case 'motion':
      return 'moving_picture+counter_advancing_if_TREK';
    case 'frozen':
      return 'still_frame+counter_pinned_if_TREK_same_n';
    case 'pause_overlay':
      // User defect: player chrome/timeline on MiSTer is very low-res when paused.
      // Suite asserts control-plane paused; PARENT scores chrome resolution on glass.
      // Present path is 529x240 only — do not expect fine UI detail.
      return 'frozen_frame+player_chrome_timeline_visible_on_glass_score_chrome_res_parent_529x240_only';
    case 'play_chrome':
      return 'motion_or_frame+timeline_chrome_if_shown_score_res_parent';
    case 'idle_logo':
      return 'static_Plex_logo_IDLE_SCREEN_no_playback_chrome';
    case 'seek_discontinuity':
      return 'counter_n_jumps_near_seek_target_then_advances';
    case 'picker_ui':
      return 'Plex_Web_picker_only_NOT_device_glass';
    default:
      return 'unspecified';
  }
}

module.exports = {
  emitGlassExpect,
  wallNow,
  glassSeeSummary,
  defaultHoldMs,
};
