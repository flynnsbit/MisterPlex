'use strict';
/**
 * Read the timeline the *user* sees in Plex Web and compare to companion daemon.
 * HDMI capture can see glass chrome; this is the control-plane truthfulness gate.
 *
 * Does NOT score lipsync / A/V offset.
 */

/**
 * Parse "M:SS", "H:MM:SS", "MM:SS" → milliseconds. Returns -1 on failure.
 */
function parseClockToMs(text) {
  const s = String(text || '').trim();
  const m = s.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) return -1;
  if (m[3] !== undefined) {
    const h = parseInt(m[1], 10);
    const min = parseInt(m[2], 10);
    const sec = parseInt(m[3], 10);
    return ((h * 60 + min) * 60 + sec) * 1000;
  }
  const min = parseInt(m[1], 10);
  const sec = parseInt(m[2], 10);
  return (min * 60 + sec) * 1000;
}

/**
 * Extract current/duration from strings like "0:34 / 6:00" or "0:34/6:00".
 */
function parseClockPair(text) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  const m = s.match(/(\d{1,2}:\d{2}(?::\d{2})?)\s*\/\s*(\d{1,2}:\d{2}(?::\d{2})?)/);
  if (!m) return null;
  const cur = parseClockToMs(m[1]);
  const dur = parseClockToMs(m[2]);
  if (cur < 0 || dur <= 0) return null;
  return { currentMs: cur, durationMs: dur, raw: `${m[1]} / ${m[2]}` };
}

/**
 * Best-effort read of Plex Web player clock + scrubber.
 * Prefers stable testids / ARIA; falls back to body text pair scan.
 */
async function readUiPlayerTimeline(page) {
  const tried = [];
  const result = {
    ok: false,
    currentMs: -1,
    durationMs: -1,
    pct: null,
    source: '',
    raw: '',
    tried,
  };

  // 1) Combined time label common in Plex Web
  const textSels = [
    '[data-testid="player-controls-time"]',
    '[data-testid="durationButton"]',
    '[class*="PlayerControls-time"]',
    '[class*="DurationButton"]',
    'button[aria-label*="Duration"]',
    '[aria-label*="Current time"]',
  ];
  for (const sel of textSels) {
    tried.push(sel);
    try {
      const loc = page.locator(sel).first();
      if (!(await loc.isVisible({ timeout: 800 }).catch(() => false))) continue;
      const t = ((await loc.innerText().catch(() => '')) || (await loc.textContent().catch(() => '')) || '')
        .replace(/\s+/g, ' ')
        .trim();
      const pair = parseClockPair(t);
      if (pair) {
        result.ok = true;
        result.currentMs = pair.currentMs;
        result.durationMs = pair.durationMs;
        result.pct = pair.durationMs > 0 ? pair.currentMs / pair.durationMs : null;
        result.source = `selector:${sel}`;
        result.raw = pair.raw;
        return result;
      }
      // Sometimes only current time in the node
      const only = parseClockToMs(t);
      if (only >= 0) {
        result.currentMs = only;
        result.source = `selector_current_only:${sel}`;
        result.raw = t;
      }
    } catch (_) {
      /* next */
    }
  }

  // 2) Range / slider aria-valuenow (0–100 or ms)
  const sliderSels = [
    '[data-testid="seekBar"] [role="slider"]',
    '[data-testid="seekBar"]',
    '[class*="SeekBar"] [role="slider"]',
    'input[type="range"]',
    '[role="slider"][aria-valuenow]',
  ];
  for (const sel of sliderSels) {
    tried.push(sel);
    try {
      const loc = page.locator(sel).first();
      if (!(await loc.isVisible({ timeout: 600 }).catch(() => false))) continue;
      const now = await loc.getAttribute('aria-valuenow');
      const max = await loc.getAttribute('aria-valuemax');
      const min = await loc.getAttribute('aria-valuemin');
      const val = now != null ? parseFloat(now) : NaN;
      const vmax = max != null ? parseFloat(max) : NaN;
      const vmin = min != null ? parseFloat(min) : 0;
      if (!Number.isFinite(val)) continue;
      if (Number.isFinite(vmax) && vmax > 1000) {
        // values in ms
        result.currentMs = Math.round(val);
        result.durationMs = Math.round(vmax);
        result.pct = vmax > vmin ? (val - vmin) / (vmax - vmin) : null;
        result.source = `slider_ms:${sel}`;
        result.raw = `now=${now} max=${max}`;
        result.ok = result.currentMs >= 0 && result.durationMs > 0;
        if (result.ok) return result;
      } else if (Number.isFinite(vmax) && vmax > 0) {
        result.pct = (val - vmin) / (vmax - vmin);
        result.source = `slider_pct:${sel}`;
        result.raw = `now=${now} max=${max}`;
        if (result.currentMs < 0 && result.pct != null) {
          // pct only until we pair with duration from elsewhere
          result.ok = false;
        }
      }
    } catch (_) {
      /* next */
    }
  }

  // 3) Body text scan for "M:SS / M:SS" (last resort — scoped to short window)
  try {
    const body = await page.evaluate(() => {
      const root =
        document.querySelector('[class*="Player"]') ||
        document.querySelector('[class*="player"]') ||
        document.body;
      return (root && root.innerText) || '';
    });
    const lines = String(body)
      .split(/\n/)
      .map((l) => l.trim())
      .filter(Boolean);
    for (const line of lines.slice(-80)) {
      const pair = parseClockPair(line);
      if (pair) {
        result.ok = true;
        result.currentMs = pair.currentMs;
        result.durationMs = pair.durationMs;
        result.pct = pair.durationMs > 0 ? pair.currentMs / pair.durationMs : null;
        result.source = 'body_text_pair';
        result.raw = pair.raw;
        return result;
      }
    }
  } catch (_) {
    /* ignore */
  }

  // pct-only from slider + duration from pair failure
  if (result.pct != null && result.currentMs < 0) {
    result.ok = false;
    result.source = result.source || 'pct_only';
  }
  return result;
}

/**
 * Compare UI clock to daemon timeline sample.
 *
 * @param {{currentMs,durationMs,pct,source,raw,ok}} ui
 * @param {{time:number,duration:number,state:string}} daemon
 * @param {string} tag
 * @param {{maxSkewMs?: number, maxPctPoints?: number}} [opts]
 */
function assertUiDaemonTimeline(ui, daemon, tag, opts = {}) {
  const maxSkewMs = opts.maxSkewMs != null ? opts.maxSkewMs : 2500;
  const maxPctPoints = opts.maxPctPoints != null ? opts.maxPctPoints : 3.0; // percentage points

  if (!ui || !ui.ok || ui.currentMs < 0) {
    return {
      ok: false,
      reason: 'ui_timeline_unreadable',
      detail:
        `${tag}: could not read Plex Web player clock/scrubber. ` +
        `source=${ui && ui.source} raw=${ui && ui.raw} tried=${(ui && ui.tried || []).slice(0, 8).join(',')}`,
    };
  }
  if (!daemon || daemon.time < 0) {
    return {
      ok: false,
      reason: 'daemon_timeline_unreadable',
      detail: `${tag}: daemon timeline time missing (state=${daemon && daemon.state})`,
    };
  }

  const skew = Math.abs(ui.currentMs - daemon.time);
  const dDur = daemon.duration > 0 ? daemon.duration : ui.durationMs;
  const uiPct = ui.durationMs > 0 ? (100 * ui.currentMs) / ui.durationMs : ui.pct != null ? 100 * ui.pct : null;
  const dPct = dDur > 0 ? (100 * daemon.time) / dDur : null;
  let pctDelta = null;
  if (uiPct != null && dPct != null) pctDelta = Math.abs(uiPct - dPct);

  // Pre-registered style log fields (caller prints).
  const metrics = {
    ui_ms: ui.currentMs,
    ui_dur_ms: ui.durationMs,
    ui_pct: uiPct,
    daemon_ms: daemon.time,
    daemon_dur_ms: daemon.duration,
    daemon_pct: dPct,
    skew_ms: skew,
    pct_delta: pctDelta,
    ui_source: ui.source,
    ui_raw: ui.raw,
    daemon_state: daemon.state,
  };

  if (skew > maxSkewMs) {
    return {
      ok: false,
      reason: 'ui_daemon_timeline_skew',
      detail:
        `${tag}: UI clock vs daemon skew_ms=${skew} > max=${maxSkewMs} ` +
        `(ui=${ui.currentMs}ms daemon=${daemon.time}ms state=${daemon.state} raw=${JSON.stringify(ui.raw)})`,
      metrics,
    };
  }
  if (pctDelta != null && pctDelta > maxPctPoints) {
    return {
      ok: false,
      reason: 'ui_daemon_timeline_pct_skew',
      detail:
        `${tag}: scrubber pct delta=${pctDelta.toFixed(2)}pp > max=${maxPctPoints} ` +
        `(ui_pct=${uiPct && uiPct.toFixed(2)} daemon_pct=${dPct && dPct.toFixed(2)})`,
      metrics,
    };
  }

  return { ok: true, metrics };
}

module.exports = {
  parseClockToMs,
  parseClockPair,
  readUiPlayerTimeline,
  assertUiDaemonTimeline,
};
