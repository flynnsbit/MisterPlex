'use strict';

/**
 * discover_real.js — find a genuine (non-fixture) library title on LOCAL PMS.
 *
 * Never silently returns a MiSTerPlex Tests avsync fixture. Empty library →
 * explicit failure for the caller (not skip-as-pass).
 */

const http = require('http');
const https = require('https');

/** Titles / paths that are lab fixtures (burned-in counter, bank-sized). */
const FIXTURE_TITLE_RE =
  /misterplex\s*(test|soak)|gen_avsync|trek24|ntsc2397|plex24|testsrc|avsync\s*blip/i;
const FIXTURE_SECTION_RE = /^misterplex\s*tests$/i;
const FIXTURE_PATH_RE = /gen_avsync|avsync_blip|misterplex\s*test|misterplex\s*soak/i;

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

function isFixtureMeta(m, sectionTitle) {
  const title = String(m.title || '');
  const file = String((((m.Media || [])[0] || {}).Part || [])[0]?.file || '');
  if (FIXTURE_TITLE_RE.test(title)) return true;
  if (FIXTURE_PATH_RE.test(file)) return true;
  if (sectionTitle && FIXTURE_SECTION_RE.test(String(sectionTitle))) {
    // Entire "MiSTerPlex Tests" section is fixture lab content.
    return true;
  }
  return false;
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
 * Bank sizes 320x240 / 624x480 are typical fixture coded sizes — deprioritize.
 */
function scoreCandidate(c, tierExpectDecode) {
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

  // Deprioritize / exclude already-at-bank geometry (fixture-like / trivial scale).
  const bank = String(tierExpectDecode || '').toLowerCase();
  if (bank && w && h && `${w}x${h}` === bank) s -= 50;
  if (isBankGeometry(w, h)) s -= 80;

  if (c.bitrate >= 2000) s += 20;
  else if (c.bitrate >= 500) s += 10;

  if (/h264|avc/i.test(c.videoCodec)) s += 5;
  return s;
}

/**
 * Discover best real title.
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
  // P7: library_media must NOT be 320x240 or 624x480 unless explicitly allowed.
  // Bank-sized sources only prove "fixture at bank size", not general scale/AR paths.
  const requireNonBank =
    opts.requireNonBank !== undefined
      ? !!opts.requireNonBank
      : !allowBankGeometry();

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
  const rejectedBankGeom = [];
  const rejectedShort = [];
  let scanned = 0;

  for (const d of dirs) {
    const secTitle = d.title || '';
    const secKey = d.key;
    // Optional: only scan a named real library when set and not the fixture section.
    if (preferSection && !FIXTURE_SECTION_RE.test(preferSection)) {
      if (!String(secTitle).toLowerCase().includes(String(preferSection).toLowerCase())) {
        // Still scan other non-fixture sections so discovery is robust.
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
      const mi = mediaInfo(m);
      if (mi.durationMs > 0 && mi.durationMs < minDurationMs) {
        rejectedShort.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
          durationMs: mi.durationMs,
        });
        continue;
      }
      if (requireNonBank && isBankGeometry(mi.width, mi.height)) {
        rejectedBankGeom.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
          library_media: geomKey(mi.width, mi.height),
        });
        continue;
      }
      // Unknown geometry (0x0) is not proof of non-bank — reject for P7.
      if (requireNonBank && (!mi.width || !mi.height)) {
        rejectedBankGeom.push({
          ratingKey: String(m.ratingKey || ''),
          title: String(m.title || ''),
          library_media: 'unknown',
          note: 'missing_library_media_dims',
        });
        continue;
      }
      const item = {
        ratingKey: String(m.ratingKey || ''),
        title: String(m.title || ''),
        sectionKey: String(secKey),
        sectionTitle: secTitle,
        librarySectionID: m.librarySectionID,
        ...mi,
      };
      item.score = scoreCandidate(item, tierDecode);
      candidates.push(item);
    }
  }

  candidates.sort((a, b) => b.score - a.score || b.durationMs - a.durationMs);

  if (!candidates.length) {
    const bankNote = requireNonBank
      ? ` Also rejected ${rejectedBankGeom.length} non-fixture item(s) with bank-sized ` +
        `library_media in {320x240,624x480} (or unknown dims) — P7 requires real geometry ` +
        `(e.g. 1440x1080, 720x480, 640x480, 624x352). Override only with E2E_REAL_ALLOW_BANK_GEOM=1.`
      : '';
    const reason =
      rejectedBankGeom.length > 0 && rejectedFixtures.length + rejectedShort.length < scanned
        ? 'real_content_no_nonbank_geometry'
        : 'real_content_library_empty';
    return {
      ok: false,
      reason,
      detail:
        `Scanned ${scanned} items across ${dirs.length} sections; ` +
        `${rejectedFixtures.length} rejected as lab fixtures` +
        (rejectedShort.length ? `; ${rejectedShort.length} too short (<${minDurationMs}ms)` : '') +
        `. No suitable non-fixture title met P7 rules (min_duration_ms=${minDurationMs}` +
        (requireNonBank ? ', require_nonbank_library_media=1' : '') +
        `). ` +
        `Add a real movie/clip whose library_media is NOT 320x240/624x480 to a non-` +
        `"MiSTerPlex Tests" library on the LOCAL PMS (e.g. section "Other Videos") — ` +
        `do not point at SHIELD/remote. Fixture fallback is intentionally DISABLED.` +
        bankNote,
      scanned,
      rejectedFixtures: rejectedFixtures.slice(0, 12),
      rejectedBankGeom: rejectedBankGeom.slice(0, 12),
      sections: dirs.map((d) => ({ key: d.key, title: d.title })),
    };
  }

  return {
    ok: true,
    item: candidates[0],
    alternates: candidates.slice(1, 6),
    scanned,
    rejectedFixtures: rejectedFixtures.length,
    rejectedBankGeom: rejectedBankGeom.length,
    requireNonBank,
  };
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
  geometryChain,
  isFixtureMeta,
  isBankGeometry,
  mediaInfo,
  FIXTURE_TITLE_RE,
  BANK_GEOMS,
};
