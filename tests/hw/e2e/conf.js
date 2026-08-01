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
    // Parent bind: cast by ratingKey only. rk=1 = 240p soak (not title match).
    ratingKey: '1',
    itemTitle: '(from metadata rk — title not used for selection)',
    expectDecode: '320x240',
    confKeys: {
      DECODE: '320x240',
      DECODE_ALLOW_LAB_480P: '0',
      DDR_YUV_FORCE_SCALE: '0',
    },
    requireDaemonTierDefault: false,
    // Synthetic avsync fixtures carry TREK24 / NTSC2397 burned-in counters.
    syntheticDefault: true,
  },
  '480p': {
    name: '480p',
    // Default soak rk=8; parent full-bleed rk=27 / BBB rk=30 via PLEX_RATING_KEY.
    //   E2E_480P_ARM=soak|fullbleed|bbb  or  PLEX_RATING_KEY=8|27|30
    ratingKey: '8',
    itemTitle: '(from metadata rk — title not used for selection)',
    expectDecode: '624x480',
    confKeys: {
      DECODE: '624x480',
      DECODE_ALLOW_LAB_480P: '1',
      DDR_YUV_FORCE_SCALE: '1',
    },
    requireDaemonTierDefault: true,
    syntheticDefault: true,
  },
};

/** 480p content arm: test(rk6) vs soak(rk8). */
function resolve480pArm(env = process.env) {
  const arm = String(env.E2E_480P_ARM || env.E2E_480P_RK || '')
    .trim()
    .toLowerCase();
  if (arm === '27' || arm === 'fullbleed' || arm === 'full-bleed' || arm === 'vres') {
    return {
      ratingKey: '27',
      itemTitle: '(metadata rk=27)',
      arm: 'fullbleed',
    };
  }
  if (arm === '30' || arm === 'bbb') {
    return {
      ratingKey: '30',
      itemTitle: '(metadata rk=30)',
      arm: 'bbb',
    };
  }
  if (arm === '6' || arm === 'test' || arm === 'short') {
    return {
      ratingKey: '6',
      itemTitle: '(metadata rk=6)',
      arm: 'test',
    };
  }
  // default soak rk=8
  return {
    ratingKey: '8',
    itemTitle: '(metadata rk=8)',
    arm: 'soak',
  };
}

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
  const contentMode = String(env.E2E_CONTENT || env.E2E_CONTENT_MODE || 'synthetic')
    .trim()
    .toLowerCase();
  const isReal = contentMode === 'real' || contentMode === 'library';

  return names.map((name) => {
    const def = TIER_DEFS[name];
    const single = names.length === 1;
    let ratingKey = def.ratingKey;
    let itemTitle = def.itemTitle;
    let contentArm = name === '480p' ? 'test' : name === '240p' ? 'test' : '';
    if (name === '480p' && !isReal) {
      const a = resolve480pArm(env);
      ratingKey = a.ratingKey;
      itemTitle = a.itemTitle;
      contentArm = a.arm;
    }
    if (single || isReal) {
      if (env.PLEX_RATING_KEY)
        ratingKey = String(env.PLEX_RATING_KEY).replace(/^\/library\/metadata\//, '');
      if (env.PLEX_ITEM_TITLE) itemTitle = env.PLEX_ITEM_TITLE;
      if (env.PLEX_KEY) {
        const m = String(env.PLEX_KEY).match(/metadata\/(\d+)/);
        if (m) ratingKey = m[1];
      }
    }
    // Real content: do not silently fall back to synthetic RK3/RK6 defaults
    // unless parent still wants them — require explicit key/title when real.
    if (isReal && single) {
      if (!env.PLEX_RATING_KEY && !env.PLEX_KEY && !env.PLEX_ITEM_TITLE) {
        // Keep tier defaults but mark that parent should override.
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
      contentArm,
      expectDecode: def.expectDecode,
      requireDaemonTier,
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
  // Two install roots exist on lab devices — parent must resolve the LIVE conf
  // from /proc/<pid>/cmdline --conf, not assume /media/fat/misterplex/.
  const confRemote = '(LIVE conf from: tr "\\0" " " </proc/$(pidof misterplexd)/cmdline | sed -n "s/.*--conf[ =]\\([^ ]*\\).*/\\1/p")';
  const keys = tier.confKeys || {};
  const setLines = Object.entries(keys)
    .map(([k, v]) => `${k}=${v}`)
    .join(' ');
  const apply =
    `# PARENT applies conf for tier=${tier.name} (suite does NOT ssh/edit device)\n` +
    `# CAUTION: device has TWO install roots / TWO conf files. Resolve LIVE conf:\n` +
    `#   # PID from GET :3005/player/telemetry pid= — NEVER pidof/cmdline (flock ERROR 14)\n` +
    `#   pid=$(curl -sS http://127.0.0.1:3005/player/telemetry | sed -n 's/.*pid=\\([0-9]*\\).*/\\1/p')\n` +
    `#   readlink -f /proc/$pid/exe\n` +
    `#   tr '\\0' ' ' </proc/$pid/cmdline; echo\n` +
    `# legacy (unsafe): pid=$(pidof misterplexd | awk '{print $1}')\n` +

    `#   tr '\\0' ' ' < /proc/$pid/cmdline; echo\n` +
    `#   conf=$(tr '\\0' ' ' < /proc/$pid/cmdline | sed -n 's/.*--conf[= ]\\([^ ]*\\).*/\\1/p')\n` +
    `#   echo LIVE_CONF=$conf\n` +
    `# Ensure LIVE conf contains:\n` +
    Object.entries(keys)
      .map(([k, v]) => `#   ${k}=${v}`)
      .join('\n') +
    `\n# Example edit target keys: ${setLines}\n` +
    `#   # restart via the live supervisor / binary — not a stale v1 bundle\n` +
    `#   export E2E_DAEMON_DECODE=${tier.expectDecode}\n` +
    `#   export E2E_LIVE_CONF=$conf   # optional, logged by suite\n` +
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

function resolveTokenFromEnv(conf = {}) {
  if (process.env.PLEX_TOKEN && String(process.env.PLEX_TOKEN).trim()) {
    return String(process.env.PLEX_TOKEN).trim();
  }
  if (conf.PLEX_TOKEN) return String(conf.PLEX_TOKEN).trim();
  const files = [
    process.env.PLEX_TOKEN_FILE,
    conf.PLEX_TOKEN_FILE,
    '/tmp/local_tok.txt',
    path.join(os.homedir(), '.config', 'misterplex', 'plex_token'),
  ].filter(Boolean);
  for (const f of files) {
    try {
      if (!fs.existsSync(f)) continue;
      const t = fs.readFileSync(f, 'utf8').replace(/\r?\n/g, '').trim();
      if (t.length >= 8) {
        process.env.PLEX_TOKEN_FILE = f;
        return t;
      }
    } catch (_) {
      /* next */
    }
  }
  return '';
}

function loadConfig() {
  // Optional lab env (gitignored) — applied before conf so env wins when set.
  try {
    const { applyLabEnvFiles } = require('./preflight_env');
    applyLabEnvFiles();
  } catch (_) {
    /* preflight optional at conf load */
  }

  const confPath = resolveConfPath();
  const conf = readConfFile(confPath);

  const plexBase = (process.env.PLEX_BASE || conf.PLEX_BASE || '').replace(/\/$/, '');
  const token = resolveTokenFromEnv(conf);

  let tiers;
  let tierResolveError = '';
  try {
    tiers = resolveTiers(process.env);
  } catch (e) {
    tiers = [];
    tierResolveError = e.message;
  }

  const t0 = tiers && tiers[0];
  const contentMode = String(process.env.E2E_CONTENT || process.env.E2E_CONTENT_MODE || 'synthetic')
    .trim()
    .toLowerCase();
  const isReal = contentMode === 'real' || contentMode === 'library';

  // Multi-cycle stress. Default 10 so intermittent transition flakes surface.
  // Set E2E_TRANSITION_CYCLES=1 for a fast smoke.
  let transitionCycles = parseInt(
    process.env.E2E_TRANSITION_CYCLES || conf.E2E_TRANSITION_CYCLES || '10',
    10
  );
  if (!Number.isFinite(transitionCycles) || transitionCycles < 1) transitionCycles = 10;
  if (transitionCycles > 100) transitionCycles = 100;
  // When N>1, continue remaining cycles after a failure so 1-in-N flakes are visible
  // and the planned cycle count is never silently shortened. Set 0 to abort on first fail.
  const continueOnFailDefault = transitionCycles > 1;
  const transitionContinueOnFail = truthy(
    process.env.E2E_TRANSITION_CONTINUE_ON_FAIL,
    continueOnFailDefault
  );

  // HDMI: parent-owned grabber. Per-cycle capture dirs when every-cycle is on.
  const hdmiMotion = truthy(process.env.E2E_HDMI_MOTION || conf.E2E_HDMI_MOTION || '0');
  const hdmiEveryCycle = truthy(
    process.env.E2E_HDMI_EVERY_CYCLE,
    hdmiMotion // default: when HDMI on, score each cycle
  );
  let hdmiHoldSec = parseInt(
    process.env.E2E_HDMI_HOLD_SEC || conf.E2E_HDMI_HOLD_SEC || '',
    10
  );
  if (!Number.isFinite(hdmiHoldSec)) {
    // Shorter default hold under multi-cycle so a 10-cycle run stays practical.
    hdmiHoldSec = transitionCycles > 1 && hdmiEveryCycle ? 8 : 20;
  }

  // Synthetic fixtures: instrument must return MOTION_OK.
  // Real titles: no burned-in counter — timeline + color/structure only.
  let hdmiAssertMode = String(process.env.E2E_HDMI_ASSERT || '').trim().toLowerCase();
  if (!hdmiAssertMode) {
    hdmiAssertMode = isReal ? 'color_structure' : 'motion';
  }

  // After transitions (or first play), hold one continuous session so parent can
  // run multiple HDMI/avsync captures WITHOUT stop/recast (session-latched A/V).
  // 0 = off. Parent multi-capture recipe uses ~360.
  let sessionHoldSec = parseInt(
    process.env.E2E_SESSION_HOLD_SEC || conf.E2E_SESSION_HOLD_SEC || '0',
    10
  );
  if (!Number.isFinite(sessionHoldSec) || sessionHoldSec < 0) sessionHoldSec = 0;
  if (sessionHoldSec > 7200) sessionHoldSec = 7200;

  // FPS labels — ERROR 17 class: never print a default as if measured.
  // Fixtures: RK8 soak is 24.000 (ffprobe-measured by parent); instrument default
  // used to hardcode 23.976. Prefer explicit env; else DEFAULT_ASSUMED 24.0 for
  // synthetic 480p soak, 24.0 for 240p lab fixtures unless overridden.
  const srcFpsEnv = process.env.E2E_HDMI_SOURCE_FPS;
  let hdmiSourceFps;
  let hdmiSourceFpsLabel;
  if (srcFpsEnv !== undefined && srcFpsEnv !== '') {
    hdmiSourceFps = parseFloat(srcFpsEnv);
    hdmiSourceFpsLabel = 'caller-supplied';
  } else {
    hdmiSourceFps = 24.0;
    hdmiSourceFpsLabel = 'DEFAULT_ASSUMED';
  }
  const capFpsEnv = process.env.E2E_HDMI_CAPTURE_FPS;
  let hdmiCaptureFps;
  let hdmiCaptureFpsLabel;
  if (capFpsEnv !== undefined && capFpsEnv !== '') {
    hdmiCaptureFps = parseFloat(capFpsEnv);
    hdmiCaptureFpsLabel = 'caller-supplied';
  } else {
    hdmiCaptureFps = 30.0;
    hdmiCaptureFpsLabel = 'DEFAULT_ASSUMED';
  }

  return {
    confPath: confPath || '(none)',
    plexBase,
    token,
    tiers: tiers || [],
    tierResolveError: tierResolveError || '',
    contentMode: isReal ? 'real' : 'synthetic',
    isRealContent: isReal,
    libraryName:
      process.env.PLEX_LIBRARY_NAME ||
      (isReal ? '' : 'MiSTerPlex Tests'),
    itemTitle:
      process.env.PLEX_ITEM_TITLE ||
      (t0 && t0.itemTitle) ||
      (isReal ? '' : 'MiSTerPlex Test 240p'),
    ratingKey: process.env.PLEX_RATING_KEY || (t0 && t0.ratingKey) || '',
    plexKey: process.env.PLEX_KEY || conf.PLEX_KEY || '',
    castName: process.env.CAST_TARGET_NAME || 'MiSTerPlex',
    playerId: process.env.CAST_PLAYER_ID || 'misterplex-dev',
    webUser: process.env.PLEX_WEB_USER || conf.PLEX_WEB_USER || '',
    misterHost: process.env.MISTER_HOST || conf.MISTER_HOST || '192.168.1.183',
    misterPort: parseInt(process.env.MISTER_PORT || conf.MISTER_PORT || '3005', 10),
    headless: process.env.PW_HEADED !== '1',
    timeoutMs: parseInt(process.env.PW_TIMEOUT_MS || '45000', 10),
    playWaitSec: parseInt(process.env.PW_PLAY_WAIT_SEC || '20', 10),
    outDir: process.env.E2E_OUT || path.join(ROOT, 'build', 'e2e-artifacts'),
    chromiumPath:
      process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ||
      process.env.PW_CHROMIUM_PATH ||
      '',
    expectCompanionHost: process.env.EXPECT_COMPANION_HOST || '',
    transitions: truthy(process.env.E2E_TRANSITIONS, true),
    transitionCycles,
    transitionContinueOnFail,
    // Overlay hold for parent HDMI (user low-res chrome bug / w-osd-hires).
    // E2E_OVERLAY_ONLY=1 → drive pause/seek chrome windows then stop (no full N-loop).
    overlayOnly: truthy(process.env.E2E_OVERLAY_ONLY, false),
    overlayHoldSec: (() => {
      const v = parseFloat(process.env.E2E_OVERLAY_HOLD_SEC || conf.E2E_OVERLAY_HOLD_SEC || '8');
      if (!Number.isFinite(v) || v < 1) return 8;
      if (v > 120) return 120;
      return v;
    })(),
    overlayRepeats: (() => {
      const v = parseInt(process.env.E2E_OVERLAY_REPEATS || '2', 10);
      if (!Number.isFinite(v) || v < 1) return 2;
      if (v > 20) return 20;
      return v;
    })(),
    // MiSTer OUTPUT resolution (chrome must match OUTPUT, not content). Defaults:
    // video_mode=8 → 1920x1080. Override for 640x480 / 800x600 / 240p labs.
    outputWidth: (() => {
      const v = parseInt(process.env.E2E_OUTPUT_W || conf.E2E_OUTPUT_W || '1920', 10);
      return Number.isFinite(v) && v > 0 ? v : 1920;
    })(),
    outputHeight: (() => {
      const v = parseInt(process.env.E2E_OUTPUT_H || conf.E2E_OUTPUT_H || '1080', 10);
      return Number.isFinite(v) && v > 0 ? v : 1080;
    })(),
    // Optional parent-exported live identity (from /proc cmdline — never assumed).
    liveConf: process.env.E2E_LIVE_CONF || '',
    liveDaemonId: process.env.E2E_LIVE_DAEMON_ID || process.env.E2E_DAEMON_ID || '',
    hdmiMotion,
    hdmiEveryCycle,
    hdmiAssertMode, // motion | color_structure
    hdmiCaptureDir:
      process.env.E2E_HDMI_CAPTURE_DIR ||
      conf.E2E_HDMI_CAPTURE_DIR ||
      path.join(ROOT, 'build', 'e2e-hdmi-capture'),
    hdmiHoldSec,
    hdmiWarmupSkip: parseInt(process.env.E2E_HDMI_WARMUP_SKIP || '15', 10),
    hdmiVideoDev: process.env.E2E_HDMI_VIDEO_DEV || '/dev/video0',
    hdmiSourceFps,
    hdmiSourceFpsLabel,
    hdmiCaptureFps,
    hdmiCaptureFpsLabel,
    sessionHoldSec,
    // Measured delivery (ffmpeg banner) — never assert request/library as delivered.
    // Real content / geom matrix default require=1; synthetic default 0.
    // P7: one real title E2E + capture window for parent viewed-pixels gate.
    p7Mode: truthy(process.env.E2E_P7 || process.env.E2E_P7_REAL_TITLE, false),
    p7HoldSec: (() => {
      const v = parseFloat(process.env.E2E_P7_HOLD_SEC || process.env.E2E_REAL_HOLD_SEC || '45');
      if (!Number.isFinite(v) || v < 5) return 45;
      if (v > 600) return 600;
      return v;
    })(),
    requireMeasuredDelivery: truthy(
      process.env.E2E_REQUIRE_MEASURED_DELIVERY,
      isReal ||
        truthy(process.env.E2E_REAL_GEOM_MATRIX, false) ||
        truthy(process.env.E2E_P7 || process.env.E2E_P7_REAL_TITLE, false)
    ),
    // session_epoch=process_epoch.stream_seq — spanning asserts need stable epoch.
    requireSessionEpoch: truthy(
      process.env.E2E_REQUIRE_SESSION_EPOCH,
      isReal ||
        truthy(process.env.E2E_REAL_GEOM_MATRIX, false) ||
        truthy(process.env.E2E_P7 || process.env.E2E_P7_REAL_TITLE, false)
    ),
    // Optional bank size to reject as measured identity on real-geom arms (e.g. 624x480).
    rejectMeasuredBankGeom: String(
      process.env.E2E_REJECT_MEASURED_BANK || process.env.E2E_EXPECT_DECODE || ''
    ).trim(),
    // Glass integrity (w-instr counter). Parent provides capture dir; suite never grabs.
    // E2E_REQUIRE_GLASS=1 → missing/unscored glass is FAIL (not timeline-only PASS).
    requireGlass: truthy(process.env.E2E_REQUIRE_GLASS, false),
    glassMaxLossPct: (() => {
      const v = parseFloat(process.env.E2E_GLASS_MAX_LOSS_PCT || '1.0');
      return Number.isFinite(v) ? v : 1.0;
    })(),
    // Pre-filled capture for offline glass score (parent pixel burst path).
    glassCaptureDir:
      process.env.E2E_GLASS_CAPTURE_DIR ||
      process.env.E2E_HDMI_SCORE_DIR ||
      '',
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
