# w-lint — harness false-verdict family (promote blocker)

**Branch:** `w-lint-gate-integrity`  
**HEAD:** (stamp after commit)  
**Date:** 2026-07-31  
**Scope:** host/static only — no device, no Quartus.

## Parent-measured pattern (oracle)

| # | Class | Evidence |
|---|--------|----------|
| 1 | Blind-and-green | Historic gates OK while measuring nothing |
| 2 | Blind-and-RED | `bash $(…)` strips trailing NL → `V2_MD5=<32hex>set +e` (fixed `92d4434f`) |
| 3 | Defective recipe | `ffmpeg -frames:v 1` → grey warm-up frame `mean=7 std=0` rc=8; same screen with `select=gte(n\,20)` → `mean≈38.67 std≈18.53` rc=0 |

**Disease:** unstated precondition / unvalidated capture — **not** a wrong threshold. Never loosen scorers.

---

## TASK 1 — newline / glue sweep

| Location | Verdict | Evidence |
|----------|---------|----------|
| `scripts/promotion_gate_check.sh:gate_join_remote_parts` | **FIXED** | Explicit `\n` join; RBG in `test_promotion_gates.sh` + `test_harness_capture_integrity.py` |
| Naive `remote="$(p1)$(p2)"` elsewhere under `scripts/` `tests/` | **none found** | Scan: zero bare adjacent `$(…)(…)` outside comments/dirname |
| Historic glue fixture | **RED proven** | `v2_md5"set +e` present in naive concat; join removes it |

## TASK 2 — unvalidated captures

| Location | Was | Fix |
|----------|-----|-----|
| `promotion_gate_check.sh` | glue → almost-right md5 | `gate_assert_md5_shape` (32 hex only; no fuzzy trim) |
| `deploy_misterplexd.sh` HOST/DISK md5 | compare without shape | `assert_md5_shape` via `md5_shape.inc.sh` |
| `rollback_v2.sh` host_md5 | compare without shape | same |
| Empty probe | misread as FAIL mismatch | NO-DATA rc=4 (prior w-lint) |

Lint: `tests/unit/test_harness_capture_integrity.py` flags gate/deploy scripts that assign md5 from `$()` and compare without shape helper.

## TASK 3 — unstated environmental preconditions

| Precondition | Was | Fix |
|--------------|-----|-----|
| USB grabber warm-up (~11–15 frames) | AGENTS.md + docs taught bare `-frames:v 1` | `scripts/capture_hdmi_frame.sh` + AGENTS/docs/pair_visual_gate/menu_osd use `select=gte(n\,20)` + DEFECTIVE warning |
| `MISTERPLEX_BASELINE_KEY` for PMS | soft-skip critical | still **PASS_INCOMPLETE** / not PASS (prior) |
| Running-core claim mtime | prose | enforced FAIL without claim (prior) |
| Device exclusive `/dev/video0` | prose in AGENTS | capture helper `fuser` busy → rc=16 |

## TASK 4 — fail-fast ordering

| Gate | Was | Fix |
|------|-----|-----|
| `promotion_gate_check.sh` verify-live | skip visual after prior fail | **aggregate** — visual always runs (`92d4434f` + tests `glue-visual-ran`) |
| `rollback_v2.sh` pair verify | `NOTE skip visual — telemetry already failed` | **always** `run_visual_gate` when `require_visual=1`; print `visual_hook true rc=` |

## TASK 5 — automated lint (RBG)

`tests/unit/test_harness_capture_integrity.py` (Makefile + rollcall **117**):

1. **RED historic glue** fixture must exist (`v2_md5"set +e`)
2. **GREEN** `gate_join_remote_parts` removes glue
3. **RED** shape rejects contaminated md5; **GREEN** accepts 32 hex
4. Scan: glue risk, unvalidated md5, grabber first-frame, fail-fast skip visual
5. Docs must not teach bare `-frames:v 1` without warm-up warning

Measured: `true rc=0` (scan_clean + RBG_OK).

Also retained: `test_pipe_rc_trap.py`, `test_gate_false_green_guard.py` (PINNOTFOUND→rc=2).

---

## Carry-forward

| Item | Status |
|------|--------|
| `fix/gate-liveness` live-exe | landed via prior w-lint + promote merge |
| `expected_commands` | **117** sha16 `030cab576a59bca4` — `--write-expected` only |
| Soft-skip ≠ pass | unchanged; geometry map has product cores |
| `score_i420_candidate.py` | **not modified** |

### Pin family fix (merge hazard)

After promote re-pin, `HYBRID_DAEMON_MD5` is **DDR `edc3a46b`**.  
`spi_daemon_md5_accepted` must **not** include it (else `daemon_family(edc3a46b)=spi` and green DDR pairs look mixed). Fixed; SPI pins = `7cd10b4d` / `50f4eb92` / `3e2cbb98`.

---

## Host true rc (direct)

| Check | true rc |
|-------|---------|
| `test_harness_capture_integrity.py` | 0 |
| `test_promotion_gates.sh` | 0 |
| `test_video_regression_liveness.sh` | 0 |
| `test_rollback_honest.sh` | 0 |
| `test_deploy_misterplexd.sh` | 0 |
| `test_pipe_rc_trap.py` | 0 |
| `test_gate_false_green_guard.py` | 0 |
| `test_live_state_identity_audit.py` | 0 |
| `test_unit_rollcall.py` | 0 (117) |
| `test_core_conf_geometry_gate.sh` | 0 |

---

## Parent recipes

```bash
# Capture (warm-up):
scripts/capture_hdmi_frame.sh build/pair-visual/idle.png
echo "true rc=$?"

# Promote verify (inject visual):
PAIR_IDLE_PNG=$PWD/build/pair-visual/idle.png \
  scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
```

Do not open Quartus for this lane.
