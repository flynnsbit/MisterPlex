#!/usr/bin/env node
/**
 * race_taxonomy.js — pure classification for details/play races + N-loop aggregate.
 *
 * Parent RED class: spinner-only details → play_button_not_found was a false
 * diagnosis. Distinct reasons must stay separated so a red artifact is actionable.
 *
 * No browser, no network. Exit 0 = taxonomy selfCheck OK; 1 = misclassified.
 */
'use strict';

/**
 * Classify a details-wait timeout into a distinct fail reason.
 * @param {{ sawTitle: boolean, playSel: string|null, spinnerVisible: boolean,
 *           bodyLineCount: number, loadingText: boolean, maxMs: number }} s
 * @returns {{ reason: string, diagnosable: boolean, detail: string }}
 */
function classifyDetailsTimeout(s) {
  const sawTitle = !!s.sawTitle;
  const playSel = s.playSel || null;
  const spinner = !!s.spinnerVisible;
  const lines = Number.isFinite(s.bodyLineCount) ? s.bodyLineCount : -1;
  const loadingText = !!s.loadingText;
  const maxMs = s.maxMs || 0;

  // Spinner still owns the pane — not a missing Play selector.
  if (spinner || (loadingText && !sawTitle && !playSel && lines >= 0 && lines < 12)) {
    return {
      reason: 'details_spinner_stuck',
      diagnosable: true,
      detail:
        `Spinner/loading still owns details after ${maxMs}ms ` +
        `(sawTitle=${sawTitle} playSel=${playSel || 'none'} lines=${lines}). ` +
        'Race: wait for spinner gone + title/metadata, do not treat as play_button_not_found.',
    };
  }
  if (!sawTitle && !playSel) {
    return {
      reason: 'details_never_rendered',
      diagnosable: true,
      detail:
        `Neither title nor Play appeared within ${maxMs}ms (lines=${lines}). ` +
        'Deep-link or Home gate likely still loading — not a selector typo.',
    };
  }
  if (sawTitle && !playSel) {
    // Title painted but Play absent after full wait — caller may still open cast first.
    return {
      reason: 'details_ready_title_only',
      diagnosable: true,
      detail:
        `Title visible but Play control never appeared within ${maxMs}ms. ` +
        'If this is pre-cast, title-only can be OK; post-cast this becomes play_button_not_found.',
    };
  }
  return {
    reason: 'details_never_rendered',
    diagnosable: true,
    detail: `Details wait timed out after ${maxMs}ms (sawTitle=${sawTitle} play=${playSel || 'none'})`,
  };
}

/**
 * After cast select, classify missing Play.
 * @param {{ sawTitle: boolean, playSel: string|null, spinnerVisible: boolean,
 *           loadingText: boolean, bodyLineCount: number }} s
 */
function classifyPlayMissingAfterCast(s) {
  const lines = Number.isFinite(s.bodyLineCount) ? s.bodyLineCount : 99;
  const stillLoading =
    !s.sawTitle ||
    !!s.spinnerVisible ||
    (!!s.loadingText && !s.playSel && lines < 12);
  if (stillLoading) {
    return {
      reason: 'details_never_rendered',
      diagnosable: true,
      detail:
        'After selecting cast target, details were not ready for Play (spinner/loading). ' +
        'Do not report play_button_not_found for a load race.',
    };
  }
  return {
    reason: 'play_button_not_found',
    diagnosable: true,
    detail:
      'Details rendered and cast target selected, but no Play control matched PLAY_SELECTORS. ' +
      'Selector drift or layout change — not a spinner race.',
  };
}

/**
 * N-loop aggregate: majority must never pass.
 * @param {{ planned: number, results: Array<{ ok: boolean, cycle?: number, transition?: string }> }} o
 */
function classifyNLoopAggregate(o) {
  const planned = o.planned || 0;
  const results = Array.isArray(o.results) ? o.results : [];
  const passed = results.filter((r) => r.ok).length;
  const failures = results.filter((r) => !r.ok);
  const failed = failures.length;
  const attempted = results.length;
  const incomplete = attempted !== planned;
  const majorityWouldPass = planned > 0 && passed > failed && failed > 0;

  if (failed === 0 && passed === planned && !incomplete) {
    return {
      ok: true,
      reason: 'transitions_ok',
      pass: passed,
      fail: failed,
      majority_pass_is_pass: false,
      detail: `pass=${passed}/${planned}`,
    };
  }
  const first = failures[0];
  return {
    ok: false,
    reason: first
      ? `transition_cycle_${first.cycle || '?'}_${first.transition || 'unknown'}`
      : 'transitions_incomplete',
    pass: passed,
    fail: failed,
    majority_pass_is_pass: false,
    majority_would_have_passed_wrongly: majorityWouldPass,
    detail:
      `pass=${passed}/${planned} fail=${failed} attempted=${attempted}` +
      (first
        ? ` first_fail cycle=${first.cycle} transition=${first.transition} reason=${first.reason || '?'}`
        : '') +
      (majorityWouldPass ? ' (majority is NOT a pass)' : ''),
  };
}

function selfCheck() {
  const cases = [];

  // Spinner-only → NOT play_button_not_found
  {
    const r = classifyDetailsTimeout({
      sawTitle: false,
      playSel: null,
      spinnerVisible: true,
      bodyLineCount: 6,
      loadingText: true,
      maxMs: 90000,
    });
    if (r.reason !== 'details_spinner_stuck') {
      throw new Error(`spinner case got ${r.reason}`);
    }
    cases.push('details_spinner_stuck');
  }

  // Empty shell
  {
    const r = classifyDetailsTimeout({
      sawTitle: false,
      playSel: null,
      spinnerVisible: false,
      bodyLineCount: 3,
      loadingText: false,
      maxMs: 60000,
    });
    if (r.reason !== 'details_never_rendered') {
      throw new Error(`empty shell got ${r.reason}`);
    }
    cases.push('details_never_rendered');
  }

  // Title only at timeout
  {
    const r = classifyDetailsTimeout({
      sawTitle: true,
      playSel: null,
      spinnerVisible: false,
      bodyLineCount: 20,
      loadingText: false,
      maxMs: 60000,
    });
    if (r.reason !== 'details_ready_title_only') {
      throw new Error(`title-only got ${r.reason}`);
    }
    cases.push('details_ready_title_only');
  }

  // Post-cast: spinner → details_never_rendered
  {
    const r = classifyPlayMissingAfterCast({
      sawTitle: false,
      playSel: null,
      spinnerVisible: true,
      loadingText: true,
      bodyLineCount: 8,
    });
    if (r.reason !== 'details_never_rendered') {
      throw new Error(`post-cast spinner got ${r.reason}`);
    }
    cases.push('post_cast_spinner_is_details_never_rendered');
  }

  // Post-cast: ready but no play → play_button_not_found
  {
    const r = classifyPlayMissingAfterCast({
      sawTitle: true,
      playSel: null,
      spinnerVisible: false,
      loadingText: false,
      bodyLineCount: 40,
    });
    if (r.reason !== 'play_button_not_found') {
      throw new Error(`post-cast ready got ${r.reason}`);
    }
    cases.push('play_button_not_found');
  }

  // N-loop: 9/10 must FAIL suite
  {
    const results = [];
    for (let i = 1; i <= 10; i++) {
      results.push(
        i === 7
          ? { ok: false, cycle: 7, transition: 'pause', reason: 'state_not_paused' }
          : { ok: true, cycle: i }
      );
    }
    const a = classifyNLoopAggregate({ planned: 10, results });
    if (a.ok) throw new Error('9/10 must not pass');
    if (!a.majority_would_have_passed_wrongly) {
      throw new Error('expected majority_would_have_passed_wrongly');
    }
    if (!String(a.reason).includes('cycle_7')) {
      throw new Error(`expected cycle_7 in reason got ${a.reason}`);
    }
    cases.push('n_loop_9_of_10_fails_suite');
  }

  // N-loop: 10/10 pass
  {
    const results = Array.from({ length: 10 }, (_, i) => ({ ok: true, cycle: i + 1 }));
    const a = classifyNLoopAggregate({ planned: 10, results });
    if (!a.ok || a.pass !== 10 || a.fail !== 0) {
      throw new Error(`10/10 should pass got ${JSON.stringify(a)}`);
    }
    cases.push('n_loop_10_of_10_pass');
  }

  // Incomplete run
  {
    const a = classifyNLoopAggregate({
      planned: 10,
      results: [{ ok: true, cycle: 1 }, { ok: true, cycle: 2 }],
    });
    if (a.ok) throw new Error('incomplete must fail');
    cases.push('n_loop_incomplete_fails');
  }

  return { ok: true, cases };
}

module.exports = {
  classifyDetailsTimeout,
  classifyPlayMissingAfterCast,
  classifyNLoopAggregate,
  selfCheck,
};

if (require.main === module) {
  try {
    const r = selfCheck();
    console.log(`race_taxonomy.js selfCheck OK cases=${r.cases.join(',')}`);
    process.exit(0);
  } catch (e) {
    console.error('race_taxonomy.js selfCheck FAIL', e.message);
    process.exit(1);
  }
}
