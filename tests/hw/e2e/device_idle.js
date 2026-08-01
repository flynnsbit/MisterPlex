'use strict';
/**
 * P4 — STOPPED unregressed: after cast stop, device must be idle with no leaked
 * playing session. Paired with Playwright stop (UI or suite HTTP) + :3005 probes.
 *
 * Does NOT score pixels (IDLE_SCREEN=logo is parent conf + HDMI). This module
 * only asserts companion-observable idle.
 */

/**
 * @param {Array<{state:string,time:number,duration?:number}>} samples timeline polls
 * @param {{playing?: number, session?: number}|null} tele telemetry snap
 * @param {{resourcesStatus?: number, tag?: string, sessionAtPlay?: number}} opts
 */
function assertDeviceIdleP4(samples, tele, opts = {}) {
  const tag = opts.tag || 'p4_idle';
  const samplesArr = samples || [];
  const bad = samplesArr.filter((s) => s.state === 'playing' || s.state === 'paused');
  const idleShaped = samplesArr.filter(
    (s) =>
      s.state === 'stopped' ||
      s.state === '' ||
      (s.state === 'buffering' && (s.time === 0 || s.duration === 0))
  );

  // Timeline must not stay in playing/paused.
  if (bad.length > 1) {
    return {
      ok: false,
      reason: 'p4_timeline_not_idle',
      detail:
        `${tag}: after stop, timeline still playing/paused ` +
        `(samples=${samplesArr.map((s) => `${s.state}@${s.time}`).join(' ')})`,
    };
  }
  if (bad.length === 1 && idleShaped.length < Math.ceil(samplesArr.length / 2)) {
    return {
      ok: false,
      reason: 'p4_timeline_not_idle',
      detail:
        `${tag}: majority not idle-shaped after stop; ` +
        `samples=${samplesArr.map((s) => `${s.state}@${s.time}`).join(' ')}`,
    };
  }

  // Companion resources must still answer (daemon alive, not wedged).
  if (opts.resourcesStatus != null && opts.resourcesStatus !== 200) {
    return {
      ok: false,
      reason: 'p4_resources_not_200',
      detail: `${tag}: GET /resources status=${opts.resourcesStatus} (want 200)`,
    };
  }

  // Telemetry playing=0 when field present (deployed daemon).
  if (tele && tele.playing === 1) {
    return {
      ok: false,
      reason: 'p4_telemetry_still_playing',
      detail:
        `${tag}: telemetry playing=1 after stop (leaked session). ` +
        `session=${tele.session} pid=${tele.pid}`,
    };
  }

  // Optional: session id may stay or increment; we only fail if still playing.
  // Log contract for parent glass: IDLE_SCREEN=logo (not screensaver).
  return {
    ok: true,
    reason: 'p4_idle_ok',
    detail:
      `${tag}: timeline idle-shaped; resources=${opts.resourcesStatus != null ? opts.resourcesStatus : 'NA'}; ` +
      `telemetry_playing=${tele && tele.playing != null ? tele.playing : 'NA'}; ` +
      `glass_contract=IDLE_SCREEN=logo_static_plex_logo (parent conf + HDMI, not suite pixels)`,
    state: samplesArr.length ? samplesArr[samplesArr.length - 1].state : 'idle',
    playing: tele && tele.playing != null ? tele.playing : null,
    session: tele && tele.session != null ? tele.session : null,
  };
}

module.exports = {
  assertDeviceIdleP4,
};
