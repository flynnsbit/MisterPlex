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
 *   GET /status/sessions      → Player state, Media WxH, embedded TranscodeSession?
 *   GET /transcode/sessions   → complete, progress, speed, videoDecision, throttled
 *   GET /library/metadata/<rk>
 *
 * Parent-measured transcode samples (same class of defect as supply collapse):
 *   HEALTHY:   complete=1 progress=99.7 speed=19.8
 *   COLLAPSED: complete=0 progress=68.6 speed=0
 *
 * Parent-measured bitrate → geometry (device ffmpeg; suite corroborates via PMS):
 *   maxVideoBitrate=397  → delivered 312x240  (n=40); NO TranscodeSession element
 *   maxVideoBitrate=2000 → delivered 624x480  (n=39)
 *   maxVideoBitrate=397  → delivered 312x240  (n=40) repeat
 * Source asset ffprobe: 624x480 @ ~397 kbps. PMS may select/deliver without a live
 * TranscodeSession (direct/copy/version pick) — absence is DATA, not NO-DATA.
 *
 * Stale-session hygiene: rapid cast/stop leaves orphaned /transcode/sessions
 * and /status/sessions — report after stop; fail when requireStaleClean=1.
 *
 * Never scores misterplexd av-lock / drops / smoothness / pixels on glass.
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
 * Extract delivery fields from one /status/sessions Metadata (or XML Video block).
 * Prefer TranscodeSession width/height when present (output); else Media/Stream.
 * hasTranscodeSession is an explicit boolean — parent found request=397 with NO element.
 */
function extractDeliveryFromMeta(m) {
  const player = (m && m.Player) || {};
  const rawTs = m && m.TranscodeSession;
  const hasTranscodeSession =
    rawTs != null &&
    typeof rawTs === 'object' &&
    !Array.isArray(rawTs) &&
    Object.keys(rawTs).length > 0;
  const ts = hasTranscodeSession ? rawTs : {};

  let media = null;
  if (m && m.Media) {
    media = Array.isArray(m.Media) ? m.Media[0] : m.Media;
  }
  let stream = null;
  if (media && media.Part) {
    const part = Array.isArray(media.Part) ? media.Part[0] : media.Part;
    const streams = (part && part.Stream) || [];
    const arr = Array.isArray(streams) ? streams : streams ? [streams] : [];
    stream =
      arr.find((s) => s && (s.streamType === 1 || String(s.streamType) === '1')) || arr[0] || null;
  }

  const mediaW = media && media.width != null ? Number(media.width) : null;
  const mediaH = media && media.height != null ? Number(media.height) : null;
  const streamW = stream && stream.width != null ? Number(stream.width) : null;
  const streamH = stream && stream.height != null ? Number(stream.height) : null;
  const tsW = ts.width != null ? Number(ts.width) : null;
  const tsH = ts.height != null ? Number(ts.height) : null;

  // Delivered guess: transcoder output dims if live TS, else stream, else media.
  let deliveredW = null;
  let deliveredH = null;
  let deliveredSource = 'none';
  if (hasTranscodeSession && tsW && tsH) {
    deliveredW = tsW;
    deliveredH = tsH;
    deliveredSource = 'TranscodeSession';
  } else if (streamW && streamH) {
    deliveredW = streamW;
    deliveredH = streamH;
    deliveredSource = 'Media.Part.Stream';
  } else if (mediaW && mediaH) {
    deliveredW = mediaW;
    deliveredH = mediaH;
    deliveredSource = 'Media';
  }

  const videoDecision = String(
    ts.videoDecision || (m && m.transcodeSession && m.transcodeSession.videoDecision) || ''
  );
  const bitrate =
    ts.videoBitrate != null
      ? Number(ts.videoBitrate)
      : ts.bitrate != null
        ? Number(ts.bitrate)
        : media && media.bitrate != null
          ? Number(media.bitrate)
          : stream && stream.bitrate != null
            ? Number(stream.bitrate)
            : null;

  return {
    ratingKey: String((m && m.ratingKey) || ''),
    title: String((m && m.title) || ''),
    state: String(player.state || (m && m.Player && m.Player.state) || ''),
    player: String(player.title || player.device || player.product || ''),
    machineIdentifier: String(player.machineIdentifier || player.address || ''),
    sessionKey: String((m && m.sessionKey) || ''),
    viewOffset: m && m.viewOffset != null ? Number(m.viewOffset) : -1,
    hasTranscodeSession,
    videoDecision,
    audioDecision: String(ts.audioDecision || ''),
    media_width: mediaW,
    media_height: mediaH,
    stream_width: streamW,
    stream_height: streamH,
    ts_width: tsW,
    ts_height: tsH,
    delivered_width: deliveredW,
    delivered_height: deliveredH,
    delivered_geom:
      deliveredW && deliveredH ? `${deliveredW}x${deliveredH}` : null,
    delivered_source: deliveredSource,
    bitrate,
    videoResolution: String((media && media.videoResolution) || ts.videoResolution || ''),
    transcode: {
      present: hasTranscodeSession,
      videoDecision,
      audioDecision: String(ts.audioDecision || ''),
      throttled: ts.throttled === true || ts.throttled === 1 || ts.throttled === '1',
      complete: ts.complete === true || ts.complete === 1 || String(ts.complete) === '1',
      progress: ts.progress != null ? Number(ts.progress) : null,
      speed: ts.speed != null ? Number(ts.speed) : null,
      width: tsW,
      height: tsH,
    },
  };
}

function extractDeliveryFromXmlBlock(block) {
  const playerBlock = (block.match(/<Player\b[^>]*\/>|<Player\b[^>]*>[\s\S]*?<\/Player>/i) || [
    '',
  ])[0];
  const tsBlock = (block.match(/<TranscodeSession\b[^>]*\/?>/i) || [''])[0];
  const mediaBlock = (block.match(/<Media\b[^>]*\/?>|<Media\b[^>]*>[\s\S]*?<\/Media>/i) || [
    '',
  ])[0];
  const streamBlock = (block.match(/<Stream\b[^>]*streamType="1"[^>]*\/?>/i) ||
    block.match(/<Stream\b[^>]*\/?>/i) || [''])[0];
  const hasTranscodeSession = !!tsBlock && /TranscodeSession/i.test(tsBlock);
  const mediaW = parseInt(attr(mediaBlock, 'width') || '0', 10) || null;
  const mediaH = parseInt(attr(mediaBlock, 'height') || '0', 10) || null;
  const streamW = parseInt(attr(streamBlock, 'width') || '0', 10) || null;
  const streamH = parseInt(attr(streamBlock, 'height') || '0', 10) || null;
  const tsW = parseInt(attr(tsBlock, 'width') || '0', 10) || null;
  const tsH = parseInt(attr(tsBlock, 'height') || '0', 10) || null;
  let deliveredW = null;
  let deliveredH = null;
  let deliveredSource = 'none';
  if (hasTranscodeSession && tsW && tsH) {
    deliveredW = tsW;
    deliveredH = tsH;
    deliveredSource = 'TranscodeSession';
  } else if (streamW && streamH) {
    deliveredW = streamW;
    deliveredH = streamH;
    deliveredSource = 'Media.Part.Stream';
  } else if (mediaW && mediaH) {
    deliveredW = mediaW;
    deliveredH = mediaH;
    deliveredSource = 'Media';
  }
  const videoDecision = attr(tsBlock, 'videoDecision') || '';
  return {
    ratingKey: attr(block, 'ratingKey'),
    title: attr(block, 'title'),
    state: attr(playerBlock, 'state') || attr(block, 'state'),
    player: attr(playerBlock, 'title') || attr(playerBlock, 'device') || attr(playerBlock, 'product'),
    machineIdentifier: attr(playerBlock, 'machineIdentifier') || attr(playerBlock, 'address'),
    sessionKey: attr(block, 'sessionKey'),
    viewOffset: parseInt(attr(block, 'viewOffset') || '-1', 10),
    hasTranscodeSession,
    videoDecision,
    audioDecision: attr(tsBlock, 'audioDecision') || '',
    media_width: mediaW,
    media_height: mediaH,
    stream_width: streamW,
    stream_height: streamH,
    ts_width: tsW,
    ts_height: tsH,
    delivered_width: deliveredW,
    delivered_height: deliveredH,
    delivered_geom: deliveredW && deliveredH ? `${deliveredW}x${deliveredH}` : null,
    delivered_source: deliveredSource,
    bitrate: parseInt(attr(tsBlock, 'videoBitrate') || attr(mediaBlock, 'bitrate') || '0', 10) || null,
    videoResolution: attr(mediaBlock, 'videoResolution') || '',
    transcode: {
      present: hasTranscodeSession,
      videoDecision,
      audioDecision: attr(tsBlock, 'audioDecision') || '',
      throttled: attr(tsBlock, 'throttled') === '1',
      complete: attr(tsBlock, 'complete') === '1',
      progress: attr(tsBlock, 'progress') !== '' ? Number(attr(tsBlock, 'progress')) : null,
      speed: attr(tsBlock, 'speed') !== '' ? Number(attr(tsBlock, 'speed')) : null,
      width: tsW,
      height: tsH,
    },
  };
}

/**
 * Normalize /status/sessions into a list of session rows (with delivery fields).
 */
function parseStatusSessionsBody(body, status) {
  if (status !== 200) {
    return { ok: false, sessions: [], detail: `HTTP ${status}`, value_kind: 'measured' };
  }
  const j = parseJsonSafe(body);
  if (j && j.MediaContainer) {
    const metas = j.MediaContainer.Metadata || [];
    const sessions = metas.map((m) => extractDeliveryFromMeta(m));
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
    sessions.push(extractDeliveryFromXmlBlock(m[0]));
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
        width: t.width != null ? Number(t.width) : null,
        height: t.height != null ? Number(t.height) : null,
        bitrate: t.videoBitrate != null ? Number(t.videoBitrate) : t.bitrate != null ? Number(t.bitrate) : null,
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
      width: attr(block, 'width') !== '' ? Number(attr(block, 'width')) : null,
      height: attr(block, 'height') !== '' ? Number(attr(block, 'height')) : null,
      bitrate: attr(block, 'videoBitrate') !== '' ? Number(attr(block, 'videoBitrate')) : null,
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
 * PMS-side delivery observation (independent of daemon logs / ffmpeg banner).
 *
 * CAN settle:
 *   - session exists for cast player + ratingKey
 *   - hasTranscodeSession true|false (absence at bitrate=397 is DATA)
 *   - delivered_geom from TranscodeSession WxH or Media/Stream WxH
 *   - videoDecision when TranscodeSession present
 *   - /transcode/sessions row count as second channel
 *
 * CANNOT settle: pixels on glass. Never PASS picture correctness.
 *
 * @param {object} statusSnap from fetchStatusSessions
 * @param {object|null} tcSnap from fetchTranscodeSessions (optional second channel)
 * @param {string} tag
 * @param {object} opts
 *   castName, ratingKey
 *   expectGeom: "312x240" — hard fail if delivered differs when set
 *   expectHasTranscode: true|false|null — null = observe only
 *   expectDecision: "copy"|"transcode"|null
 *   requireGeom: if true, missing delivered_geom → FAIL (not soft)
 */
function assertPmsDeliveryObservation(statusSnap, tcSnap, tag, opts = {}) {
  const want = opts.castName || 'MiSTerPlex';
  const rk = opts.ratingKey != null ? String(opts.ratingKey) : '';
  const requireGeom = opts.requireGeom === true;
  const expectGeom = opts.expectGeom ? String(opts.expectGeom).trim() : '';
  const expectHasTs =
    opts.expectHasTranscode === undefined || opts.expectHasTranscode === null
      ? null
      : !!opts.expectHasTranscode;
  const expectDecision = opts.expectDecision
    ? String(opts.expectDecision).toLowerCase()
    : '';

  if (!statusSnap || !statusSnap.ok) {
    return {
      ok: false,
      reason: 'pms_delivery_unprobed',
      detail: `${tag}: /status/sessions unprobed — cannot observe PMS delivery`,
      value_kind: 'unprobed',
    };
  }
  const s = findSessionForPlayer(statusSnap.sessions, want, rk);
  if (!s) {
    return {
      ok: false,
      reason: 'pms_delivery_no_session',
      detail: `${tag}: no session for ${want} rk=${rk || '*'} — cannot observe delivery`,
      value_kind: 'measured',
    };
  }

  const tcCount = tcSnap && tcSnap.ok ? tcSnap.count : null;
  const tcGeom =
    tcSnap && tcSnap.ok && tcSnap.sessions && tcSnap.sessions[0]
      ? tcSnap.sessions[0].width && tcSnap.sessions[0].height
        ? `${tcSnap.sessions[0].width}x${tcSnap.sessions[0].height}`
        : null
      : null;

  // Prefer session embedded delivery; fall back to /transcode/sessions geom.
  let delivered = s.delivered_geom;
  let deliveredSource = s.delivered_source || 'none';
  if (!delivered && tcGeom) {
    delivered = tcGeom;
    deliveredSource = '/transcode/sessions';
  }

  const report = {
    ratingKey: s.ratingKey,
    state: s.state,
    player: s.player,
    hasTranscodeSession: !!s.hasTranscodeSession,
    videoDecision: s.videoDecision || '',
    delivered_geom: delivered,
    delivered_source: deliveredSource,
    media_geom:
      s.media_width && s.media_height ? `${s.media_width}x${s.media_height}` : null,
    ts_geom: s.ts_width && s.ts_height ? `${s.ts_width}x${s.ts_height}` : null,
    bitrate: s.bitrate,
    transcode_sessions_count: tcCount,
    value_kind: 'measured_pms',
  };

  if (requireGeom && !delivered) {
    return {
      ok: false,
      reason: 'pms_delivery_geom_missing',
      detail:
        `${tag}: session present but no Media/TranscodeSession WxH. ` +
        `hasTS=${report.hasTranscodeSession ? 1 : 0} tc_count=${tcCount}. ` +
        `PRE_REGISTER fail: PMS delivery geometry NO-DATA (not 0x0).`,
      report,
      value_kind: 'measured',
    };
  }

  if (expectHasTs !== null && !!s.hasTranscodeSession !== expectHasTs) {
    return {
      ok: false,
      reason: 'pms_delivery_transcode_presence_mismatch',
      detail:
        `${tag}: hasTranscodeSession=${s.hasTranscodeSession ? 1 : 0} expected=${expectHasTs ? 1 : 0}. ` +
        `Parent class: request=397 often has NO TranscodeSession; request=2000 may have one. ` +
        `report=${JSON.stringify(report)}`,
      report,
      value_kind: 'measured',
    };
  }

  if (expectDecision && report.videoDecision) {
    if (String(report.videoDecision).toLowerCase() !== expectDecision) {
      return {
        ok: false,
        reason: 'pms_delivery_decision_mismatch',
        detail:
          `${tag}: videoDecision=${report.videoDecision} expected=${expectDecision} ` +
          `report=${JSON.stringify(report)}`,
        report,
        value_kind: 'measured',
      };
    }
  }

  if (expectGeom && delivered && delivered !== expectGeom) {
    return {
      ok: false,
      reason: 'pms_delivery_geom_mismatch',
      detail:
        `${tag}: PMS delivered_geom=${delivered} (src=${deliveredSource}) != expect ${expectGeom}. ` +
        `hasTS=${report.hasTranscodeSession ? 1 : 0} decision=${report.videoDecision || 'NA'}. ` +
        `Parent ladder: 397→312x240, 2000→624x480. report=${JSON.stringify(report)}`,
      report,
      value_kind: 'measured',
    };
  }
  if (expectGeom && !delivered) {
    return {
      ok: false,
      reason: 'pms_delivery_geom_missing',
      detail:
        `${tag}: expected geom ${expectGeom} but PMS delivered_geom=NO-DATA. ` +
        `report=${JSON.stringify(report)}`,
      report,
      value_kind: 'measured',
    };
  }

  return {
    ok: true,
    reason: 'pms_delivery_observed',
    detail:
      `${tag}: PMS_DELIVERY rk=${report.ratingKey} state=${report.state} ` +
      `delivered=${delivered || 'NO-DATA'} src=${deliveredSource} ` +
      `hasTranscodeSession=${report.hasTranscodeSession ? 1 : 0} ` +
      `decision=${report.videoDecision || 'NA'} tc_sessions=${tcCount} ` +
      `media=${report.media_geom || 'NA'} ts=${report.ts_geom || 'NA'} ` +
      `bitrate=${report.bitrate != null ? report.bitrate : 'NA'} ` +
      `value_kind=measured_pms NOT_pixels`,
    report,
    session: s,
    value_kind: 'measured',
  };
}

/**
 * Format a single-line banner for logs / parent correlation.
 */
function formatPmsDeliveryLine(obs, tag = 'pms_delivery') {
  if (!obs) return `${tag}: NO-DATA`;
  if (!obs.ok) return `${tag}: FAIL reason=${obs.reason} ${obs.detail || ''}`;
  return obs.detail || `${tag}: OK`;
}

/**
 * Transcode health from /transcode/sessions.
 * Defaults derived from parent HEALTHY vs COLLAPSED samples.
 *   minSpeed default 0.5 — collapsed speed=0 fails; healthy 19.8 passes
 *   minProgress default 5 — only while session active; after long play higher
 *   requireComplete default false during early play (complete may lag)
 *
 * NOTE: empty /transcode/sessions is valid DATA for direct-play / no-TS class
 * (parent: maxVideoBitrate=397 often has zero transcoder rows). allowEmpty default
 * true when scoring "health"; use expectHasTranscode on assertPmsDeliveryObservation
 * to require presence/absence.
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
    '<Media width="624" height="480" bitrate="397288"/>' +
    '</Video></MediaContainer>';
  const xs = parseStatusSessionsBody(xmlStatus, 200);
  if (!xs.ok || xs.count !== 1 || xs.sessions[0].ratingKey !== '9') {
    errs.push('xml_status_parse');
  }
  if (xs.sessions[0].delivered_geom !== '624x480' || xs.sessions[0].hasTranscodeSession) {
    errs.push(`xml_delivery got geom=${xs.sessions[0].delivered_geom} hasTS=${xs.sessions[0].hasTranscodeSession}`);
  }
  const xmlTc =
    '<MediaContainer size="1">' +
    '<TranscodeSession complete="0" progress="68.6" speed="0" videoDecision="transcode" throttled="1" width="312" height="240"/>' +
    '</MediaContainer>';
  const xt = parseTranscodeSessionsBody(xmlTc, 200);
  if (!xt.ok || xt.sessions[0].speed !== 0) errs.push('xml_tc_parse');
  if (xt.sessions[0].width !== 312 || xt.sessions[0].height !== 240) {
    errs.push('xml_tc_geom');
  }

  // Parent bitrate ladder classes via JSON session docs
  // 397 → 312x240, NO TranscodeSession
  const j397 = {
    MediaContainer: {
      size: 1,
      Metadata: [
        {
          ratingKey: '36',
          title: 'Bank480',
          sessionKey: '1',
          Player: { title: 'MiSTerPlex', state: 'playing', machineIdentifier: 'misterplex-dev' },
          Media: [{ width: 312, height: 240, bitrate: 397288, videoResolution: '240' }],
        },
      ],
    },
  };
  const p397 = parseStatusSessionsBody(JSON.stringify(j397), 200);
  const d397 = assertPmsDeliveryObservation(
    p397,
    { ok: true, sessions: [], count: 0 },
    't_397',
    {
      castName: 'MiSTerPlex',
      ratingKey: '36',
      expectGeom: '312x240',
      expectHasTranscode: false,
      requireGeom: true,
    }
  );
  if (!d397.ok) errs.push(`delivery_397 ${d397.reason}`);
  if (d397.report && d397.report.hasTranscodeSession) errs.push('delivery_397_hasTS');

  // 2000 → 624x480 with TranscodeSession output dims
  const j2000 = {
    MediaContainer: {
      size: 1,
      Metadata: [
        {
          ratingKey: '36',
          title: 'Bank480',
          sessionKey: '2',
          Player: { title: 'MiSTerPlex', state: 'playing' },
          Media: [{ width: 624, height: 480, bitrate: 2000000 }],
          TranscodeSession: {
            videoDecision: 'transcode',
            width: 624,
            height: 480,
            speed: 19.8,
            complete: true,
            progress: 99.7,
          },
        },
      ],
    },
  };
  const p2000 = parseStatusSessionsBody(JSON.stringify(j2000), 200);
  if (!p2000.sessions[0].hasTranscodeSession) errs.push('json_2000_hasTS');
  if (p2000.sessions[0].delivered_geom !== '624x480') {
    errs.push(`json_2000_geom ${p2000.sessions[0].delivered_geom}`);
  }
  const d2000 = assertPmsDeliveryObservation(p2000, null, 't_2000', {
    castName: 'MiSTerPlex',
    ratingKey: '36',
    expectGeom: '624x480',
    expectHasTranscode: true,
    expectDecision: 'transcode',
  });
  if (!d2000.ok) errs.push(`delivery_2000 ${d2000.reason}`);

  // Mismatch must fail (red-before-green)
  const dMiss = assertPmsDeliveryObservation(p397, null, 't_miss_geom', {
    castName: 'MiSTerPlex',
    expectGeom: '624x480',
  });
  if (dMiss.ok || dMiss.reason !== 'pms_delivery_geom_mismatch') {
    errs.push(`delivery_mismatch got ${dMiss.reason}`);
  }
  const dTsMiss = assertPmsDeliveryObservation(p397, null, 't_ts_miss', {
    castName: 'MiSTerPlex',
    expectHasTranscode: true,
  });
  if (dTsMiss.ok || dTsMiss.reason !== 'pms_delivery_transcode_presence_mismatch') {
    errs.push(`delivery_ts_miss got ${dTsMiss.reason}`);
  }

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
  extractDeliveryFromMeta,
  assertSessionPlaying,
  assertSessionPaused,
  assertSessionGone,
  assertTranscodeHealth,
  assertPmsDeliveryObservation,
  formatPmsDeliveryLine,
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
    console.log(
      'PMS_DELIVERY: can observe hasTranscodeSession + delivered_geom from /status/sessions ' +
        '(parent ladder 397→312x240 no-TS; 2000→624x480). CANNOT prove pixels.'
    );
    process.exit(0);
  } catch (e) {
    console.error('pms_control_plane.js selfCheck FAIL', e.message);
    process.exit(1);
  }
}
