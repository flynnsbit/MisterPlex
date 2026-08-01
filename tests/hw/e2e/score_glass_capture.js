#!/usr/bin/env node
/**
 * score_glass_capture.js — offline glass gate on a parent-provided capture dir.
 *
 * Does NOT open /dev/video0. Does NOT drive Plex. Invokes
 * tools/hdmi_motion_instrument.py (w-instr template counter) then applies
 * glass_counter_loss gap% so a 1.54% skip session cannot report PASS.
 *
 * Usage:
 *   E2E_GLASS_CAPTURE_DIR=/path/to/pngs node tests/hw/e2e/score_glass_capture.js
 *   node tests/hw/e2e/score_glass_capture.js /path/to/pngs
 *
 * Exit: 0 glass OK | 1 FAIL (loss/rate/structure/...) | 77 missing dir/deps (never pass)
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  analyzeCounterGaps,
  nsFromInstrumentJson,
  assertGlassLoss,
} = require('./glass_counter_loss');

const EXIT_PASS = 0;
const EXIT_FAIL = 1;
const EXIT_SKIP = 77;

const ROOT = path.resolve(__dirname, '../../..');

function main() {
  const dir =
    process.argv[2] ||
    process.env.E2E_GLASS_CAPTURE_DIR ||
    process.env.E2E_HDMI_SCORE_DIR ||
    '';
  if (!dir) {
    console.error('SKIP-NOT-PASS: pass capture dir or E2E_GLASS_CAPTURE_DIR');
    process.exit(EXIT_SKIP);
  }
  if (!fs.existsSync(dir)) {
    console.error(`FAIL: capture dir missing ${dir}`);
    process.exit(EXIT_FAIL);
  }
  const tool = path.join(ROOT, 'tools', 'hdmi_motion_instrument.py');
  if (!fs.existsSync(tool)) {
    console.error(`FAIL: missing ${tool}`);
    process.exit(EXIT_FAIL);
  }

  const srcFps = parseFloat(process.env.E2E_HDMI_SOURCE_FPS || '24');
  const capFps = parseFloat(process.env.E2E_HDMI_CAPTURE_FPS || '30');
  const warmup = parseInt(process.env.E2E_HDMI_WARMUP_SKIP || '15', 10);
  const maxLoss = parseFloat(process.env.E2E_GLASS_MAX_LOSS_PCT || '1.0');
  const srcLabel = process.env.E2E_HDMI_SOURCE_FPS ? 'caller-supplied' : 'DEFAULT_ASSUMED';
  const capLabel = process.env.E2E_HDMI_CAPTURE_FPS ? 'caller-supplied' : 'DEFAULT_ASSUMED';

  console.log(`score_glass_capture dir=${dir}`);
  console.log(
    `fps source=${srcFps} (${srcLabel}) capture=${capFps} (${capLabel}) warmup_skip=${warmup} ` +
      `max_loss_pct=${maxLoss}`
  );

  const res = spawnSync(
    'python3',
    [
      tool,
      dir,
      '--warmup-skip',
      String(warmup),
      '--source-fps',
      String(srcFps),
      '--capture-fps',
      String(capFps),
      '--json',
    ],
    { encoding: 'utf8', timeout: 300000 }
  );
  const out = `${res.stdout || ''}${res.stderr || ''}`;
  const rc = typeof res.status === 'number' ? res.status : 99;
  console.log(`hdmi_instrument true rc=${rc}`);
  for (const line of out.split('\n').filter(Boolean).slice(-30)) {
    console.log(`  instrument: ${line.slice(0, 280)}`);
  }

  if (rc === 77) {
    console.error('FAIL glass: instrument UNSCORED rc=77 (never pass)');
    process.exit(EXIT_FAIL);
  }
  if (rc !== 0) {
    console.error(`FAIL glass: instrument rc=${rc}`);
    process.exit(EXIT_FAIL);
  }

  const ns = nsFromInstrumentJson(out);
  const gap = analyzeCounterGaps(ns);
  console.log(
    `GLASS_COUNTER_GAPS samples=${gap.n_samples} n=${gap.n_first}->${gap.n_last} ` +
      `span=${gap.source_span} skips=${gap.skips} loss_pct=${
        gap.loss_pct != null ? gap.loss_pct.toFixed(3) : 'NA'
      } value_kind=${gap.value_kind}`
  );
  const gr = assertGlassLoss(gap, maxLoss, 'offline');
  if (!gr.ok) {
    console.error(`FAIL ${gr.reason}: ${gr.detail}`);
    console.log('CAST_GLASS_RESULT=FAIL');
    process.exit(EXIT_FAIL);
  }
  console.log(`GLASS_LOSS_OK ${gr.detail}`);
  console.log('CAST_GLASS_RESULT=PASS');
  process.exit(EXIT_PASS);
}

main();
