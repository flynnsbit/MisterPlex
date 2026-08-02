'use strict';

/**
 * client_truth.js — Playwright / Plex Web CLIENT observations only.
 *
 * Parent ERROR 20: daemon strings like `clock=av-lock` are unconditional
 * literals — worthless as health. This module scores only what the Plex Web
 * client shows (and optional PMS /status/sessions ratingKey the client owns).
 *
 * NEVER scores: smoothness, A/V sync, drops, av-lock, daemon telemetry.
 * Soft-skip / UNSCORED is never a pass (callers must not map ok:false+skip→PASS).
 */

const http = require('http');
const https = require('https');
const { readUiPlayerTimeline, parseClockPair, parseClockToMs } = require('./ui_timeline');

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function httpGet(url, headers = {}, timeoutMs = 8000) {
  return new Promise((resolve) => {
    const lib = String(url).startsWith('https') ? https : http;
    const req = lib.get(url, { headers, timeout: timeoutMs, rejectUnauthorized: false }, (res) => {
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
 * Sample Plex Web player clock N times (CLIENT measured).
 * @returns {Promise<Array<{wall_ms:number, ok:boolean, currentMs:number, durationMs:number, raw:string, source:string}>>}
 */
async function sampleUiClock(page, n = 5, gapMs = 400) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const ui = await readUiPlayerTimeline(page);
    out.push({
      wall_ms: Date.now(),
      ok: !!(ui && ui.ok && ui.currentMs >= 0),
      currentMs: ui && ui.currentMs != null ? ui.currentMs : -1,
      durationMs: ui && ui.durationMs != null ? ui.durationMs : -1,
      raw: (ui && ui.raw) || '',
      source: (ui && ui.source) || '',
    });
    if (i + 1 < n) await sleep(gapMs);
  }
  return out;
}

function readableSamples(samples) {
  return (samples || []).filter((s) => s && s.ok && s.currentMs >= 0);
}

/**
 * PLAYING: client clock must advance by ≥ minAdvanceMs across the sample window.
 */
function assertClientPlayingAdvances(samples, tag, opts = {}) {
  const minAdvanceMs = opts.minAdvanceMs != null ? opts.minAdvanceMs : 500;
  const good = readableSamples(samples);
  if (good.length < 2) {
    return {
      ok: false,
      reason: 'client_clock_unreadable',
      detail:
        `${tag}: need ≥2 readable UI clocks during play; got readable=${good.length}/` +
        `${(samples || []).length}. Client does not show an advancing player position.`,
      samples: summarizeSamples(samples),
      value_kind: 'measured',
    };
  }
  const first = good[0].currentMs;
  const last = good[good.length - 1].currentMs;
  const advance = last - first;
  const max = Math.max(...good.map((s) => s.currentMs));
  const min = Math.min(...good.map((s) => s.currentMs));
  const span = max - min;
  if (advance < minAdvanceMs && span < minAdvanceMs) {
    return {
      ok: false,
      reason: 'client_position_not_advancing',
      detail:
        `${tag}: UI position did not advance (first=${first} last=${last} advance=${advance} ` +
        `span=${span} min_required=${minAdvanceMs}). PRE_REGISTER fail: stopped cast / stuck UI.`,
      samples: summarizeSamples(samples),
      first_ms: first,
      last_ms: last,
      advance_ms: advance,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'client_playing_advances',
    first_ms: first,
    last_ms: last,
    advance_ms: Math.max(advance, span),
    samples: summarizeSamples(samples),
    value_kind: 'measured',
  };
}

/**
 * PAUSED: client clock must stay within maxDriftMs (not free-running).
 */
function assertClientPausedFrozen(samples, tag, opts = {}) {
  const maxDriftMs = opts.maxDriftMs != null ? opts.maxDriftMs : 1500;
  const good = readableSamples(samples);
  if (good.length < 2) {
    return {
      ok: false,
      reason: 'client_clock_unreadable',
      detail: `${tag}: need ≥2 readable UI clocks while paused; got ${good.length}`,
      samples: summarizeSamples(samples),
      value_kind: 'measured',
    };
  }
  const times = good.map((s) => s.currentMs);
  const drift = Math.max(...times) - Math.min(...times);
  if (drift > maxDriftMs) {
    return {
      ok: false,
      reason: 'client_position_still_advancing',
      detail:
        `${tag}: UI position drifted ${drift}ms while paused > max=${maxDriftMs} ` +
        `(times=${times.join(',')}). PRE_REGISTER fail: pause not effective in client.`,
      samples: summarizeSamples(samples),
      drift_ms: drift,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'client_paused_frozen',
    drift_ms: drift,
    time_ms: times[times.length - 1],
    samples: summarizeSamples(samples),
    value_kind: 'measured',
  };
}

/**
 * SEEK: client clock near target within tolMs.
 */
function assertClientSeekNear(sampleOrMs, targetMs, tag, opts = {}) {
  const tolMs = opts.tolMs != null ? opts.tolMs : 4500;
  const ms =
    typeof sampleOrMs === 'number'
      ? sampleOrMs
      : sampleOrMs && sampleOrMs.ok
        ? sampleOrMs.currentMs
        : -1;
  if (ms < 0) {
    return {
      ok: false,
      reason: 'client_clock_unreadable',
      detail: `${tag}: UI clock unreadable after seek (target=${targetMs})`,
      value_kind: 'measured',
    };
  }
  const err = Math.abs(ms - targetMs);
  if (err > tolMs) {
    return {
      ok: false,
      reason: 'client_seek_miss',
      detail:
        `${tag}: UI position ${ms}ms not within ${tolMs}ms of seek target ${targetMs}ms ` +
        `(err=${err}). PRE_REGISTER fail: seek not reflected in client timeline.`,
      ui_ms: ms,
      target_ms: targetMs,
      err_ms: err,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'client_seek_near',
    ui_ms: ms,
    target_ms: targetMs,
    err_ms: err,
    value_kind: 'measured',
  };
}

/**
 * After seek while playing: position should advance again (not stuck at land).
 */
function assertClientSeekThenAdvances(samples, tag, opts = {}) {
  return assertClientPlayingAdvances(samples, tag, {
    minAdvanceMs: opts.minAdvanceMs != null ? opts.minAdvanceMs : 400,
  });
}

/**
 * STOP / idle: client must not show an active advancing player clock.
 * Pass if clock unreadable (player chrome gone) OR frozen at end OR explicit stopped UI.
 */
async function assertClientStoppedIdle(page, tag, opts = {}) {
  const samples = opts.samples || (await sampleUiClock(page, opts.n || 4, opts.gapMs || 350));
  const good = readableSamples(samples);
  if (good.length === 0) {
    return {
      ok: true,
      reason: 'client_player_chrome_gone',
      detail: `${tag}: no UI player clock after stop — client idle (chrome dismissed)`,
      samples: summarizeSamples(samples),
      value_kind: 'measured',
    };
  }
  // Chrome still up: must not be free-running play.
  const adv = assertClientPlayingAdvances(samples, `${tag}_idle_neg`, {
    minAdvanceMs: opts.maxAdvanceMs != null ? opts.maxAdvanceMs : 800,
  });
  if (adv.ok) {
    return {
      ok: false,
      reason: 'client_still_playing',
      detail:
        `${tag}: UI position still advancing after stop (advance_ms=${adv.advance_ms}). ` +
        `PRE_REGISTER fail: stop did not return client to idle.`,
      samples: summarizeSamples(samples),
      value_kind: 'measured',
    };
  }
  // Unreadable mid-window or frozen → idle OK
  if (adv.reason === 'client_position_not_advancing' || adv.reason === 'client_clock_unreadable') {
    return {
      ok: true,
      reason: 'client_idle_or_frozen',
      detail: `${tag}: UI not advancing after stop (${adv.reason})`,
      samples: summarizeSamples(samples),
      value_kind: 'measured',
    };
  }
  return {
    ok: false,
    reason: adv.reason || 'client_stop_unverified',
    detail: adv.detail || `${tag}: stop idle not proven`,
    samples: summarizeSamples(samples),
    value_kind: 'measured',
  };
}

function summarizeSamples(samples) {
  return (samples || []).slice(0, 12).map((s) => ({
    wall_ms: s.wall_ms,
    ok: s.ok,
    currentMs: s.currentMs,
    raw: String(s.raw || '').slice(0, 40),
  }));
}

/**
 * ratingKey before/after guard.
 * mid-run content swap / respawn underneath → INVALID (not usable data).
 */
function assertRatingKeyUnchanged(before, after, tag) {
  const b = before == null || before === '' ? '' : String(before);
  const a = after == null || after === '' ? '' : String(after);
  if (!b) {
    return {
      ok: false,
      reason: 'rating_key_before_missing',
      detail: `${tag}: ratingKey BEFORE assertion missing — cannot gate session survival`,
      invalid: true,
      before: b,
      after: a,
      value_kind: 'unprobed',
    };
  }
  if (!a) {
    return {
      ok: false,
      reason: 'rating_key_after_missing',
      detail:
        `${tag}: ratingKey AFTER missing (before=${b}). Session may have died mid-window — INVALID, not data.`,
      invalid: true,
      before: b,
      after: a,
      value_kind: 'measured',
    };
  }
  if (a !== b) {
    return {
      ok: false,
      reason: 'rating_key_changed',
      detail:
        `${tag}: ratingKey changed ${b} → ${a}. Mid-run content swap/respawn — INVALID, never score as pass.`,
      invalid: true,
      before: b,
      after: a,
      value_kind: 'measured',
    };
  }
  return {
    ok: true,
    reason: 'rating_key_stable',
    ratingKey: b,
    before: b,
    after: a,
    value_kind: 'measured',
  };
}

/**
 * Read ratingKey currently playing from PMS /status/sessions (client session on server).
 * This is Plex session truth, NOT misterplexd telemetry / av-lock.
 *
 * @returns {Promise<{ok:boolean, ratingKey:string, title:string, player:string, state:string, raw_count:number, detail?:string}>}
 */
async function readPmsSessionRatingKey(plexBase, token, opts = {}) {
  const wantPlayer = String(opts.playerName || opts.castName || 'MiSTerPlex').toLowerCase();
  const headers = {
    'X-Plex-Token': token,
    Accept: 'application/json',
  };
  const url = `${String(plexBase).replace(/\/$/, '')}/status/sessions`;
  const r = await httpGet(url, headers, opts.timeoutMs || 8000);
  if (r.status !== 200) {
    return {
      ok: false,
      ratingKey: '',
      title: '',
      player: '',
      state: '',
      raw_count: 0,
      detail: `GET /status/sessions HTTP ${r.status}`,
      value_kind: 'measured',
    };
  }
  let j;
  try {
    j = JSON.parse(r.body);
  } catch (_) {
    return {
      ok: false,
      ratingKey: '',
      title: '',
      player: '',
      state: '',
      raw_count: 0,
      detail: 'sessions_bad_json',
      value_kind: 'measured',
    };
  }
  const metas = j.MediaContainer?.Metadata || [];
  const hits = [];
  for (const m of metas) {
    const player = m.Player || {};
    const title = String(m.title || '');
    const rk = String(m.ratingKey || '');
    const state = String(player.state || m.Player?.state || '');
    const pname = String(player.title || player.device || player.product || '').toLowerCase();
    const matchPlayer =
      !wantPlayer ||
      pname.includes(wantPlayer.toLowerCase()) ||
      pname.includes('misterplex') ||
      // If only one session, accept it (lab often single cast).
      metas.length === 1;
    if (matchPlayer && rk) {
      hits.push({
        ratingKey: rk,
        title,
        player: player.title || player.device || '',
        state,
      });
    }
  }
  if (!hits.length) {
    return {
      ok: false,
      ratingKey: '',
      title: '',
      player: '',
      state: '',
      raw_count: metas.length,
      detail: `no session matching player~${wantPlayer} (sessions=${metas.length})`,
      value_kind: 'measured',
    };
  }
  // Prefer playing/paused over buffering
  hits.sort((a, b) => {
    const rank = (s) =>
      /play/i.test(s) ? 0 : /paus/i.test(s) ? 1 : /buffer/i.test(s) ? 2 : 3;
    return rank(a.state) - rank(b.state);
  });
  const h = hits[0];
  return {
    ok: true,
    ratingKey: h.ratingKey,
    title: h.title,
    player: h.player,
    state: h.state,
    raw_count: metas.length,
    value_kind: 'measured',
  };
}

/**
 * Gate: capture session rk before work, after work must match expectedRatingKey.
 */
async function gateRatingKey(plexBase, token, expectedRatingKey, tag, opts = {}) {
  const sess = await readPmsSessionRatingKey(plexBase, token, opts);
  const expected = String(expectedRatingKey || '');
  if (!sess.ok) {
    return {
      ok: false,
      invalid: true,
      reason: 'session_rating_key_unprobed',
      detail:
        `${tag}: ${sess.detail || 'no session'}. ` +
        `Cannot prove ratingKey=${expected} survived — INVALID (not data).`,
      expected,
      observed: '',
      session: sess,
      value_kind: 'measured',
    };
  }
  const cmp = assertRatingKeyUnchanged(expected, sess.ratingKey, tag);
  return {
    ...cmp,
    session: sess,
    expected,
    observed: sess.ratingKey,
  };
}

function formatClientResult(r) {
  if (!r) return 'null';
  const bits = [
    `ok=${r.ok ? 1 : 0}`,
    `reason=${r.reason || 'NA'}`,
    r.invalid ? 'INVALID=1' : '',
    r.advance_ms != null ? `advance_ms=${r.advance_ms}` : '',
    r.drift_ms != null ? `drift_ms=${r.drift_ms}` : '',
    r.ui_ms != null ? `ui_ms=${r.ui_ms}` : '',
    r.ratingKey ? `rk=${r.ratingKey}` : '',
    r.before && r.after ? `rk_before=${r.before} rk_after=${r.after}` : '',
  ].filter(Boolean);
  return bits.join(' ');
}

/**
 * Pure self-check / red-before-green (no browser, no device).
 * Exit 0 only if all proofs match PRE_REGISTER.
 */
function selfCheck() {
  const errs = [];
  const playGood = assertClientPlayingAdvances(
    [
      { ok: true, currentMs: 1000, wall_ms: 1 },
      { ok: true, currentMs: 2000, wall_ms: 2 },
    ],
    't_play_green',
    { minAdvanceMs: 500 }
  );
  if (!playGood.ok) errs.push('play_green_should_pass');

  const playRed = assertClientPlayingAdvances(
    [
      { ok: true, currentMs: 1000, wall_ms: 1 },
      { ok: true, currentMs: 1050, wall_ms: 2 },
    ],
    't_play_red',
    { minAdvanceMs: 500 }
  );
  if (playRed.ok || playRed.reason !== 'client_position_not_advancing') {
    errs.push(`play_red_expected_fail got ${playRed.reason}`);
  }

  const pauseGood = assertClientPausedFrozen(
    [
      { ok: true, currentMs: 5000, wall_ms: 1 },
      { ok: true, currentMs: 5100, wall_ms: 2 },
    ],
    't_pause_green',
    { maxDriftMs: 1500 }
  );
  if (!pauseGood.ok) errs.push('pause_green_should_pass');

  const pauseRed = assertClientPausedFrozen(
    [
      { ok: true, currentMs: 5000, wall_ms: 1 },
      { ok: true, currentMs: 8000, wall_ms: 2 },
    ],
    't_pause_red',
    { maxDriftMs: 1500 }
  );
  if (pauseRed.ok || pauseRed.reason !== 'client_position_still_advancing') {
    errs.push(`pause_red_expected_fail got ${pauseRed.reason}`);
  }

  const seekGood = assertClientSeekNear(8200, 8000, 't_seek_green', { tolMs: 4500 });
  if (!seekGood.ok) errs.push('seek_green_should_pass');
  const seekRed = assertClientSeekNear(2000, 8000, 't_seek_red', { tolMs: 4500 });
  if (seekRed.ok || seekRed.reason !== 'client_seek_miss') {
    errs.push(`seek_red_expected_fail got ${seekRed.reason}`);
  }

  const rkOk = assertRatingKeyUnchanged('30', '30', 't_rk');
  if (!rkOk.ok) errs.push('rk_stable_should_pass');
  const rkSwap = assertRatingKeyUnchanged('30', '1', 't_rk_swap');
  if (rkSwap.ok || !rkSwap.invalid || rkSwap.reason !== 'rating_key_changed') {
    errs.push(`rk_swap_expected_INVALID got ${JSON.stringify(rkSwap)}`);
  }
  const rkDead = assertRatingKeyUnchanged('30', '', 't_rk_dead');
  if (rkDead.ok || !rkDead.invalid) errs.push('rk_dead_expected_INVALID');

  // parse helpers still work
  if (parseClockToMs('1:05') !== 65000) errs.push('parseClockToMs');
  if (!parseClockPair('0:34 / 6:00')) errs.push('parseClockPair');

  if (errs.length) {
    const e = new Error(errs.join('; '));
    e.errs = errs;
    throw e;
  }
  return true;
}

module.exports = {
  sampleUiClock,
  assertClientPlayingAdvances,
  assertClientPausedFrozen,
  assertClientSeekNear,
  assertClientSeekThenAdvances,
  assertClientStoppedIdle,
  assertRatingKeyUnchanged,
  readPmsSessionRatingKey,
  gateRatingKey,
  formatClientResult,
  selfCheck,
  parseClockToMs,
  parseClockPair,
  readUiPlayerTimeline,
};

if (require.main === module) {
  try {
    selfCheck();
    console.log('client_truth.js selfCheck OK');
    console.log('PRE_REGISTER: play_red/pause_red/seek_red/rk_swap → ok=0 INVALID where noted');
    process.exit(0);
  } catch (e) {
    console.error('client_truth.js selfCheck FAIL', e.message);
    process.exit(1);
  }
}
