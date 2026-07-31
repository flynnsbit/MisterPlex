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

function loadConfig() {
  const confPath = resolveConfPath();
  const conf = readConfFile(confPath);

  // Prefer env over conf. No default private PMS URL (private-data gate).
  const plexBase = (process.env.PLEX_BASE || conf.PLEX_BASE || '').replace(/\/$/, '');
  const token = process.env.PLEX_TOKEN || conf.PLEX_TOKEN || '';

  return {
    confPath: confPath || '(none)',
    plexBase,
    token,
    // Library / item — match lab "MiSTerPlex Tests" section titles (substring OK).
    libraryName: process.env.PLEX_LIBRARY_NAME || 'MiSTerPlex Tests',
    itemTitle: process.env.PLEX_ITEM_TITLE || 'MiSTerPlex Test 240p',
    // ratingKey override skips library search when set (e.g. 3).
    ratingKey: process.env.PLEX_RATING_KEY || '',
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
  loadConfig,
  daemonBase,
  redact,
};
