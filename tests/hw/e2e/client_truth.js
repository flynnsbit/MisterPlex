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
 * Realtime rate gate — media timeline vs wall clock during continuous play.
 *
 * WHY THIS EXISTS (parent-measured 480p collapse, same session):
 *   starved: vfps 11.1 pfps 6.4 drops climbing  audio_s/wall_s = 0.467
 *   healthy: vfps 23.8 pfps 23.6 drops flat     audio_s/wall_s = 0.993
 * Timeline still advanced in both cases — advance-only gates called both PASS.
 *
 * DERIVED TOLERANCE (do not invent loosely):
 *   target rate = 1.0 media_ms / wall_ms
 *   measured healthy = 0.993, measured starved = 0.467, gap = 0.526
 *   min_ratio default = 0.75
 *     — above starved (0.467) so collapse fails
 *     — below healthy (0.993) so real-time passes
 *     — slightly above midpoint 0.730 toward healthy to absorb UI sample jitter
 *   max_ratio default = 1.35
 *     — allows brief UI catch-up after buffer; free-run / double-speed fails
 *
 * EXCLUSIONS (caller + sample filter):
 *   - pause: media_delta≈0 → ratio≈0 — only sample while playing
 *   - seek: discontinuous media jump — drop steps where media moves backward
 *     or media_step > wall_step * max_ratio * seekRejectFactor
 *   - startup: require minWallMs of usable contiguous play before scoring
 *
 * value_kind=measured (from samples). Soft-skip is never a pass for callers.
 */
function assertClientRealtimeRate(samples, tag, opts = {}) {
  const minRatio = opts.minRatio != null ? opts.minRatio : 0.75;
  const maxRatio = opts.maxRatio != null ? opts.maxRatio : 1.35;
  const minWallMs = opts.minWallMs != null ? opts.minWallMs : 3000;
  const minPairs = opts.minPairs != null ? opts.minPairs : 3;
  const seekRejectFactor = opts.seekRejectFactor != null ? opts.seekRejectFactor : 1.5;
  const good = readableSamples(samples).filter((s) => s.wall_ms > 0);
  if (good.length < 2) {
    return {
      ok: false,
      reason: 'client_rate_unreadable',
      detail:
        `${tag}: need ≥2 readable UI clocks with wall_ms for realtime rate; ` +
        `got readable=${good.length}. PRE_REGISTER fail: cannot score rate.`,
      samples: summarizeSamples(samples),
      min_ratio: minRatio,
      max_ratio: maxRatio,
      value_kind: 'measured',
    };
  }

  // Build contiguous play pairs; drop seek/pause-like discontinuities.
  const pairs = [];
  let rejectedSeek = 0;
  let rejectedPause = 0;
  for (let i = 1; i < good.length; i++) {
    const a = good[i - 1];
    const b = good[i];
    const dWall = b.wall_ms - a.wall_ms;
    const dMedia = b.currentMs - a.currentMs;
    if (dWall <= 0) continue;
    if (dMedia < 0) {
      rejectedSeek++;
      continue; // rewind / scrub backward
    }
    if (dMedia === 0) {
      rejectedPause++;
      continue; // frozen step (pause or stall) — not a rate sample
    }
    const stepRatio = dMedia / dWall;
    if (stepRatio > maxRatio * seekRejectFactor) {
      rejectedSeek++;
      continue; // discontinuous seek jump forward
    }
    pairs.push({ dWall, dMedia, stepRatio, from: a.currentMs, to: b.currentMs });
  }

  if (pairs.length < minPairs) {
    return {
      ok: false,
      reason: 'client_rate_insufficient_pairs',
      detail:
        `${tag}: usable play pairs=${pairs.length} < min=${minPairs} ` +
        `(rejected_seekish=${rejectedSeek} rejected_frozen=${rejectedPause}). ` +
        `PRE_REGISTER fail: window too short or dominated by pause/seek.`,
      pairs: pairs.length,
      rejected_seekish: rejectedSeek,
      rejected_frozen: rejectedPause,
      min_ratio: minRatio,
      max_ratio: maxRatio,
      samples: summarizeSamples(samples),
      value_kind: 'measured',
    };
  }

  const sumWall = pairs.reduce((s, p) => s + p.dWall, 0);
  const sumMedia = pairs.reduce((s, p) => s + p.dMedia, 0);
  if (sumWall < minWallMs) {
    return {
      ok: false,
      reason: 'client_rate_window_short',
      detail:
        `${tag}: usable wall_ms=${sumWall} < minWallMs=${minWallMs}. ` +
        `PRE_REGISTER fail: hold continuous play longer before scoring rate.`,
      wall_ms: sumWall,
      media_ms: sumMedia,
      pairs: pairs.length,
      min_ratio: minRatio,
      max_ratio: maxRatio,
      value_kind: 'measured',
    };
  }

  const ratio = sumMedia / sumWall;
  const base = {
    ratio,
    wall_ms: sumWall,
    media_ms: sumMedia,
    pairs: pairs.length,
    rejected_seekish: rejectedSeek,
    rejected_frozen: rejectedPause,
    min_ratio: minRatio,
    max_ratio: maxRatio,
    samples: summarizeSamples(samples),
    value_kind: 'measured',
    derivation:
      'min_ratio=0.75 from parent starved audio_s/wall_s=0.467 vs healthy=0.993 (midpoint 0.730 + jitter margin); max_ratio=1.35 catch-up band',
  };

  if (ratio < minRatio) {
    return {
      ok: false,
      reason: 'client_realtime_rate_low',
      detail:
        `${tag}: media/wall ratio=${ratio.toFixed(3)} < min=${minRatio} ` +
        `(media_ms=${sumMedia} wall_ms=${sumWall} pairs=${pairs.length}). ` +
        `PRE_REGISTER fail: starved-class (parent collapse audio_s/wall_s=0.467). ` +
        `Advance-only would have passed — rate gate catches under-realtime play.`,
      ...base,
    };
  }
  if (ratio > maxRatio) {
    return {
      ok: false,
      reason: 'client_realtime_rate_high',
      detail:
        `${tag}: media/wall ratio=${ratio.toFixed(3)} > max=${maxRatio} ` +
        `(media_ms=${sumMedia} wall_ms=${sumWall}). ` +
        `PRE_REGISTER fail: free-run / double-speed / seek residue in window.`,
      ...base,
    };
  }
  return {
    ok: true,
    reason: 'client_realtime_rate_ok',
    detail:
      `${tag}: ratio=${ratio.toFixed(3)} in [${minRatio},${maxRatio}] ` +
      `media_ms=${sumMedia} wall_ms=${sumWall} pairs=${pairs.length}`,
    ...base,
  };
}

/**
 * Build synthetic samples for red/green rate proofs (no browser).
 * rate = media_ms per wall_ms (e.g. 0.467 starved, 0.993 healthy).
 */
function synthesizeRateSamples(rate, opts = {}) {
  const n = opts.n != null ? opts.n : 8;
  const gapWall = opts.gapWallMs != null ? opts.gapWallMs : 500;
  const t0 = opts.t0Media != null ? opts.t0Media : 10000;
  const w0 = opts.w0 != null ? opts.w0 : 1_000_000;
  const out = [];
  for (let i = 0; i < n; i++) {
    out.push({
      ok: true,
      wall_ms: w0 + i * gapWall,
      currentMs: Math.round(t0 + i * gapWall * rate),
      durationMs: 600000,
      raw: `synth rate=${rate}`,
      source: 'synth',
    });
  }
  return out;
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
    r.ratio != null && Number.isFinite(r.ratio) ? `ratio=${Number(r.ratio).toFixed(3)}` : '',
    r.wall_ms != null ? `wall_ms=${r.wall_ms}` : '',
    r.media_ms != null ? `media_ms=${r.media_ms}` : '',
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

  // Realtime rate — fixture data from parent-measured collapse session.
  // healthy audio_s/wall_s=0.993 → PASS; starved 0.467 → FAIL client_realtime_rate_low
  const rateHealthy = assertClientRealtimeRate(
    synthesizeRateSamples(0.993, { n: 10, gapWallMs: 500 }),
    't_rate_healthy',
    { minRatio: 0.75, maxRatio: 1.35, minWallMs: 3000, minPairs: 3 }
  );
  if (!rateHealthy.ok) {
    errs.push(`rate_healthy_should_pass got ${rateHealthy.reason} ratio=${rateHealthy.ratio}`);
  }
  const rateStarved = assertClientRealtimeRate(
    synthesizeRateSamples(0.467, { n: 10, gapWallMs: 500 }),
    't_rate_starved',
    { minRatio: 0.75, maxRatio: 1.35, minWallMs: 3000, minPairs: 3 }
  );
  if (rateStarved.ok || rateStarved.reason !== 'client_realtime_rate_low') {
    errs.push(
      `rate_starved_expected_fail got ok=${rateStarved.ok} reason=${rateStarved.reason} ratio=${rateStarved.ratio}`
    );
  }
  // Pause-dominated window: all frozen steps → insufficient pairs (not a false PASS)
  const paused = synthesizeRateSamples(0, { n: 8, gapWallMs: 500 });
  const ratePause = assertClientRealtimeRate(paused, 't_rate_pause', {
    minRatio: 0.75,
    minWallMs: 1000,
    minPairs: 3,
  });
  if (ratePause.ok || ratePause.reason !== 'client_rate_insufficient_pairs') {
    errs.push(`rate_pause_expected_insufficient got ${ratePause.reason}`);
  }
  // Seek jump then steady: large media step rejected; remaining pairs still healthy
  const seekish = synthesizeRateSamples(1.0, { n: 8, gapWallMs: 500, t0Media: 1000 });
  seekish[3] = {
    ...seekish[3],
    currentMs: seekish[2].currentMs + 60000, // +60s jump on 500ms wall
  };
  // repair subsequent samples to continue from jump at rate 1.0
  for (let i = 4; i < seekish.length; i++) {
    seekish[i].currentMs = seekish[3].currentMs + (i - 3) * 500;
  }
  const rateSeek = assertClientRealtimeRate(seekish, 't_rate_seek_filter', {
    minRatio: 0.75,
    maxRatio: 1.35,
    minWallMs: 2000,
    minPairs: 3,
  });
  if (!rateSeek.ok) {
    errs.push(`rate_seek_filter_should_pass got ${rateSeek.reason} ratio=${rateSeek.ratio}`);
  }
  if (!(rateSeek.rejected_seekish >= 1)) {
    errs.push(`rate_seek_filter_expected_rejected_seekish got ${rateSeek.rejected_seekish}`);
  }

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
  assertClientRealtimeRate,
  synthesizeRateSamples,
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
    console.log(
      'PRE_REGISTER: play_red/pause_red/seek_red/rk_swap INVALID; ' +
        'rate_starved(0.467) FAIL; rate_healthy(0.993) PASS; pause/seek excluded'
    );
    process.exit(0);
  } catch (e) {
    console.error('client_truth.js selfCheck FAIL', e.message);
    process.exit(1);
  }
}
