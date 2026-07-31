'use strict';

/**
 * Runtime config for Plex Web e2e. Tokens and PMS base URLs come from env or a
 * gitignored conf file — never hardcode private :32400 addresses or tokens
 * (tests/unit/test_no_private_data.sh).
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../..');

/** Lab decode tiers. Suite never edits device conf — parent applies these. */
const TIER_DEFS = {
  '240p': {
    name: '240p',
    ratingKey: '3',
    itemTitle: 'MiSTerPlex Test 240p',
    expectDecode: '320x240',
    confKeys: {
      DECODE: '320x240',
      DECODE_ALLOW_LAB_480P: '0',
      DDR_YUV_FORCE_SCALE: '0',
    },
    // Lab often already on 240p; missing probe is WARN unless forced.
    requireDaemonTierDefault: false,
  },
  '480p': {
    name: '480p',
    ratingKey: '6',
    itemTitle: 'MiSTerPlex Test 480p',
    expectDecode: '624x480',
    confKeys: {
      DECODE: '624x480',
      DECODE_ALLOW_LAB_480P: '1',
      DDR_YUV_FORCE_SCALE: '1',
    },
    // Mis-set conf silently tests wrong tier — require explicit parent probe.
    requireDaemonTierDefault: true,
  },
};

function readConfFile(confPath) {
  if (!confPath || !fs.existsSync(confPath)) return {};
  const vals = {};
  for (const line of fs.readFileSync(confPath, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const m = t.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (!m) continue;
    vals[m[1]] = m[2].trim().replace(/\r$/, '').replace(/^["']|["']$/g, '');
  }
  return vals;
}

function resolveConfPath() {
  if (process.env.MISTERPLEX_CONF) return process.env.MISTERPLEX_CONF;
  const candidates = [
    path.join(ROOT, 'assets', 'misterplex.conf'),
    path.join(os.homedir(), '.config', 'misterplex', 'misterplex.conf'),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return '';
}

function truthy(v, def = false) {
  if (v === undefined || v === null || v === '') return def;
  return /^(1|true|yes|on)$/i.test(String(v));
}

function normalizeDecode(s) {
  const m = String(s || '')
    .trim()
    .toLowerCase()
    .match(/(\d+)\s*[x×]\s*(\d+)/i);
  if (!m) return String(s || '').trim().toLowerCase();
  return `${m[1]}x${m[2]}`;
}

/**
 * Resolve which tier(s) this invocation runs.
 * E2E_TIER=240p|480p|all  (default 240p)
 * Explicit PLEX_RATING_KEY / PLEX_ITEM_TITLE still override per-tier defaults
 * when a single tier is selected.
 */
function resolveTiers(env = process.env) {
  const raw = String(env.E2E_TIER || env.PLEX_E2E_TIER || '240p')
    .trim()
    .toLowerCase();
  let names;
  if (raw === 'all' || raw === 'both') names = ['240p', '480p'];
  else if (raw === '480' || raw === '480p') names = ['480p'];
  else if (raw === '240' || raw === '240p' || raw === '') names = ['240p'];
  else if (TIER_DEFS[raw]) names = [raw];
  else {
    throw new Error(
      `Unknown E2E_TIER=${JSON.stringify(raw)} — use 240p, 480p, or all`
    );
  }

  const forceRequire = env.E2E_REQUIRE_DAEMON_TIER;
  const daemonDecode = normalizeDecode(env.E2E_DAEMON_DECODE || env.E2E_EXPECT_DECODE || '');

  return names.map((name) => {
    const def = TIER_DEFS[name];
    const single = names.length === 1;
    // Single-tier env overrides for library item selection.
    let ratingKey = def.ratingKey;
    let itemTitle = def.itemTitle;
    if (single) {
      if (env.PLEX_RATING_KEY)
        ratingKey = String(env.PLEX_RATING_KEY).replace(/^\/library\/metadata\//, '');
      if (env.PLEX_ITEM_TITLE) itemTitle = env.PLEX_ITEM_TITLE;
      if (env.PLEX_KEY) {
        const m = String(env.PLEX_KEY).match(/metadata\/(\d+)/);
        if (m) ratingKey = m[1];
      }
    }
    let requireDaemonTier = def.requireDaemonTierDefault;
    if (forceRequire !== undefined && forceRequire !== '') {
      requireDaemonTier = truthy(forceRequire, requireDaemonTier);
    }
    return {
      ...def,
      ratingKey: String(ratingKey),
      itemTitle,
      expectDecode: def.expectDecode,
      requireDaemonTier,
      // Parent-exported probe of daemon banner / conf after apply.
      // For multi-tier runs, E2E_DAEMON_DECODE_<TIER> wins (e.g. E2E_DAEMON_DECODE_480P).
      daemonDecodeReported: normalizeDecode(
        env[`E2E_DAEMON_DECODE_${name.toUpperCase()}`] ||
          (single ? daemonDecode : '') ||
          ''
      ),
    };
  });
}

function parentConfCommands(tier, misterHost) {
  const host = misterHost || 'MISTER_HOST';
  const confRemote = '/media/fat/misterplex/misterplex.conf';
  const keys = tier.confKeys || {};
  const setLines = Object.entries(keys)
    .map(([k, v]) => `${k}=${v}`)
    .join(' ');
  // Parent owns device — emit exact ops, never execute from suite.
  const apply =
    `# PARENT applies conf for tier=${tier.name} (suite does NOT ssh/edit device)\n` +
    `# On MiSTer (${host}), ensure ${confRemote} contains:\n` +
    Object.entries(keys)
      .map(([k, v]) => `#   ${k}=${v}`)
      .join('\n') +
    `\n# Example (parent-run):\n` +
    `#   ssh root@${host} 'grep -E "^(DECODE|DECODE_ALLOW_LAB_480P|DDR_YUV_FORCE_SCALE)=" ${confRemote} || true'\n` +
    `#   # then edit conf to: ${setLines}\n` +
    `#   ssh root@${host} 'systemctl restart misterplexd || /media/fat/misterplex/misterplexd &'\n` +
    `#   # probe banner / log for adopted decode, then export:\n` +
    `#   export E2E_DAEMON_DECODE=${tier.expectDecode}\n` +
    `#   export E2E_TIER=${tier.name}`;
  return {
    tier: tier.name,
    expectDecode: tier.expectDecode,
    confKeys: keys,
    confRemote,
    applyText: apply,
    probeExport: `E2E_DAEMON_DECODE=${tier.expectDecode} E2E_TIER=${tier.name}`,
  };
}

function loadConfig() {
  const confPath = resolveConfPath();
  const conf = readConfFile(confPath);

  // Prefer env over conf. No default private PMS URL (private-data gate).
  const plexBase = (process.env.PLEX_BASE || conf.PLEX_BASE || '').replace(/\/$/, '');
  const token = process.env.PLEX_TOKEN || conf.PLEX_TOKEN || '';

  let tiers;
  let tierResolveError = '';
  try {
    tiers = resolveTiers(process.env);
  } catch (e) {
    tiers = [];
    tierResolveError = e.message;
  }

  // Back-compat defaults from first tier when present.
  const t0 = tiers && tiers[0];

  return {
    confPath: confPath || '(none)',
    plexBase,
    token,
    tiers: tiers || [],
    tierResolveError: tierResolveError || '',
    // Library / item — match lab "MiSTerPlex Tests" section titles (substring OK).
    libraryName: process.env.PLEX_LIBRARY_NAME || 'MiSTerPlex Tests',
    itemTitle: process.env.PLEX_ITEM_TITLE || (t0 && t0.itemTitle) || 'MiSTerPlex Test 240p',
    // ratingKey override skips library search when set (e.g. 3).
    ratingKey: process.env.PLEX_RATING_KEY || (t0 && t0.ratingKey) || '',
    // Allow PLEX_KEY=/library/metadata/3 form
    plexKey: process.env.PLEX_KEY || conf.PLEX_KEY || '',
    castName: process.env.CAST_TARGET_NAME || 'MiSTerPlex',
    playerId: process.env.CAST_PLAYER_ID || 'misterplex-dev',
    // Plex Home profile name (Select User). Empty → first listed profile.
    webUser: process.env.PLEX_WEB_USER || conf.PLEX_WEB_USER || '',
    // MiSTer companion (documented lab default host; not a PMS :32400).
    misterHost: process.env.MISTER_HOST || '192.168.1.183',
    misterPort: parseInt(process.env.MISTER_PORT || '3005', 10),
    headless: process.env.PW_HEADED !== '1',
    timeoutMs: parseInt(process.env.PW_TIMEOUT_MS || '45000', 10),
    playWaitSec: parseInt(process.env.PW_PLAY_WAIT_SEC || '20', 10),
    outDir: process.env.E2E_OUT || path.join(ROOT, 'build', 'e2e-artifacts'),
    // Optional: pin a local Chrome for Testing binary when playwright install
    // cannot download (lab cache / offline). Env wins over auto-detect.
    chromiumPath:
      process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ||
      process.env.PW_CHROMIUM_PATH ||
      '',
    // Optional override for companion-server host assert (comma-separated).
    // Default: hostname of PLEX_BASE (+ loopback unless ALLOW_LOOPBACK_COMPANION=0).
    expectCompanionHost: process.env.EXPECT_COMPANION_HOST || '',
    // Transition scenarios (pause/resume, seek, stop+recast, play→idle→play).
    // Default ON — set E2E_TRANSITIONS=0 to skip (still not a pass of transitions).
    transitions: truthy(process.env.E2E_TRANSITIONS, true),
    // Optional HDMI motion gate (parent-owned grabber). Default OFF.
    // When on: suite holds playback, prints parent capture+score commands, and
    // if E2E_HDMI_CAPTURE_DIR already has PNGs, runs tools/hdmi_motion_instrument.py
    // (never opens /dev/video0 itself). Instrument rc=77 → hard FAIL.
    hdmiMotion: truthy(process.env.E2E_HDMI_MOTION || conf.E2E_HDMI_MOTION || '0'),
    hdmiCaptureDir:
      process.env.E2E_HDMI_CAPTURE_DIR ||
      conf.E2E_HDMI_CAPTURE_DIR ||
      path.join(ROOT, 'build', 'e2e-hdmi-capture'),
    hdmiHoldSec: parseInt(process.env.E2E_HDMI_HOLD_SEC || conf.E2E_HDMI_HOLD_SEC || '20', 10),
    hdmiWarmupSkip: parseInt(process.env.E2E_HDMI_WARMUP_SKIP || '15', 10),
    hdmiVideoDev: process.env.E2E_HDMI_VIDEO_DEV || '/dev/video0',
  };
}

function daemonBase(cfg) {
  return `http://${cfg.misterHost}:${cfg.misterPort}`;
}

function redact(s) {
  return String(s)
    .replace(/X-Plex-Token[=:][^&\s"']+/gi, 'X-Plex-Token=REDACTED')
    .replace(/myPlexAccessToken["']?\s*[:=]\s*["']?[^"'\s]+/gi, 'myPlexAccessToken=REDACTED');
}

module.exports = {
  ROOT,
  TIER_DEFS,
  loadConfig,
  daemonBase,
  redact,
  resolveTiers,
  parentConfCommands,
  normalizeDecode,
};
