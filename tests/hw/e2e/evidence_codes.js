'use strict';

/**
 * Evidence / exit-code contract — aligned with w-avsync (tools/avsync_audio_telemetry_verdict.py).
 *
 * Parent 2026-08-02: do not invent a second convention. Soft-skip is never PASS.
 *
 *   0  PASS                    — required axes have DATA and each ok
 *   1  FAIL                    — assertion disproved (control plane broken)
 *  78  INSUFFICIENT_EVIDENCE   — configured but required axis NO-DATA (e.g. PMS unreachable)
 *  79  SESSION_INVALID         — mid-run ratingKey/pid/epoch swap (never score as data)
 *  77  NO-DATA / SKIP-NOT-PASS — deps missing (chromium/token file); never a pass
 *
 * Legacy alias: UNVERIFIED was rc=2. Callers must use 78 going forward.
 * Absence is NO-DATA, never 0.0 / never green.
 */

const EXIT_PASS = 0;
const EXIT_FAIL = 1;
/** @deprecated use EXIT_INSUFFICIENT_EVIDENCE=78 — kept only as name alias docs */
const EXIT_UNVERIFIED_LEGACY = 2;
const EXIT_INSUFFICIENT_EVIDENCE = 78;
const EXIT_SESSION_INVALID = 79;
const EXIT_SKIP = 77; // NO-DATA / SKIP-NOT-PASS

const RESULT_PASS = 'PASS';
const RESULT_FAIL = 'FAIL';
const RESULT_INSUFFICIENT_EVIDENCE = 'INSUFFICIENT_EVIDENCE';
const RESULT_SESSION_INVALID = 'SESSION_INVALID';
const RESULT_SKIP_NOT_PASS = 'SKIP-NOT-PASS';

/**
 * What this suite settles vs cannot settle.
 * Playback quality is intermittent (~25% degrade event rate parent-measured).
 * Single-pass healthy ≠ quality verified.
 */
const COVERAGE_DECL = {
  evidence_class: 'playwright_pms_control_plane',
  settles: [
    'plex_web_reachable',
    'misterplex_in_select_player_exact',
    'companion_server_is_pms_under_test',
    'cast_session_starts',
    'pms_status_sessions_playing_correct_ratingKey',
    'pause_resume_seek_stop_reflected_on_client_and_pms',
    'session_gone_after_stop',
    'teardown_our_controller_only',
  ],
  does_not_settle: [
    'pixels_on_glass',
    'playback_quality_vfps_pfps_drops',
    'supply_ratio_starvation',
    'lipsync',
    'hdmi_lock',
    'intermittent_25pct_degrade_class',
  ],
  quality_policy:
    'VERIFY_CONTROL_NOT_QUALITY — single-pass healthy has ~75% chance of missing ' +
    'a real ~25% intermittent degrade. Do not claim "playback verified". ' +
    'Optional E2E_REQUIRE_MEDIA_HEALTH=1 + N>=10 is a separate quality probe, not default DoD.',
  exit_codes:
    '0=PASS 1=FAIL 78=INSUFFICIENT_EVIDENCE 79=SESSION_INVALID 77=SKIP-NOT-PASS/NO-DATA',
};

/** Per-assertion: what RED looks like (must be able to fail). */
const ASSERTION_FAIL_CATALOG = [
  {
    id: 'pms_reachable',
    fail_when: 'PLEX_BASE web/identity HTTP not 2xx/3xx',
    rc: EXIT_INSUFFICIENT_EVIDENCE,
    result: RESULT_INSUFFICIENT_EVIDENCE,
  },
  {
    id: 'mister_in_picker',
    fail_when: 'Select Player diff lacks exact cast name; ghost MiSTerPlexTest alone is reject',
    rc: EXIT_FAIL,
    result: RESULT_FAIL,
  },
  {
    id: 'companion_invariant',
    fail_when: 'primary companion host/fn is not PMS under test (friendlyName sort collision)',
    rc: EXIT_FAIL,
    result: RESULT_FAIL,
  },
  {
    id: 'session_playing_rk',
    fail_when: 'PMS /status/sessions missing our player or wrong ratingKey',
    rc: EXIT_FAIL,
    result: RESULT_FAIL,
  },
  {
    id: 'pause_reflected',
    fail_when: 'UI clock keeps advancing or PMS state not paused after pause',
    rc: EXIT_FAIL,
    result: RESULT_FAIL,
  },
  {
    id: 'stop_gone',
    fail_when: 'after stop, PMS still lists our player session or UI not idle',
    rc: EXIT_FAIL,
    result: RESULT_FAIL,
  },
  {
    id: 'ratingKey_stable',
    fail_when: 'rk_before != rk_after mid phase (daemon respawn / content swap)',
    rc: EXIT_SESSION_INVALID,
    result: RESULT_SESSION_INVALID,
  },
  {
    id: 'teardown_our_only',
    fail_when: 'Playwright controller still polling after suite; never fails for user tab',
    rc: EXIT_FAIL,
    result: RESULT_FAIL,
  },
  {
    id: 'playback_quality',
    fail_when:
      'NOT SCORED by default — intermittent 25% degrade cannot be claimed from N=1 healthy',
    rc: null,
    result: 'OUT_OF_SCOPE',
  },
];

function formatCoverageBanner() {
  const lines = [
    `COVERAGE_DECL evidence_class=${COVERAGE_DECL.evidence_class}`,
    `COVERAGE_SETTLES=${COVERAGE_DECL.settles.join('+')}`,
    `COVERAGE_DOES_NOT_SETTLE=${COVERAGE_DECL.does_not_settle.join('+')}`,
    `COVERAGE_QUALITY_POLICY=${COVERAGE_DECL.quality_policy}`,
    `COVERAGE_EXIT_CODES=${COVERAGE_DECL.exit_codes}`,
    'COVERAGE_NOTE: green Playwright = control-plane reachability only. HDMI pixels unavailable → still not pixel PASS.',
  ];
  for (const a of ASSERTION_FAIL_CATALOG) {
    lines.push(
      `ASSERT_FAIL_WHEN id=${a.id} rc=${a.rc == null ? 'NA' : a.rc} result=${a.result} when=${a.fail_when}`
    );
  }
  return lines.join('\n');
}

function emitResult(result, extra = '') {
  const line = extra
    ? `CAST_PICKER_E2E_RESULT=${result} ${extra}`
    : `CAST_PICKER_E2E_RESULT=${result}`;
  return line;
}

function selfCheck() {
  if (EXIT_INSUFFICIENT_EVIDENCE !== 78) throw new Error('rc78');
  if (EXIT_SESSION_INVALID !== 79) throw new Error('rc79');
  if (EXIT_SKIP !== 77) throw new Error('rc77');
  if (EXIT_PASS === EXIT_INSUFFICIENT_EVIDENCE) throw new Error('pass==insuff');
  if (EXIT_FAIL === EXIT_SKIP) throw new Error('fail==skip');
  // Soft-skip codes must never equal PASS
  for (const c of [EXIT_INSUFFICIENT_EVIDENCE, EXIT_SESSION_INVALID, EXIT_SKIP, EXIT_FAIL]) {
    if (c === EXIT_PASS) throw new Error('nonpass equals pass ' + c);
  }
  const ban = formatCoverageBanner();
  if (!ban.includes('VERIFY_CONTROL_NOT_QUALITY')) throw new Error('quality policy missing');
  if (!ban.includes('INSUFFICIENT_EVIDENCE')) throw new Error('insuff label missing');
  return true;
}

if (require.main === module) {
  try {
    selfCheck();
    console.log('evidence_codes.js selfCheck OK');
    console.log(formatCoverageBanner());
    process.exit(EXIT_PASS);
  } catch (e) {
    console.error('evidence_codes.js selfCheck FAIL', e.message);
    process.exit(EXIT_FAIL);
  }
}

module.exports = {
  EXIT_PASS,
  EXIT_FAIL,
  EXIT_UNVERIFIED_LEGACY,
  EXIT_INSUFFICIENT_EVIDENCE,
  /** @deprecated alias — prefer EXIT_INSUFFICIENT_EVIDENCE */
  EXIT_UNVERIFIED: EXIT_INSUFFICIENT_EVIDENCE,
  EXIT_SESSION_INVALID,
  EXIT_SKIP,
  RESULT_PASS,
  RESULT_FAIL,
  RESULT_INSUFFICIENT_EVIDENCE,
  RESULT_SESSION_INVALID,
  RESULT_SKIP_NOT_PASS,
  COVERAGE_DECL,
  ASSERTION_FAIL_CATALOG,
  formatCoverageBanner,
  emitResult,
  selfCheck,
};
