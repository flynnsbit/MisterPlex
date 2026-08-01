'use strict';
/**
 * Glass-side frame-loss from burned-in counter sequences (w-instr / HDMI capture).
 *
 * Timeline advance alone is blind to display-side gaps. Parent ERROR 18/19
 * frame-loss % claims were WITHDRAWN (capture sampling margin); this gate still
 * flags large counter discontinuities when a capture is scored — not a claim
 * that 1.54% was measured.
 *
 * Input: ordered counter values n (source frame index burned into fixtures),
 * typically from tools/hdmi_motion_instrument.py JSON `reads[].n` (status=ok).
 *
 * Model (dense capture, same class as parent 24fps@30cap):
 *   delta 0  → plateau (capture faster than source) — OK
 *   delta 1  → adjacent advance — OK
 *   delta >1 → skipped source frames = delta-1
 *   delta <0 → non-monotonic (OCR/bank) — counted separately, not as loss%
 *
 * loss_pct = 100 * skips / source_span   where source_span = last_n - first_n
 * (threshold E2E_GLASS_MAX_LOSS_PCT is lab policy, not a withdrawn % claim).
 *
 * Every numeric field is measured from the counter sequence unless noted.
 */

/**
 * @param {number[]} nsRaw ordered counter samples (may include nulls — filtered)
 * @returns {{
 *   ok: boolean,
 *   n_samples: number,
 *   n_first: number|null,
 *   n_last: number|null,
 *   source_span: number,
 *   advances: number,
 *   skips: number,
 *   plateaus: number,
 *   backward: number,
 *   loss_pct: number|null,
 *   max_gap: number,
 *   value_kind: 'measured'|'insufficient',
 * }}
 */
function analyzeCounterGaps(nsRaw) {
  const ns = (nsRaw || [])
    .map((x) => (typeof x === 'number' ? x : parseInt(String(x), 10)))
    .filter((n) => Number.isFinite(n) && n >= 0);

  const empty = {
    ok: false,
    n_samples: ns.length,
    n_first: null,
    n_last: null,
    source_span: 0,
    advances: 0,
    skips: 0,
    plateaus: 0,
    backward: 0,
    loss_pct: null,
    max_gap: 0,
    value_kind: 'insufficient',
  };
  if (ns.length < 3) return empty;

  let skips = 0;
  let advances = 0;
  let plateaus = 0;
  let backward = 0;
  let maxGap = 0;
  for (let i = 1; i < ns.length; i++) {
    const d = ns[i] - ns[i - 1];
    if (d === 0) {
      plateaus++;
      continue;
    }
    if (d < 0) {
      backward++;
      continue;
    }
    // d >= 1
    advances += d;
    if (d > 1) {
      const gap = d - 1;
      skips += gap;
      if (gap > maxGap) maxGap = gap;
    }
  }

  const nFirst = ns[0];
  const nLast = ns[ns.length - 1];
  const sourceSpan = Math.max(0, nLast - nFirst);
  let lossPct = null;
  if (sourceSpan > 0) {
    lossPct = (100 * skips) / sourceSpan;
  }

  return {
    ok: true,
    n_samples: ns.length,
    n_first: nFirst,
    n_last: nLast,
    source_span: sourceSpan,
    advances,
    skips,
    plateaus,
    backward,
    loss_pct: lossPct,
    max_gap: maxGap,
    value_kind: 'measured',
  };
}

/**
 * Parse instrument --json stdout/stderr blob → ordered n list.
 * @param {string} text
 * @returns {number[]}
 */
function nsFromInstrumentJson(text) {
  const s = String(text || '');
  // Prefer last JSON object in output (instrument may print human lines first).
  let obj = null;
  const lines = s.split(/\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const t = lines[i].trim();
    if (!t.startsWith('{')) continue;
    try {
      obj = JSON.parse(t);
      break;
    } catch (_) {
      /* try multi-line */
    }
  }
  if (!obj) {
    // Whole blob
    const m = s.match(/\{[\s\S]*"verdict"[\s\S]*\}/);
    if (m) {
      try {
        obj = JSON.parse(m[0]);
      } catch (_) {
        obj = null;
      }
    }
  }
  if (!obj) return [];

  if (Array.isArray(obj.ns_head) && Array.isArray(obj.ns_tail) && obj.n_min != null) {
    // Prefer full reads when present
  }
  const ns = [];
  if (Array.isArray(obj.reads)) {
    for (const r of obj.reads) {
      if (!r) continue;
      if (r.status && r.status !== 'ok') continue;
      if (r.n == null) continue;
      const n = typeof r.n === 'number' ? r.n : parseInt(String(r.n), 10);
      if (Number.isFinite(n)) ns.push(n);
    }
  }
  return ns;
}

/**
 * Gate: fail if measured loss_pct exceeds maxLossPct.
 * @param {object} gap from analyzeCounterGaps
 * @param {number} maxLossPct
 * @param {string} tag
 */
function assertGlassLoss(gap, maxLossPct, tag) {
  const maxPct = Number.isFinite(maxLossPct) ? maxLossPct : 1.0;
  if (!gap || !gap.ok || gap.loss_pct == null) {
    return {
      ok: false,
      reason: 'glass_counter_unscored',
      detail:
        `${tag}: cannot measure glass frame loss (need ≥3 monotonic counter samples). ` +
        `n_samples=${gap && gap.n_samples} — soft-skip is NOT a glass PASS.`,
      gap,
    };
  }
  if (gap.backward > gap.n_samples / 4) {
    return {
      ok: false,
      reason: 'glass_counter_non_monotonic',
      detail:
        `${tag}: counter sequence too non-monotonic (backward=${gap.backward}/` +
        `${gap.n_samples}) — refuse to score loss% (OCR/bank noise).`,
      gap,
    };
  }
  if (gap.loss_pct > maxPct) {
    return {
      ok: false,
      reason: 'glass_frame_loss',
      detail:
        `${tag}: measured display-side frame loss_pct=${gap.loss_pct.toFixed(3)} ` +
        `> max=${maxPct} (skips=${gap.skips} source_span=${gap.source_span} ` +
        `n=${gap.n_first}->${gap.n_last} max_gap=${gap.max_gap} value_kind=measured). ` +
        `Daemon drops/presents can be clean while glass skips — timeline advance is insufficient.`,
      gap,
    };
  }
  return {
    ok: true,
    reason: 'glass_loss_ok',
    detail:
      `${tag}: glass_loss_pct=${gap.loss_pct.toFixed(3)}<=${maxPct} ` +
      `skips=${gap.skips} span=${gap.source_span} samples=${gap.n_samples}`,
    gap,
  };
}

module.exports = {
  analyzeCounterGaps,
  nsFromInstrumentJson,
  assertGlassLoss,
};
