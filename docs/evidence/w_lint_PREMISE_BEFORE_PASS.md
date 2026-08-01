# Premise-before-PASS audit (parent soak 2026-08-01)

## Confirmed case

```
publish_swap_delta pairs=7234 p_d0=0.0000 p_d1=0.0257 p_dge2=0.9743
                   skip_verdict=NO_ZERO_REFRESH_SKIP
```

Premise of `NO_ZERO_REFRESH_SKIP`: Δframes_done ∈ {0,1} with Δ=1 the norm.
Measured: **p_dge2=0.9743**, mean interval/refresh ≈ 3. Device RBF `c5382bee`
packs **bank_vsync_count** into PLXD[63:48] labelled `frames_done`.

Pre-fix scorer (`67d6d376`): assigned `NO_ZERO_REFRESH_SKIP` from `p_d0` alone.
Post-fix (`ee790a3d` + this branch): `p_delta1 < 0.5` → `skip_verdict=UNSCORED`,
`fd_semantics=LIKELY_VSYNC_PACKED`.

RBG (host):
```
./build/test_publish_swap_delta_ledger; echo "true rc=$?"
# vsync_packed → skip_verdict=UNSCORED fd_semantics=LIKELY_VSYNC_PACKED  true rc=0
# healthy Δ=1 → NO_ZERO_REFRESH_SKIP fd_semantics=SWAP_COUNTER         true rc=0
```

## T2 — FRAME_LEDGER circularity?

**Not circular with PLXD[63:48].** Code path:

| Field | Source | File |
|-------|--------|------|
| frames | pipe `frameIndex` | `media_player.cpp` present loop |
| presents | `presentCount_++` after successful DDR/FPGA publish | same |
| drops | `droppedFrames_` A/V-pacer only | same |
| publish_misses | failed present attempt | same |
| unaccounted | `frames - presents - drops` | `frame_ledger.hpp` |

`frameLedgerSessionEnd(...)` takes those ARM counters; it does **not** read
`brs.frames_done` / PLXD. So `drops=0 unaccounted=0` is a **closed ARM publish
ledger**, not a proof of zero **display** skips.

On c5382bee the mislabelled PLXD field can still advance every vsync while the
ARM ledger closes — exactly the false confidence the parent saw.

Mitigation on this branch: emit `scope=ARM_PUBLISH_NOT_DISPLAY` on ledger lines
and `VERDICT=LEDGER_OK scope=ARM_PUBLISH_NOT_DISPLAY not_display_swap`.

Coordinate: w-geom RTL pack (product should pack real swap counter); this lane
owns ARM/scorer honesty.

## T3 — deploy false-negative / missing dep

| Defect | Evidence | Fix on w-lint |
|--------|----------|---------------|
| Missing `daemon_backup_policy.sh` → die | Parent branch gap; main now requires it | Script vendored; deploy exits **rc=2** `DEPLOY_FAIL_MISSING_DEP` at top |
| `source boot_hook_policy` after live verify under `set -e` | Missing file → rc≠0 after all POST_* PASS | Explicit existence check before source; message `would_false_fail_after_live_verify` |
| Main tree prints `deploy_overall 0` **before** boot hook | `scripts/deploy_misterplexd.sh:685` then hook at 692 | **w-lint keeps overall deferred** until hook+geometry (line ~631 after hook ~504) |
| Prior exit 0 on failure | Historical | Live `/proc/PID/exe` md5 + n_daemon=1; geometry skip → **78** not 0 |

RBG missing dep:
```
# empty tree with only deploy script
true rc=2  verdict=DEPLOY_FAIL_MISSING_DEP
```

**Main still has overall-before-hook** — flag for w-promote; do not weaken w-lint.

## T4 — retraction discipline

T5 present-tense `frames_done is actually bank_vsync_count` was **real**
(`git show 100b797d^` L13). Fix = HISTORICAL FAULT block. **Do not revert.**
Fault described is **LIVE on c5382bee silicon**.

Pre-retraction check: `docs/COMMENT_CONTEXT_RULE.md` — require `git log`/`git show`.

## Ranked premise-before-PASS findings (worst first)

1. **publish_swap_delta NO_ZERO without fd premise** — daily-driver soak false PASS.
   Fixed: premise gate + unit. Guard: `test_instrument_premise_guard.py`.

2. **FRAME_LEDGER LEDGER_OK misread as display health** — not circular, but
   scope-blind. Fixed: `scope=ARM_PUBLISH_NOT_DISPLAY`.

3. **deploy overall=0 before boot hook (main)** — opposite of false-neg: green
   printed then hook can still fail. w-lint deferred; main needs w-promote.

4. **deploy missing policy after live verify** — false RED on success. Fail-fast
   deps at top + boot_hook existence check.

5. **video_regression CORE identity** — already refuse FULL_PASS without PLXC
   (prior w-lint work).

6. **glass sampling margin** — ERROR 18/19; UNSCORED when margin inadequate
   (prior).

7. **av_drift as lipsync** — tagged servo_error_not_lipsync (prior).

8. **product-path orphan cadence** — green tests off product path (prior TIER1 RED).

## Convention

Any instrument that emits PASS/OK/NO_*_SKIP must:

1. State its **premise** in code comments and telemetry (`fd_semantics=...`).
2. **Validate** the premise on the same sample set.
3. Emit **UNSCORED (rc=77)** when premise fails — never PASS, never FAIL on the
   claimed defect class.
