'use strict';
/**
 * Self-diagnosing env preflight for cast-picker E2E.
 * Missing/malformed required inputs → loud FAIL with remediation (never soft-pass).
 * Does not print token values.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const https = require('https');

const EXIT_FAIL = 1;
const EXIT_UNVERIFIED = 2;
const EXIT_SKIP = 77;

function log(...a) {
  console.log(...a);
}

function loadDotEnvFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return {};
  const out = {};
  for (const line of fs.readFileSync(filePath, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const m = t.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m) continue;
    let v = m[2].trim().replace(/\r$/, '');
    if (
      (v.startsWith('"') && v.endsWith('"')) ||
      (v.startsWith("'") && v.endsWith("'"))
    ) {
      v = v.slice(1, -1);
    }
    out[m[1]] = v;
  }
  return out;
}

/** Apply gitignored lab env files into process.env (does not override existing). */
function applyLabEnvFiles() {
  const root = path.resolve(__dirname);
  const repoRoot = path.resolve(__dirname, '../../..');
  const candidates = [
    process.env.E2E_ENV_FILE,
    path.join(root, '.env.lab'),
    path.join(root, 'e2e.env'),
    path.join(os.homedir(), '.config', 'misterplex', 'e2e.env'),
    path.join(repoRoot, 'assets', 'e2e.env'),
  ].filter(Boolean);

  const loaded = [];
  for (const f of candidates) {
    if (!fs.existsSync(f)) continue;
    const vals = loadDotEnvFile(f);
    let n = 0;
    for (const [k, v] of Object.entries(vals)) {
      if (process.env[k] === undefined || process.env[k] === '') {
        process.env[k] = v;
        n++;
      }
    }
    loaded.push(`${f}(+${n})`);
  }
  return loaded;
}

function resolveToken() {
  if (process.env.PLEX_TOKEN && String(process.env.PLEX_TOKEN).trim()) {
    return {
      token: String(process.env.PLEX_TOKEN).trim(),
      source: 'env:PLEX_TOKEN',
    };
  }
  const files = [
    process.env.PLEX_TOKEN_FILE,
    '/tmp/local_tok.txt',
    path.join(os.homedir(), '.config', 'misterplex', 'plex_token'),
    path.join(os.homedir(), '.plex_token'),
  ].filter(Boolean);

  for (const f of files) {
    try {
      if (!fs.existsSync(f)) continue;
      const t = fs.readFileSync(f, 'utf8').replace(/\r?\n/g, '').trim();
      if (t.length >= 8) {
        process.env.PLEX_TOKEN = t;
        process.env.PLEX_TOKEN_FILE = f;
        return { token: t, source: `file:${f}` };
      }
    } catch (_) {
      /* next */
    }
  }
  return { token: '', source: '' };
}

function httpGet(url, headers = {}, timeoutMs = 8000) {
  return new Promise((resolve) => {
    try {
      const u = new URL(url);
      const lib = u.protocol === 'https:' ? https : http;
      const req = lib.get(
        url,
        { headers, timeout: timeoutMs },
        (res) => {
          let body = '';
          res.on('data', (d) => {
            body += d;
          });
          res.on('end', () =>
            resolve({ status: res.statusCode || 0, body })
          );
        }
      );
      req.on('error', () => resolve({ status: 0, body: '' }));
      req.on('timeout', () => {
        req.destroy();
        resolve({ status: 0, body: '' });
      });
    } catch (_) {
      resolve({ status: 0, body: '' });
    }
  });
}

/**
 * Loud preflight. Mutates process.env with resolved token/defaults.
 * @returns {{ ok: true, report: object } | never (process.exit)}
 */
async function runPreflight({ requirePms = true, requireDaemon = true } = {}) {
  const loaded = applyLabEnvFiles();
  const tok = resolveToken();

  // Sensible lab defaults (MISTER_HOST allowed by test_no_private_data).
  if (!process.env.MISTER_HOST) process.env.MISTER_HOST = '192.168.1.183';
  if (!process.env.MISTER_PORT) process.env.MISTER_PORT = '3005';
  if (!process.env.E2E_PLXD_FRAMES_VOID) process.env.E2E_PLXD_FRAMES_VOID = '1';
  if (!process.env.E2E_REQUIRE_PID) process.env.E2E_REQUIRE_PID = '1';
  if (!process.env.E2E_TIER) process.env.E2E_TIER = '240p';

  const plexBase = (process.env.PLEX_BASE || '').replace(/\/$/, '');
  const misterHost = process.env.MISTER_HOST;
  const misterPort = process.env.MISTER_PORT || '3005';
  const webUser = process.env.PLEX_WEB_USER || '';
  const chromium =
    process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ||
    process.env.PW_CHROMIUM_PATH ||
    '';

  log('PREFLIGHT_ENV begin');
  if (loaded.length) log(`PREFLIGHT_ENV loaded_files=${loaded.join(',')}`);
  else log('PREFLIGHT_ENV loaded_files=(none) — optional: tests/hw/e2e/.env.lab or ~/.config/misterplex/e2e.env');

  const problems = [];
  const notes = [];

  if (!plexBase) {
    problems.push({
      key: 'PLEX_BASE',
      severity: 'fail',
      detail:
        'PLEX_BASE is unset. LOCAL PMS only.\n' +
        '  Remediation:\n' +
        '    export PLEX_BASE=http://YOUR-PLEX-SERVER:32400\n' +
        '  Or put PLEX_BASE=... in ~/.config/misterplex/e2e.env or tests/hw/e2e/.env.lab (gitignored).\n' +
        '  Do NOT use SHIELD or remote plex hosts.',
    });
  } else if (/plex\.nevertrustaf\.art|32401/.test(plexBase)) {
    problems.push({
      key: 'PLEX_BASE',
      severity: 'fail',
      detail: `PLEX_BASE=${plexBase} looks remote/ignored. Use LOCAL PMS only.`,
    });
  } else {
    notes.push(`PLEX_BASE=${plexBase}`);
  }

  if (!tok.token) {
    problems.push({
      key: 'PLEX_TOKEN',
      severity: 'fail',
      detail:
        'PLEX_TOKEN missing (and no usable token file).\n' +
        '  Remediation (pick one):\n' +
        '    export PLEX_TOKEN=...          # account/server token for LOCAL PMS web UI\n' +
        '    export PLEX_TOKEN_FILE=/path/to/token   # file with token only\n' +
        '  Auto-tried: /tmp/local_tok.txt, ~/.config/misterplex/plex_token, ~/.plex_token\n' +
        '  Never commit the token.',
    });
  } else {
    notes.push(`PLEX_TOKEN source=${tok.source} len=${tok.token.length} (value not printed)`);
  }

  // PLEX_WEB_USER optional — empty means auto first Home profile (logged at runtime).
  if (webUser) notes.push(`PLEX_WEB_USER=${webUser} (exact Home profile name)`);
  else {
    notes.push(
      'PLEX_WEB_USER=(auto) — will click first Plex Home profile and log PLEX_WEB_USER_DEFAULTED=<name>. ' +
        'To pin: export PLEX_WEB_USER=YourProfileName (name shown on Select User screen).'
    );
  }

  notes.push(`MISTER_HOST=${misterHost} MISTER_PORT=${misterPort}`);
  notes.push(
    `E2E_TIER=${process.env.E2E_TIER} E2E_TRANSITION_CYCLES=${process.env.E2E_TRANSITION_CYCLES || '10'} ` +
      `E2E_OVERLAY_ONLY=${process.env.E2E_OVERLAY_ONLY || '0'} ` +
      `E2E_OVERLAY_HOLD_SEC=${process.env.E2E_OVERLAY_HOLD_SEC || '8'}`
  );

  // Chromium — soft until suite; check node_modules
  const pwPath = path.join(__dirname, 'node_modules', 'playwright');
  if (!fs.existsSync(pwPath)) {
    problems.push({
      key: 'playwright',
      severity: 'skip',
      detail:
        'tests/hw/e2e/node_modules/playwright missing.\n' +
        '  Remediation: cd tests/hw/e2e && npm install',
    });
  } else {
    notes.push(`playwright_pkg=present chromium_env=${chromium || '(playwright default/cache)'}`);
  }

  for (const n of notes) log(`PREFLIGHT_OK ${n}`);
  for (const p of problems) {
    log(`PREFLIGHT_BAD key=${p.key} severity=${p.severity}`);
    log(p.detail);
  }

  const hard = problems.filter((p) => p.severity === 'fail');
  const skips = problems.filter((p) => p.severity === 'skip');
  if (hard.length) {
    log('PREFLIGHT_ENV RESULT=FAIL — fix PREFLIGHT_BAD items; not running suite');
    log('CAST_PICKER_E2E_RESULT=FAIL');
    process.exit(EXIT_FAIL);
  }
  if (skips.length) {
    log('PREFLIGHT_ENV RESULT=SKIP-NOT-PASS — deps missing (never a pass)');
    log('CAST_PICKER_E2E_RESULT=SKIP-NOT-PASS');
    process.exit(EXIT_SKIP);
  }

  // Live reachability when required
  if (requirePms && plexBase && tok.token) {
    const web = await httpGet(`${plexBase}/web/index.html`);
    log(`PREFLIGHT_PMS web_status=${web.status} url=${plexBase}/web/index.html`);
    if (web.status < 200 || web.status >= 400) {
      log(
        'PREFLIGHT_ENV RESULT=UNVERIFIED — PLEX_BASE set but PMS Web unreachable\n' +
          `  Check host/port/firewall. GET ${plexBase}/web/index.html → HTTP ${web.status}`
      );
      log('CAST_PICKER_E2E_RESULT=UNVERIFIED');
      process.exit(EXIT_UNVERIFIED);
    }
    const idn = await httpGet(`${plexBase}/identity`);
    const mid = (idn.body.match(/machineIdentifier="([^"]+)"/) || [])[1] || '';
    log(`PREFLIGHT_PMS identity_status=${idn.status} machineId=${mid || '?'}`);
    if (idn.status < 200 || !mid) {
      log('PREFLIGHT_ENV RESULT=UNVERIFIED — /identity failed');
      log('CAST_PICKER_E2E_RESULT=UNVERIFIED');
      process.exit(EXIT_UNVERIFIED);
    }
  }

  if (requireDaemon) {
    const tl = await httpGet(
      `http://${misterHost}:${misterPort}/player/timeline/poll?commandID=1&wait=0`
    );
    const ok =
      tl.status === 200 &&
      (tl.body.includes('Timeline') || tl.body.includes('MediaContainer'));
    log(
      `PREFLIGHT_DAEMON timeline_status=${tl.status} ok=${ok ? 1 : 0} ` +
        `url=http://${misterHost}:${misterPort}/player/timeline/poll`
    );
    if (!ok) {
      const res = await httpGet(`http://${misterHost}:${misterPort}/resources`);
      log(`PREFLIGHT_DAEMON resources_status=${res.status}`);
      log(
        'PREFLIGHT_ENV RESULT=FAIL — companion :3005 unreachable (daemon_unreachable class)\n' +
          `  Remediation: confirm misterplexd on ${misterHost}, curl http://${misterHost}:3005/resources → 200\n` +
          '  Parent owns device; this suite does not ssh/restart.'
      );
      log('CAST_PICKER_E2E_RESULT=FAIL');
      process.exit(EXIT_FAIL);
    }
  }

  log('PREFLIGHT_ENV RESULT=OK — starting suite');
  return {
    ok: true,
    plexBase,
    misterHost,
    misterPort,
    tokenSource: tok.source,
    webUser: webUser || '(auto)',
  };
}

module.exports = {
  applyLabEnvFiles,
  resolveToken,
  runPreflight,
  loadDotEnvFile,
  EXIT_FAIL,
  EXIT_UNVERIFIED,
  EXIT_SKIP,
};

if (require.main === module) {
  runPreflight({
    requirePms: !/^(0|false|no)$/i.test(String(process.env.E2E_PREFLIGHT_PMS || '1')),
    requireDaemon: !/^(0|false|no)$/i.test(String(process.env.E2E_PREFLIGHT_DAEMON || '1')),
  }).then(() => process.exit(0));
}
