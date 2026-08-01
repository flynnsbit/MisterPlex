'use strict';

/**
 * discover_real.js — find a genuine (non-fixture) library title on LOCAL PMS.
 *
 * Never silently returns a MiSTerPlex Tests avsync fixture. Empty library →
 * explicit failure for the caller (not skip-as-pass).
 */

const http = require('http');
const https = require('https');

/**
 * Lab fixtures (burned-in counter / flash / soak). Title+path only —
 * never reject an entire library section: Contract-3 real titles live in
 * "MiSTerPlex Tests" alongside fixtures (parent PMS layout).
 */
const FIXTURE_TITLE_RE =
  /misterplex\s*(test|soak)\b|gen_avsync|trek24|ntsc2397|plex24|testsrc|avsync\s*blip|disc\s*nyquist/i;
const FIXTURE_SECTION_RE = /^misterplex\s*tests$/i; // informational only — not a reject
const FIXTURE_PATH_RE =
  /gen_avsync|avsync_blip|misterplex\s*test\b|misterplex\s*soak\b|disc\s*nyquist/i;

/**
 * Instrument glass (OCR/AVSync/AudioID) — useful for counter loss, NOT P7
 * "one real title on viewed pixels". Still non-fixture for other real arms.
 */
const INSTRUMENT_GLASS_RE =
  /ocrproof|avsync\s*glass|audioid\s*glass|glass\s*ledger|glass\s*ocr/i;

/**
 * w-asset480 Contract 3 — preferred P7 sources (path/title fingerprint).
 * ratingKeys are PMS-local and must be discovered, never hard-coded as CI truth.
 *   FullBleed 624x480 1200s · Real BBB GlassAV ladder · bare Real BBB
 */
const CONTRACT3_RE =
  /fullbleed|full-bleed|bank480\s*fullbleed|real\s*bbb|big\s*buck\s*bunny|glassav|glassid/i;
const CONTRACT3_FULLBLEED_RE = /fullbleed|full-bleed|bank480\s*fullbleed/i;
const CONTRACT3_BBB_RE = /real\s*bbb|big\s*buck\s*bunny|glassav|glassid/i;

/** Coded-bank sizes used by lab fixtures / DECODE tiers — NOT general-case geometry. */
const BANK_GEOMS = new Set(['320x240', '624x480']);
function geomKey(w, h) {
  const wi = parseInt(w, 10) || 0;
  const hi = parseInt(h, 10) || 0;
  if (!wi || !hi) return '';
  return `${wi}x${hi}`;
}

function isBankGeometry(w, h) {
  return BANK_GEOMS.has(geomKey(w, h));
}

function allowBankGeometry() {
  return /^(1|true|yes|on)$/i.test(String(process.env.E2E_REAL_ALLOW_BANK_GEOM || ''));
}

function httpGet(url, headers = {}, timeoutMs = 12000) {
  return new Promise((resolve) => {
    const lib = url.startsWith('https') ? https : http;
    const req = lib.get(url, { headers, timeout: timeoutMs, rejectUnauthorized: false }, (res) => {
      let body = '';
      res.on('data', (d) => {
        body += d;
      });
      res.on('end', () => resolve({ status: res.statusCode || 0, body }));
    });
    req.on('error', () => resolve({ status: 0, body: '' }));
    req.on('timeout', () => {
      req.destroy();
      resolve({ status: 0, body: '' });
    });
  });
}

function metaBlob(m) {
  const title = String(m.title || '');
  const file = String((((m.Media || [])[0] || {}).Part || [])[0]?.file || m.file || '');
  return { title, file, blob: `${title} ${file}` };
}

/** w-asset480 Contract 3 real content (FullBleed / Real BBB). */
function isContract3Meta(m) {
  const { blob } = metaBlob(m);
  return CONTRACT3_RE.test(blob);
}

function isInstrumentGlassMeta(m) {
  const { blob } = metaBlob(m);
  if (isContract3Meta(m)) return false; // Real BBB GlassAV is Contract 3, not instrument
  return INSTRUMENT_GLASS_RE.test(blob);
}

/**
 * True for synthetic Test/Soak/flash fixtures only.
 * sectionTitle is logged by callers but MUST NOT reject Contract-3 rows in
 * "MiSTerPlex Tests" — that section holds both fixtures and real BBB/FullBleed.
 */
function isFixtureMeta(m, sectionTitle) {
  void sectionTitle;
  if (isContract3Meta(m)) return false;
  const { title, file } = metaBlob(m);
  if (FIXTURE_TITLE_RE.test(title)) return true;
  if (FIXTURE_PATH_RE.test(file)) return true;
  return false;
}

/** P7-eligible: Contract 3 preferred; never synthetic fixture; instrument glass out. */
function isP7EligibleMeta(m, sectionTitle) {
  if (isFixtureMeta(m, sectionTitle)) return false;
  if (isInstrumentGlassMeta(m)) return false;
  return isContract3Meta(m);
}
function mediaInfo(m) {
  const media = (m.Media || [])[0] || {};
  const part = (media.Part || [])[0] || {};
  const stream =
    (part.Stream || media.Stream || []).find(
      (s) => String(s.streamType) === '1' || s.streamType === 1
    ) || {};
  const w = parseInt(media.width || stream.width || 0, 10) || 0;
  const h = parseInt(media.height || stream.height || 0, 10) || 0;
  return {
    width: w,
    height: h,
    videoCodec: String(media.videoCodec || stream.codec || ''),
    videoProfile: String(media.videoProfile || stream.profile || ''),
    videoResolution: String(media.videoResolution || ''),
    bitrate: parseInt(media.bitrate || part.bitrate || 0, 10) || 0,
    container: String(media.container || part.container || ''),
    frameRate: String(media.videoFrameRate || stream.frameRate || ''),
    durationMs: parseInt(m.duration || media.duration || 0, 10) || 0,
    file: String(part.file || ''),
    partKey: String(part.key || ''),
    audioCodec: String(media.audioCodec || ''),
  };
}

/**
 * Score candidates: prefer long duration, non-bank geometry, real detail (bitrate).
 * Bank sizes 320x240 / 624x480 are typical fixture coded sizes — deprioritize
 * unless Contract 3 (FullBleed / Real BBB at bank) which is P7-valid.
 */
function scoreCandidate(c, tierExpectDecode, opts = {}) {
  let s = 0;
  const dur = c.durationMs || 0;
  // Prefer soak-length material.
  if (dur >= 30 * 60 * 1000) s += 100;
  else if (dur >= 5 * 60 * 1000) s += 60;
  else if (dur >= 60 * 1000) s += 30;
  else if (dur >= 20 * 1000) s += 10;
  else s -= 20;

  const w = c.width || 0;
  const h = c.height || 0;
  if (w >= 1280 || h >= 720) s += 40;
  else if (w >= 720 || h >= 480) s += 25;
  else if (w > 0 && h > 0) s += 5;

  const bank = String(tierExpectDecode || '').toLowerCase();
  const contract3 = !!(c.contract3 || opts.contract3);
  if (!contract3) {
    if (bank && w && h && `${w}x${h}` === bank) s -= 50;
    if (isBankGeometry(w, h)) s -= 80;
  }

  if (c.bitrate >= 2000) s += 20;
  else if (c.bitrate >= 500) s += 10;

  if (/h264|avc/i.test(c.videoCodec)) s += 5;

  // Contract 3 preference (w-asset480). P7 wants REAL + LONG by default;
  // short 90s ladder clips lose to ≥5–20 min BBB/FullBleed. Use E2E_P7_ARM=nonbank
  // when parent wants 1440x1080 / 720x480 scale-path stress over soak length.
  if (contract3) {
    s += 200;
    const blob = `${c.title || ''} ${c.file || ''}`.toLowerCase();
    if (CONTRACT3_FULLBLEED_RE.test(blob)) s += 80;
    if (CONTRACT3_BBB_RE.test(blob)) s += 100; // real picture content > lab FullBleed pattern
    // Long title bonuses (rd-review P7: not a 30s flash fixture).
    if (dur >= 15 * 60 * 1000) s += 120; // ≥15 min
    else if (dur >= 5 * 60 * 1000) s += 90; // ≥5 min
    else if (dur >= 3 * 60 * 1000) s += 40;
    else if (dur > 0 && dur < 120 * 1000) s -= 40; // short ladder (90s) deprioritized
    // Non-bank forces crop/pad/scale — soft preference unless arm=nonbank (caller).
    if (!isBankGeometry(w, h)) s += 35;
    if (w >= 1280 || h >= 720) s += 45; // true full-frame source
  }
  return s;
}/**
 * Discover best real title.
 * opts.p7Mode / E2E_P7: prefer w-asset480 Contract 3 (FullBleed / Real BBB);
 *   bank geometry allowed for those titles; instrument glass rejected.
 * @returns {{ ok:true, item } | { ok:false, reason, detail, scanned }}
 */
async function discoverRealTitle(cfg, opts = {}) {
  const headers = {
    'X-Plex-Token': cfg.token,
    Accept: 'application/json',
  };
  const tierDecode = (opts.expectDecode || cfg.tiers?.[0]?.expectDecode || '').toLowerCase();
  const minDurationMs = parseInt(opts.minDurationMs || process.env.E2E_REAL_MIN_DURATION_MS || '20000', 10);
  const preferSection = process.env.E2E_REAL_LIBRARY_NAME || cfg.libraryName || '';
  const p7Mode =
    opts.p7Mode !== undefined
      ? !!opts.p7Mode
      : /^(1|true|yes|on)$/i.test(String(process.env.E2E_P7 || process.env.E2E_P7_REAL_TITLE || ''));
  // Prefer Contract 3 only (default on for P7). Set E2E_P7_CONTRACT3_ONLY=0 to allow any non-fixture.
  const contract3Only =
    opts.contract3Only !== undefined
      ? !!opts.contract3Only
      : p7Mode && !/^(0|false|no|off)$/i.test(String(process.env.E2E_P7_CONTRACT3_ONLY || '1'));
  // P7 Contract 3 may be bank-sized (FullBleed/BBB 624x480). Non-P7 still defaults non-bank.
  const requireNonBank =
    opts.requireNonBank !== undefined
      ? !!opts.requireNonBank
      : p7Mode
        ? false
        : !allowBankGeometry();
  const preferArm = String(opts.preferArm || process.env.E2E_P7_ARM || '')
    .trim()
    .toLowerCase(); // fullbleed | bbb | nonbank | ''

  const sec = await httpGet(`${cfg.plexBase}/library/sections`, headers);
  if (sec.status !== 200) {
    return {
      ok: false,
      reason: 'pms_sections_unreachable',
      detail: `HTTP ${sec.status} from /library/sections`,
      scanned: 0,
    };
  }
  let sections;
  try {
    sections = JSON.parse(sec.body);
  } catch (_) {
    return { ok: false, reason: 'pms_sections_bad_json', detail: '', scanned: 0 };
  }
  const dirs = sections.MediaContainer?.Directory || [];
  const candidates = [];
  const rejectedFixtures = [];
  const rejectedInstrument = [];
  const rejectedBankGeom = [];
  const rejectedShort = [];
  const rejectedNotContract3 = [];
  let scanned = 0;

  for (const d of dirs) {
    const secTitle = d.title || '';
    const secKey = d.key;
    if (preferSection && !FIXTURE_SECTION_RE.test(preferSection)) {
      if (!String(secTitle).toLowerCase().includes(String(preferSection).toLowerCase())) {
        // Still scan all sections — preferSection is a soft hint only.
      }
    }
    const all = await httpGet(`${cfg.plexBase}/library/sections/${secKey}/all`, headers);
    if (all.status !== 200) continue;
    let items;
    try {
      items = JSON.parse(all.body);
    } catch (_) {
      continue;
    }
    const metas = items.MediaContainer?.Metadata || [];
    for (const m of metas) {
      scanned++;
      if (isFixtureMeta(m, secTitle)) {
        rejectedFixtures.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
          section: secTitle,
        });
        continue;
      }
      if (p7Mode && isInstrumentGlassMeta(m)) {
        rejectedInstrument.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
        });
        continue;
      }
      if (contract3Only && !isContract3Meta(m)) {
        rejectedNotContract3.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
        });
        continue;
      }
      const mi = mediaInfo(m);
      if (mi.durationMs > 0 && mi.durationMs < minDurationMs) {
        rejectedShort.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
          durationMs: mi.durationMs,
        });
        continue;
      }
      const contract3 = isContract3Meta(m);
      // Non-Contract3 bank geom still rejected when requireNonBank.
      if (requireNonBank && !contract3 && isBankGeometry(mi.width, mi.height)) {
        rejectedBankGeom.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
          library_media: geomKey(mi.width, mi.height),
        });
        continue;
      }
      if (requireNonBank && !contract3 && (!mi.width || !mi.height)) {
        rejectedBankGeom.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
          library_media: 'unknown',
          note: 'missing_library_media_dims',
        });
        continue;
      }
      if (preferArm === 'fullbleed' && !CONTRACT3_FULLBLEED_RE.test(`${m.title || ''} ${mi.file || ''}`)) {
        continue;
      }
      if (preferArm === 'bbb' && !CONTRACT3_BBB_RE.test(`${m.title || ''} ${mi.file || ''}`)) {
        continue;
      }
      if (
        preferArm === 'nonbank' &&
        isBankGeometry(mi.width, mi.height)
      ) {
        continue;
      }
      const item = {
        ratingKey: String(m.ratingKey || ''),
        title: String(m.title || ''),
        sectionKey: String(secKey),
        sectionTitle: secTitle,
        librarySectionID: m.librarySectionID,
        contract3,
        contract3_kind: contract3
          ? CONTRACT3_FULLBLEED_RE.test(`${m.title || ''} ${mi.file || ''}`)
            ? 'fullbleed'
            : 'bbb'
          : '',
        ...mi,
      };
      item.score = scoreCandidate(item, tierDecode, { contract3 });
      candidates.push(item);
    }
  }

  candidates.sort((a, b) => b.score - a.score || b.durationMs - a.durationMs);

  if (!candidates.length) {
    const bankNote = requireNonBank
      ? ` Also rejected ${rejectedBankGeom.length} non-fixture item(s) with bank-sized ` +
        `library_media in {320x240,624x480} (or unknown dims). For P7 bank-sized FullBleed/BBB ` +
        `use E2E_P7=1 (Contract 3). For non-bank stress pin E2E_P7_ARM=nonbank or rk 29/31/32/28.`
      : '';
    const c3note = contract3Only
      ? ` Contract3-only filter active (w-asset480 FullBleed / Real BBB / GlassAV). ` +
        `Rejected ${rejectedNotContract3.length} non-Contract3. Scan section 2 for ` +
        `"Bank480 FullBleed" or "Real BBB GlassAV" — do not source new assets in this lane.`
      : '';
    const reason =
      contract3Only && rejectedNotContract3.length
        ? 'p7_contract3_not_in_library'
        : rejectedBankGeom.length > 0 && rejectedFixtures.length + rejectedShort.length < scanned
          ? 'real_content_no_nonbank_geometry'
          : 'real_content_library_empty';
    return {
      ok: false,
      reason,
      detail:
        `Scanned ${scanned} items across ${dirs.length} sections; ` +
        `${rejectedFixtures.length} rejected as lab fixtures` +
        (rejectedInstrument.length ? `; ${rejectedInstrument.length} instrument glass` : '') +
        (rejectedShort.length ? `; ${rejectedShort.length} too short (<${minDurationMs}ms)` : '') +
        `. No suitable title met rules (min_duration_ms=${minDurationMs}` +
        (p7Mode ? ', p7=1' : '') +
        (contract3Only ? ', contract3_only=1' : '') +
        (requireNonBank ? ', require_nonbank=1' : '') +
        `). ` +
        `Coordinate w-asset480 Contract 3; LOCAL PMS only — never SHIELD/remote. ` +
        `Fixture fallback DISABLED.` +
        c3note +
        bankNote,
      scanned,
      rejectedFixtures: rejectedFixtures.slice(0, 12),
      rejectedInstrument: rejectedInstrument.slice(0, 8),
      rejectedBankGeom: rejectedBankGeom.slice(0, 12),
      rejectedNotContract3: rejectedNotContract3.slice(0, 8),
      sections: dirs.map((d) => ({ key: d.key, title: d.title })),
    };
  }

  return {
    ok: true,
    item: candidates[0],
    alternates: candidates.slice(1, 8),
    scanned,
    rejectedFixtures: rejectedFixtures.length,
    rejectedInstrument: rejectedInstrument.length,
    rejectedBankGeom: rejectedBankGeom.length,
    rejectedNotContract3: rejectedNotContract3.length,
    requireNonBank,
    p7Mode,
    contract3Only,
    preferArm: preferArm || '',
    source: 'discover_real_contract3',
  };
}

/**
 * P7 entry: Contract 3 discovery (FullBleed / Real BBB). ratingKey is measured
 * from PMS — never commit household topology; optional E2E_P7_RATING_KEY pins.
 */
async function discoverP7Title(cfg, opts = {}) {
  return discoverRealTitle(cfg, {
    ...opts,
    p7Mode: true,
    contract3Only: opts.contract3Only !== undefined ? opts.contract3Only : true,
    requireNonBank: false,
  });
}
/**
 * Build expected geometry chain for logs (PMS-side + tier). Delivery mode is
 * best-effort from daemon STREAM policy: H.264 library parts often direct-play.
 */
function geometryChain(item, tier) {
  const expectDecode = tier?.expectDecode || process.env.E2E_DAEMON_DECODE || 'unknown';
  const lib = item.width && item.height ? `${item.width}x${item.height}` : 'unknown';
  const isH264 = /h264|avc/i.test(item.videoCodec || '');
  // Product STREAM path prefers direct H.264 Part; otherwise PMS universal → tier.
  let expectedDelivery = expectDecode;
  let pathGuess = 'transcode_to_tier';
  if (isH264 && item.partKey) {
    pathGuess = 'prefer_direct_h264_part';
    // Direct play delivers library geometry into ARM scale-to-bank.
    expectedDelivery = lib;
  }
  return {
    requested_tier: tier?.name || process.env.E2E_TIER || '240p',
    expect_decode_bank: expectDecode,
    library_media: lib,
    library_codec: item.videoCodec || '?',
    library_profile: item.videoProfile || '?',
    library_container: item.container || '?',
    library_bitrate: item.bitrate || 0,
    library_duration_ms: item.durationMs || 0,
    expected_delivery: expectedDelivery,
    path_guess: pathGuess,
    arm_rescale_expected:
      lib !== 'unknown' && expectDecode !== 'unknown' && lib !== expectDecode ? '1' : '0',
  };
}

module.exports = {
  discoverRealTitle,
  discoverP7Title,
  geometryChain,
  isFixtureMeta,
  isContract3Meta,
  isInstrumentGlassMeta,
  isP7EligibleMeta,
  isBankGeometry,
  mediaInfo,
  FIXTURE_TITLE_RE,
  CONTRACT3_RE,
  BANK_GEOMS,
};
