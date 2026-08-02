'use strict';

/**
 * pms_control_plane.js — Plex Media Server control-plane truth (no HDMI).
 *
 * Boundary (print on every run):
 *   Playwright + PMS HTTP prove cast/session/transcode control plane only.
 *   They CANNOT prove a single correct pixel reached the screen.
 *   HDMI-USB is a separate evidence class (currently unavailable → do not
 *   over-read green Playwright as product pixel PASS).
 *
 * Endpoints (parent-verified):
 *   GET /status/sessions
 *   GET /transcode/sessions   → complete, progress, speed, videoDecision, throttled
 *   GET /library/metadata/<rk>
 *
 * Parent-measured transcode samples (same class of defect as supply collapse):
 *   HEALTHY:   complete=1 progress=99.7 speed=19.8
 *   COLLAPSED: complete=0 progress=68.6 speed=0
 *
 * Stale-session hygiene: rapid cast/stop leaves orphaned /transcode/sessions
 * and /status/sessions — report after stop; fail when requireStaleClean=1.
 *
 * Never scores misterplexd av-lock / drops / smoothness.
 * Never embeds lab IPs, tokens, or plex.direct hashes (env only).
 */

const http = require('http');
const https = require('https');

const BOUNDARY_BANNER =
  'CONTROL_PLANE_ONLY: Playwright+PMS prove cast/session/transcode state. ' +
  'CANNOT prove pixels on glass. Green here ≠ viewed-pixel PASS. ' +
  'HDMI-USB is a separate evidence class.';

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function httpGet(url, headers = {}, timeoutMs = 8000) {
  return new Promise((resolve) => {
    const lib = String(url).startsWith('https') ? https : http;
    const req = lib.get(
      url,
      { headers, timeout: timeoutMs, rejectUnauthorized: false },
      (res) => {
        let body = '';
        res.on('data', (d) => {
          body += d;
        });
        res.on('end', () => resolve({ status: res.statusCode || 0, body }));
      }
    );
    req.on('error', (e) => resolve({ status: 0, body: '', err: e.message }));
    req.on('timeout', () => {
      req.destroy();
      resolve({ status: 0, body: '', err: 'timeout' });
    });
  });
}

function baseUrl(plexBase) {
  return String(plexBase || '').replace(/\/$/, '');
}

function authHeaders(token) {
  return {
    'X-Plex-Token': token,
    Accept: 'application/json',
  };
}

function attr(xml, name) {
  const m = String(xml || '').match(new RegExp(`\\b${name}="([^"]*)"`, 'i'));
  return m ? m[1] : '';
}

function parseJsonSafe(body) {
  try {
    return JSON.parse(body);
  } catch (_) {
    return null;
  }
}

/**
 * Normalize /status/sessions into a list of session rows.
 */
function parseStatusSessionsBody(body, status) {
  if (status !== 200) {
    return { ok: false, sessions: [], detail: `HTTP ${status}`, value_kind: 'measured' };
  }
  const j = parseJsonSafe(body);
  if (j && j.MediaContainer) {
    const metas = j.MediaContainer.Metadata || [];
    const sessions = metas.map((m) => {
      const player = m.Player || {};
      const trans = m.TranscodeSession || {};
      return {
        ratingKey: String(m.ratingKey || ''),
        title: String(m.title || ''),
        state: String(player.state || m.Player?.state || ''),
        player: String(player.title || player.device || player.product || ''),
        machineIdentifier: String(player.machineIdentifier || player.address || ''),
        sessionKey: String(m.sessionKey || ''),
        viewOffset: m.viewOffset != null ? Number(m.viewOffset) : -1,
        transcode: {
          videoDecision: String(trans.videoDecision || m.transcodeSession?.videoDecision || ''),
          audioDecision: String(trans.audioDecision || ''),
          throttled: trans.throttled === true || trans.throttled === 1 || trans.throttled === '1',
          complete: trans.complete === true || trans.complete === 1 || String(trans.complete) === '1',
          progress: trans.progress != null ? Number(trans.progress) : null,
          speed: trans.speed != null ? Number(trans.speed) : null,
        },
      };
    });
    return {
      ok: true,
      sessions,
      count: sessions.length,
      size: Number(j.MediaContainer.size != null ? j.MediaContainer.size : sessions.length),
      value_kind: 'measured',
    };
  }
  // XML fallback
  const size = parseInt(attr(body, 'size') || '0', 10);
  const sessions = [];
  const re = /<Video\b[^>]*>[\s\S]*?<\/Video>|<Track\b[^>]*>[\s\S]*?<\/Track>/gi;
  let m;
  const blob = String(body || '');
  while ((m = re.exec(blob))) {
    const block = m[0];
    const playerBlock = (block.match(/<Player\b[^>]*\/>|<Player\b[^>]*>[\s\S]*?<\/Player>/i) || [
      '',
    ])[0];
    sessions.push({
      ratingKey: attr(block, 'ratingKey'),
      title: attr(block, 'title'),
      state: attr(playerBlock, 'state') || attr(block, 'state'),
      player: attr(playerBlock, 'title') || attr(playerBlock, 'device') || attr(playerBlock, 'product'),
      machineIdentifier: attr(playerBlock, 'machineIdentifier') || attr(playerBlock, 'address'),
      sessionKey: attr(block, 'sessionKey'),
      viewOffset: parseInt(attr(block, 'viewOffset') || '-1', 10),
      transcode: {},
    });
  }
  return {
    ok: true,
    sessions,
    count: sessions.length,
    size: Number.isFinite(size) ? size : sessions.length,
    value_kind: 'measured',
  };
}

/**
 * Normalize /transcode/sessions.
 * Parent samples: HEALTHY complete=1 progress=99.7 speed=19.8
 *                 COLLAPSED complete=0 progress=68.6 speed=0
 */
function parseTranscodeSessionsBody(body, status) {
  if (status !== 200) {
    return { ok: false, sessions: [], detail: `HTTP ${status}`, value_kind: 'measured' };
  }
  const j = parseJsonSafe(body);
  const sessions = [];
  if (j && j.MediaContainer) {
    const list =
      j.MediaContainer.TranscodeSession ||
      j.MediaContainer.Metadata ||
      [];
    const arr = Array.isArray(list) ? list : list ? [list] : [];
    for (const t of arr) {
      sessions.push({
        key: String(t.key || t.sessionKey || ''),
        throttled: t.throttled === true || t.throttled === 1 || String(t.throttled) === '1',
        complete: t.complete === true || t.complete === 1 || String(t.complete) === '1',
        progress: t.progress != null ? Number(t.progress) : null,
        speed: t.speed != null ? Number(t.speed) : null,
        videoDecision: String(t.videoDecision || ''),
        audioDecision: String(t.audioDecision || ''),
        sourceVideoCodec: String(t.sourceVideoCodec || ''),
        videoCodec: String(t.videoCodec || ''),
      });
    }
    return {
      ok: true,
      sessions,
      count: sessions.length,
      size: Number(j.MediaContainer.size != null ? j.MediaContainer.size : sessions.length),
      value_kind: 'measured',
    };
  }
  // XML: <TranscodeSession ... />
  const blob = String(body || '');
  const size = parseInt(attr(blob, 'size') || '0', 10);
  const re = /<TranscodeSession\b[^>]*\/?>/gi;
  let m;
  while ((m = re.exec(blob))) {
    const block = m[0];
    sessions.push({
      key: attr(block, 'key') || attr(block, 'sessionKey'),
      throttled: attr(block, 'throttled') === '1',
      complete: attr(block, 'complete') === '1',
      progress: attr(block, 'progress') !== '' ? Number(attr(block, 'progress')) : null,
      speed: attr(block, 'speed') !== '' ? Number(attr(block, 'speed')) : null,
      videoDecision: attr(block, 'videoDecision'),
      audioDecision: attr(block, 'audioDecision'),
      sourceVideoCodec: attr(block, 'sourceVideoCodec'),
      videoCodec: attr(block, 'videoCodec'),
    });
  }
  return {
    ok: true,
    sessions,
    count: sessions.length,
    size: Number.isFinite(size) ? size : sessions.length,
    value_kind: 'measured',
  };
}

async function fetchStatusSessions(plexBase, token, opts = {}) {
  const url = `${baseUrl(plexBase)}/status/sessions`;
  const r = await httpGet(url, authHeaders(token), opts.timeoutMs || 8000);
  const parsed = parseStatusSessionsBody(r.body, r.status);
  parsed.http_status = r.status;
  parsed.endpoint = '/status/sessions';
  return parsed;
}

async function fetchTranscodeSessions(plexBase, token, opts = {}) {
  const url = `${baseUrl(plexBase)}/transcode/sessions`;
  const r = await httpGet(url, authHeaders(token), opts.timeoutMs || 8000);
  const parsed = parseTranscodeSessionsBody(r.body, r.status);
  parsed.http_status = r.status;
  parsed.endpoint = '/transcode/sessions';
  return parsed;
}

function matchPlayer(session, wantName) {
  const want = String(wantName || 'misterplex').toLowerCase();
  const hay = `${session.player || ''} ${session.machineIdentifier || ''}`.toLowerCase();
  return hay.includes(want) || hay.includes('misterplex');
}

function findSessionForPlayer(sessions, wantName, expectedRk) {
  const list = sessions || [];
  const rk = expectedRk != null && expectedRk !== '' ? String(expectedRk) : '';
  let hits = list.filter((s) => matchPlayer(s, wantName));
  if (!hits.length && list.length === 1) hits = list.slice();
  if (rk) {
    const rkHits = hits.filter((s) => String(s.ratingKey) === rk);
    if (rkHits.length) hits = rkHits;
  }
  // prefer playing > paused > buffering
  hits.sort((a, b) => {
    const rank = (s) =>
      /play/i.test(s.state) ? 0 : /paus/i.test(s.state) ? 1 : /buffer/i.test(s.state) ? 2 : 3;
    return rank(a) - rank(b);
  });
  return hits[0] || null;
}

/**
 * Playing: session exists for player + ratingKey, state playing|buffering.
 */
function assertSessionPlaying(statusSnap, tag, opts = {}) {
  const want = opts.castName || opts.playerName || 'MiSTerPlex';
  const rk = opts.ratingKey != null ? String(opts.ratingKey) : '';
  if (!statusSnap || !statusSnap.ok) {
    return {
      ok: false,
      reason: 'pms_sessions_unprobed',
      detail: `${tag}: /status/sessions unprobed (${(statusSnap && statusSnap.detail) || 'NA'})`,
      value_kind: 'unprobed',
    };
  }
  const s = findSessionForPlayer(statusSnap.sessions, want, rk);
  if (!s) {
    return {
      ok: false,
      reason: 'pms_session_missing',
      detail:
        `${tag}: no /status/sessions row for player~${want}` +
        (rk ? ` rk=${rk}` : '') +
        ` (sessions=${statusSnap.count}). PRE_REGISTER fail: cast did not create PMS session.`,
      sessions: statusSnap.count,
      value_kind: 'measured',
    };
  }
  if (rk && String(s.ratingKey) !== rk) {
    return {
      ok: false,
      reason: 'pms_session_wrong_rating_key',
      detail:
        `${tag}: session rk=${s.ratingKey} != expected ${rk} player=${s.player} state=${s.state}. ` +
        `PRE_REGISTER fail: wrong title under cast (content swap / leftover).`,
      session: s,
      value_kind: 'measured',
    };
  }
  if (!/play|buffer/i.test(s.state || '')) {
    return {
      ok: false,
      reason: 'pms_session_not_playing',
      detail:
        `${tag}: session state=${s.state || '?'} (want playing|buffering) rk=${s.ratingKey} player=${s.player}. ` +
        `PRE_REGISTER fail: PMS does not report playing.`,
      session: s,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'pms_session_playing',
    session: s,
    ratingKey: s.ratingKey,
    state: s.state,
    player: s.player,
    value_kind: 'measured',
  };
}

function assertSessionPaused(statusSnap, tag, opts = {}) {
  const want = opts.castName || 'MiSTerPlex';
  const rk = opts.ratingKey != null ? String(opts.ratingKey) : '';
  if (!statusSnap || !statusSnap.ok) {
    return {
      ok: false,
      reason: 'pms_sessions_unprobed',
      detail: `${tag}: /status/sessions unprobed`,
      value_kind: 'unprobed',
    };
  }
  const s = findSessionForPlayer(statusSnap.sessions, want, rk);
  if (!s) {
    return {
      ok: false,
      reason: 'pms_session_missing_on_pause',
      detail: `${tag}: no session on pause for ${want}`,
      value_kind: 'measured',
    };
  }
  if (!/paus/i.test(s.state || '')) {
    return {
      ok: false,
      reason: 'pms_session_not_paused',
      detail:
        `${tag}: state=${s.state} want paused rk=${s.ratingKey}. ` +
        `PRE_REGISTER fail: pause not reflected on PMS.`,
      session: s,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'pms_session_paused',
    session: s,
    ratingKey: s.ratingKey,
    state: s.state,
    value_kind: 'measured',
  };
}

/**
 * After stop: no session for our player (or empty container).
 */
function assertSessionGone(statusSnap, tag, opts = {}) {
  const want = opts.castName || 'MiSTerPlex';
  if (!statusSnap || !statusSnap.ok) {
    return {
      ok: false,
      reason: 'pms_sessions_unprobed',
      detail: `${tag}: /status/sessions unprobed after stop`,
      value_kind: 'unprobed',
    };
  }
  const leftovers = (statusSnap.sessions || []).filter((s) => matchPlayer(s, want));
  if (leftovers.length) {
    return {
      ok: false,
      reason: 'pms_session_stale_after_stop',
      detail:
        `${tag}: ${leftovers.length} leftover /status/sessions for ${want} after stop: ` +
        leftovers
          .map((s) => `rk=${s.ratingKey} state=${s.state} player=${s.player}`)
          .join('; ') +
        `. PRE_REGISTER fail: stale-session hygiene (orphan cast session).`,
      leftovers,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'pms_session_gone',
    sessions_total: statusSnap.count,
    value_kind: 'measured',
  };
}

/**
 * Transcode health from /transcode/sessions.
 * Defaults derived from parent HEALTHY vs COLLAPSED samples.
 *   minSpeed default 0.5 — collapsed speed=0 fails; healthy 19.8 passes
 *   minProgress default 5 — only while session active; after long play higher
 *   requireComplete default false during early play (complete may lag)
 */
function assertTranscodeHealth(tcSnap, tag, opts = {}) {
  const minSpeed = opts.minSpeed != null ? opts.minSpeed : 0.5;
  const minProgress = opts.minProgress != null ? opts.minProgress : 0;
  const requireComplete = opts.requireComplete === true;
  const allowEmpty = opts.allowEmpty === true; // direct play may have 0 transcoder rows

  if (!tcSnap || !tcSnap.ok) {
    return {
      ok: false,
      reason: 'pms_transcode_unprobed',
      detail: `${tag}: /transcode/sessions unprobed (${(tcSnap && tcSnap.detail) || 'NA'})`,
      value_kind: 'unprobed',
    };
  }
  if (!tcSnap.sessions.length) {
    if (allowEmpty) {
      return {
        ok: true,
        reason: 'pms_transcode_empty_direct_play',
        detail: `${tag}: no transcoder rows (direct play / copy) — not scored as collapse`,
        soft: true,
        value_kind: 'measured',
      };
    }
    return {
      ok: false,
      reason: 'pms_transcode_missing',
      detail:
        `${tag}: /transcode/sessions empty while cast active. ` +
        `PRE_REGISTER fail: expected transcoder row for lab cast (or set allowEmpty for direct play).`,
      value_kind: 'measured',
    };
  }

  // Score the "worst" active session (lowest speed) — collapse must not hide behind a healthy sibling.
  const ranked = [...tcSnap.sessions].sort((a, b) => {
    const sa = a.speed == null ? -1 : a.speed;
    const sb = b.speed == null ? -1 : b.speed;
    return sa - sb;
  });
  const t = ranked[0];
  const speed = t.speed;
  const progress = t.progress;
  const complete = !!t.complete;

  if (requireComplete && !complete) {
    return {
      ok: false,
      reason: 'pms_transcode_incomplete',
      detail:
        `${tag}: complete=0 progress=${progress} speed=${speed}. ` +
        `PRE_REGISTER fail: parent COLLAPSED class complete=0 progress=68.6 speed=0.`,
      session: t,
      value_kind: 'measured',
    };
  }
  if (speed != null && Number.isFinite(speed) && speed < minSpeed) {
    return {
      ok: false,
      reason: 'pms_transcode_speed_collapsed',
      detail:
        `${tag}: speed=${speed} < min=${minSpeed} progress=${progress} complete=${complete ? 1 : 0} ` +
        `throttled=${t.throttled ? 1 : 0} decision=${t.videoDecision || 'NA'}. ` +
        `PRE_REGISTER fail: COLLAPSED class (parent speed=0). HEALTHY speed≈19.8.`,
      session: t,
      min_speed: minSpeed,
      derivation: 'minSpeed=0.5 from parent collapsed speed=0 vs healthy 19.8',
      value_kind: 'measured',
    };
  }
  if (progress != null && Number.isFinite(progress) && progress < minProgress) {
    return {
      ok: false,
      reason: 'pms_transcode_progress_low',
      detail: `${tag}: progress=${progress} < min=${minProgress} speed=${speed}`,
      session: t,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'pms_transcode_healthy',
    session: t,
    speed,
    progress,
    complete,
    throttled: !!t.throttled,
    videoDecision: t.videoDecision || '',
    count: tcSnap.count,
    value_kind: 'measured',
    derivation: 'minSpeed=0.5 from parent collapsed speed=0 vs healthy≈19.8',
  };
}

/**
 * After stop: report leftover status + transcoder sessions (stale hygiene).
 * failOnLeftover=true → hard fail; else ok with report (still not a pass of clean).
 */
function assertStaleSessionHygiene(statusSnap, tcSnap, tag, opts = {}) {
  // OUR player leftover status sessions → hard fail when failOnLeftover.
  // Transcode leftovers alone are REPORTED but do not fail by default — the user's
  // long-lived Plex tab may keep a transcoder alive and must not red the suite.
  // Set failOnTranscodeLeftover=1 only when lab is known exclusive.
  const failOnLeftover = opts.failOnLeftover !== false;
  const failOnTranscodeLeftover = opts.failOnTranscodeLeftover === true;
  const want = opts.castName || 'MiSTerPlex';
  const statusLeft = statusSnap && statusSnap.ok ? statusSnap.sessions || [] : null;
  const tcLeft = tcSnap && tcSnap.ok ? tcSnap.sessions || [] : null;

  if (statusLeft == null || tcLeft == null) {
    return {
      ok: false,
      reason: 'pms_stale_hygiene_unprobed',
      detail: `${tag}: cannot probe leftover sessions (status_ok=${!!(statusSnap && statusSnap.ok)} tc_ok=${!!(tcSnap && tcSnap.ok)})`,
      value_kind: 'unprobed',
    };
  }

  const playerLeft = statusLeft.filter((s) => matchPlayer(s, want));
  const foreignStatus = statusLeft.filter((s) => !matchPlayer(s, want));
  const tcCount = tcLeft.length;

  const report = {
    status_total: statusLeft.length,
    status_our_player: playerLeft.length,
    status_other: foreignStatus.length,
    transcode_total: tcCount,
    our_sessions: playerLeft.map((s) => ({
      rk: s.ratingKey,
      state: s.state,
      player: s.player,
    })),
    transcode: tcLeft.map((t) => ({
      speed: t.speed,
      progress: t.progress,
      complete: t.complete,
      decision: t.videoDecision,
    })),
  };

  if (playerLeft.length) {
    const detail =
      `${tag}: STALE_SESSION_HYGIENE leftover status_our=${playerLeft.length} ` +
      `status_other=${foreignStatus.length} transcode=${tcCount}. ` +
      `our=${JSON.stringify(report.our_sessions)} tc=${JSON.stringify(report.transcode)}. ` +
      `Defect class: stop did not clear OUR cast session on PMS.`;
    if (failOnLeftover) {
      return {
        ok: false,
        reason: 'pms_stale_sessions_after_stop',
        detail,
        report,
        value_kind: 'measured',
      };
    }
    return {
      ok: true,
      softReport: true,
      reason: 'pms_stale_sessions_reported',
      detail: detail + ' failOnLeftover=0 (reported, not hard-fail)',
      report,
      value_kind: 'measured',
    };
  }

  if (tcCount > 0) {
    const detail =
      `${tag}: STALE_TRANSCODE_REPORT count=${tcCount} status_other=${foreignStatus.length} ` +
      `tc=${JSON.stringify(report.transcode)}. ` +
      `May be user long-lived Plex tab — not attributed to our controller by default.`;
    if (failOnTranscodeLeftover && foreignStatus.length === 0) {
      return {
        ok: false,
        reason: 'pms_stale_transcode_after_stop',
        detail:
          detail +
          ' failOnTranscodeLeftover=1 and no foreign status sessions — treating as our orphan.',
        report,
        value_kind: 'measured',
      };
    }
    return {
      ok: true,
      softReport: true,
      reason: 'pms_stale_transcode_reported',
      detail,
      report,
      value_kind: 'measured',
    };
  }

  return {
    ok: true,
    reason: 'pms_stale_clean',
    detail: `${tag}: no leftover /status/sessions for ${want}; transcode empty or not ours`,
    report,
    value_kind: 'measured',
  };
}

function formatPmsResult(r) {
  if (!r) return 'null';
  const bits = [
    `ok=${r.ok ? 1 : 0}`,
    `reason=${r.reason || 'NA'}`,
    r.ratingKey ? `rk=${r.ratingKey}` : '',
    r.state ? `state=${r.state}` : '',
    r.speed != null ? `speed=${r.speed}` : '',
    r.progress != null ? `progress=${r.progress}` : '',
    r.complete != null ? `complete=${r.complete ? 1 : 0}` : '',
    r.sessions_total != null ? `sessions=${r.sessions_total}` : '',
    r.softReport ? 'STALE_REPORT=1' : '',
  ].filter(Boolean);
  return bits.join(' ');
}

function selfCheck() {
  const errs = [];

  // Playing green
  const playSnap = {
    ok: true,
    count: 1,
    sessions: [
      {
        ratingKey: '9',
        title: 'BBB',
        state: 'playing',
        player: 'MiSTerPlex',
        machineIdentifier: 'misterplex-dev',
      },
    ],
  };
  const pg = assertSessionPlaying(playSnap, 't_play', { ratingKey: '9', castName: 'MiSTerPlex' });
  if (!pg.ok) errs.push('play_green');

  // Playing red — wrong rk
  const pr = assertSessionPlaying(playSnap, 't_play_rk', { ratingKey: '27', castName: 'MiSTerPlex' });
  if (pr.ok || pr.reason !== 'pms_session_wrong_rating_key') {
    errs.push(`play_wrong_rk got ${pr.reason}`);
  }

  // Playing red — missing
  const pm = assertSessionPlaying({ ok: true, count: 0, sessions: [] }, 't_miss', {
    ratingKey: '9',
  });
  if (pm.ok || pm.reason !== 'pms_session_missing') errs.push(`play_miss got ${pm.reason}`);

  // Pause
  const pauseSnap = {
    ok: true,
    count: 1,
    sessions: [{ ratingKey: '9', state: 'paused', player: 'MiSTerPlex' }],
  };
  const paz = assertSessionPaused(pauseSnap, 't_pause', { ratingKey: '9' });
  if (!paz.ok) errs.push('pause_green');
  const pazRed = assertSessionPaused(playSnap, 't_pause_red', { ratingKey: '9' });
  if (pazRed.ok || pazRed.reason !== 'pms_session_not_paused') {
    errs.push(`pause_red got ${pazRed.reason}`);
  }

  // Gone
  const gone = assertSessionGone({ ok: true, count: 0, sessions: [] }, 't_gone');
  if (!gone.ok) errs.push('gone_green');
  const goneRed = assertSessionGone(playSnap, 't_gone_red');
  if (goneRed.ok || goneRed.reason !== 'pms_session_stale_after_stop') {
    errs.push(`gone_red got ${goneRed.reason}`);
  }

  // Transcode healthy vs collapsed (parent numbers)
  const tcHealthy = {
    ok: true,
    count: 1,
    sessions: [{ complete: true, progress: 99.7, speed: 19.8, videoDecision: 'transcode', throttled: false }],
  };
  const th = assertTranscodeHealth(tcHealthy, 't_tc_h', { minSpeed: 0.5 });
  if (!th.ok) errs.push(`tc_healthy ${th.reason}`);

  const tcCollapsed = {
    ok: true,
    count: 1,
    sessions: [{ complete: false, progress: 68.6, speed: 0, videoDecision: 'transcode', throttled: true }],
  };
  const tc = assertTranscodeHealth(tcCollapsed, 't_tc_c', { minSpeed: 0.5 });
  if (tc.ok || tc.reason !== 'pms_transcode_speed_collapsed') {
    errs.push(`tc_collapsed got ${tc.reason}`);
  }

  // Stale hygiene — OUR player leftover fails; tc-only is report (user tab safe)
  const stale = assertStaleSessionHygiene(playSnap, tcCollapsed, 't_stale', {
    failOnLeftover: true,
    castName: 'MiSTerPlex',
  });
  if (stale.ok || stale.reason !== 'pms_stale_sessions_after_stop') {
    errs.push(`stale_red got ${stale.reason}`);
  }
  const tcOnly = assertStaleSessionHygiene(
    { ok: true, sessions: [], count: 0 },
    tcCollapsed,
    't_tc_only',
    { failOnLeftover: true, failOnTranscodeLeftover: false }
  );
  if (!tcOnly.ok || !tcOnly.softReport) {
    errs.push(`tc_only_should_report_not_fail got ok=${tcOnly.ok} soft=${tcOnly.softReport}`);
  }
  const clean = assertStaleSessionHygiene(
    { ok: true, sessions: [], count: 0 },
    { ok: true, sessions: [], count: 0 },
    't_clean',
    { failOnLeftover: true }
  );
  if (!clean.ok) errs.push('stale_clean');

  // XML parse smoke
  const xmlStatus =
    '<MediaContainer size="1"><Video ratingKey="9" title="BBB" sessionKey="1">' +
    '<Player title="MiSTerPlex" state="playing" machineIdentifier="misterplex-dev"/>' +
    '</Video></MediaContainer>';
  const xs = parseStatusSessionsBody(xmlStatus, 200);
  if (!xs.ok || xs.count !== 1 || xs.sessions[0].ratingKey !== '9') {
    errs.push('xml_status_parse');
  }
  const xmlTc =
    '<MediaContainer size="1">' +
    '<TranscodeSession complete="0" progress="68.6" speed="0" videoDecision="transcode" throttled="1"/>' +
    '</MediaContainer>';
  const xt = parseTranscodeSessionsBody(xmlTc, 200);
  if (!xt.ok || xt.sessions[0].speed !== 0) errs.push('xml_tc_parse');

  if (errs.length) {
    const e = new Error(errs.join('; '));
    e.errs = errs;
    throw e;
  }
  return true;
}

module.exports = {
  BOUNDARY_BANNER,
  fetchStatusSessions,
  fetchTranscodeSessions,
  parseStatusSessionsBody,
  parseTranscodeSessionsBody,
  assertSessionPlaying,
  assertSessionPaused,
  assertSessionGone,
  assertTranscodeHealth,
  assertStaleSessionHygiene,
  findSessionForPlayer,
  formatPmsResult,
  selfCheck,
  sleep,
};

if (require.main === module) {
  try {
    selfCheck();
    console.log('pms_control_plane.js selfCheck OK');
    console.log(BOUNDARY_BANNER);
    console.log(
      'PRE_REGISTER: play/pause/gone reds; tc speed=0 FAIL; tc speed=19.8 PASS; stale leftover FAIL'
    );
    process.exit(0);
  } catch (e) {
    console.error('pms_control_plane.js selfCheck FAIL', e.message);
    process.exit(1);
  }
}
