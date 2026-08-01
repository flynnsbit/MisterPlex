# GATE INTEGRITY AUDIT — ROUND 2

**Branch:** `w-lint-gate-integrity`  
**Worktree:** `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-lint`  
**Pre-fix tip:** `780f6543`  
**Host-only.** No device. No Quartus fit.  
**All rcs captured as `cmd; echo "true rc=$?"` (never through a pipe).**

---

## T1 — `make define-parity` and T7 / `NATIVE_V_1TO1`

### Measured (before fix)

```
make define-parity; echo "true rc=$?"
→ true rc=0
```

Table listed QSF macros only. **`NATIVE_V_1TO1` never appeared.**  
`FRAME_H=480` status=`shared`. PASS message claimed product macros match.

### What NATIVE_V_1TO1 actually is

Quoted from tip `present_core.sv` (after port from main `ef0b4de5`):

```systemverilog
localparam bit NATIVE_V_1TO1 = (FRAME_H > 240);
localparam int V_STORE_I = NATIVE_V_1TO1 ? FRAME_H : 240;
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE_I;
```

**It is a localparam, not a `VERILOG_MACRO`.**  
`check_define_parity.py` discovers macros only via QSF `set_global_assignment -name VERILOG_MACRO`.  
**Therefore the gate could PASS without ever opening `present_core.sv`.**

### Pre-fix w-lint source (defect)

Before this round, w-lint `present_core.sv` still had:

```systemverilog
localparam V_STORE = 10'd240;
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / 240;
wire past_last_row = (py >= 10'd240);
```

with **`FRAME_H=480` in Plex.qsf**.  
define-parity → **GREEN**. T7 → **absent**.  
`test_rtl_invariants.py` on w-lint **required** the hard-240 clamp — **locking the defect as PASS**.

Main (`w-avsync-hdmi-measure` @ `ef0b4de5`) already had T7 RTL + updated invariants; **main define-parity was also blind to T7**.

### Parent fit 78eff44e candidate

A GREEN define-parity + FRAME_H=480 **does not prove** NATIVE_V_1TO1 was in the fitted netlist.  
If the fit freeze lagged T7 source (or used a tree like pre-fix w-lint), glass keeps the 240-row ceiling while macros look product-correct.  
**This gate was a failed gate: it passed because it did not look.**

### Fix landed this round

1. Ported T7 `present_core.sv` from main into w-lint.  
2. Updated `test_rtl_invariants.py` to require NATIVE_V_1TO1 / V_STORE_I (like main).  
3. Extended `scripts/check_define_parity.py` with `check_present_core_t7_contract`:
   - When `FRAME_H>240`, require NATIVE_V_1TO1 + V_STORE_I + STORE_Y_SCALE÷V_STORE_I
   - Emit `DEFINE_PARITY_T7_PRESENT_*` table + explicit **NOT a VERILOG_MACRO** note
   - Self-test: `--fault-strip-t7-native` → exit 1

### Measured (after fix)

| Probe | true rc |
|-------|--------:|
| `make define-parity` | **0** |
| `--fault-strip-t7-native` | **1** |
| `--present-core` pre-T7 integ-tip-fit tree | **1** |
| `--drop-verilator-macro DDR_FRAME_STORE` | **1** |
| `--fault-rtl-coded-width 320` | **1** |

---

## T2 — Red-before-green (observed RED?)

| Gate | Runs? | Green true rc | Red demonstrated? | Red true rc | Notes |
|------|-------|--------------:|-------------------|------------:|-------|
| **define-parity** | yes (host) | 0 | yes (strip T7 / drop macro / shear) | 1 | Now covers T7 localparam |
| **quartus-sv-subset** | yes (static+elab) | 0 | not re-broken this round | — | STATIC only; pairs verilator-elab; **not** synth PASS |
| **post-fit-timing** | needs STA_RPT | missing→**2** | scratch neg slack | **1** | `slack<0` → exit 1 (hard). missing file → 4 from script / 2 from make |
| **post-fit-hierarchy** | needs FIT_RPT | missing→**2** | empty fit rpt | **1** | MISSING modules → 1. Does **not** check T7 netlist shape |
| **test_no_private_data** | yes | 0 | injected `192.168.77.77:32400` | **1** | Still catches lab IP; restored |
| **make unit** (aggregate) | yes | varies | historically RED (UNREGISTERED_COMMAND, orphan TIER1, private IP) | — | Wrapped by `run_with_skip_summary` |
| **FBAR** `test_fbar_fast` | obsolete path | — | default | **77** SKIP-NOT-PASS | Honest; not a pass |
| **e2e** | device | — | not run (host-only) | — | Parent owns device |
| **run_with_skip_summary** | yes | self-test 0 | 77→SKIP_NOT_PASS; critical→78 | 0 self | process_rc 77/78 ≠ 0 |
| **promotion_gate_check** | scripts | — | code: vr=77 → HARD FAIL | — | quoted below |
| **rtl_invariants** | yes | **0** | T7/PLXD needles | — | Updated freeze-safe + T7 |

### post-fit-timing hard fail (quoted)

`scripts/check_quartus_timing.py`:
```python
failures = [row for row in slack_rows if row.slack < 0 or row.tns < 0]
if failures:
    ...
    return 1
```
Scratch `sta_neg.rpt` with Setup slack=-1.25 → **true rc=1**.  
Scratch ok → **true rc=0**. Missing → script **4** / make **2**.

### post-fit-hierarchy hard fail

Empty hierarchy → all critical modules MISSING → **true rc=1**.  
Config requires `ddr_frame_store`, `present_core`, `stream_path`, `ddr_bitstream_reader` with min resources.  
**Gap:** hierarchy presence ≠ T7 480-row fetch path; still need glass / define-parity source contract.

### test_no_private_data

RED with private PMS URL → **true rc=1**. Clean → **true rc=0**.  
Still works.

### FBAR

```
SKIP-NOT-PASS test_fbar_fast: obsolete v2 debug-menu card...
true rc=77
```

### Gaps / never-proven-red this session

- Full `make unit` not re-run end-to-end (long); individual guards verified.  
- Live e2e / FBAR product path: host-only refuse.  
- post-fit-* never run against real 78eff44e reports **in this session** (no STA/FIT artifacts here).

---

## T3 — Field name ≠ derivation sweep

### Confirmed (prior + this round)

| Field | Name implies | Actual derivation | Site | Status |
|-------|--------------|-------------------|------|--------|
| `frames_done` | swap count | c5382bee: `bank_vsync_count`; tip: `frames_done_d2` | PLXD pack / mailbox | tags + plxd_liveness; **input_mailbox bare "swap count" FIXED this round** |
| `presents` | display present | `presentCount_++` on publish OK | media_player | **tagged** `presents_src=arm_presentCount_` + scope |
| `presented` / `drops` (profile) | glass | ARM prof counters | media_player present_profile | **tagged** this round |
| `unaccounted` | independent | `residual` (= frames-presents-drops) | frame_ledger fragment | already `unaccounted_eq` + scope |
| `HISTORICAL FAULT` | past only | may describe live c5382bee | ddr_bank_release_select | keep; NOT YET FITTED |
| `V_STORE=240` in hdmi_source_resolution | current RTL | was hardcoded pre-T7 | tools/hdmi_source_resolution.py | **split c5382bee vs tip T7** |
| `src_fps=23.976` | measured | ERROR 17 class | hdmi_motion (main) | w-lint already refuses DEFAULT_ASSUMED; comments warn 23.976 |
| `vfps`/`pfps` | HDMI | wall+counters | media_player | already `vfps_src=measured` |
| `swap_live` | healthy swaps | swap_progress ∧ ¬stuck | plxd_liveness | documented |
| `check_decode_throughput unaccounted` | mystery cycles | cycles_total - accounted - overhead | tools/ | sim cycle residual; named honestly in stages |

### Ranked remaining risk (worst first)

1. **Any consumer still treating PLXD `frames_done` as swap count on c5382bee** — runtime safety; mitigated by plxd_liveness but logs must keep `frames_done_src=...`.  
2. **`[STALL]` / bank-select lines printing `frames_done=` without src tag** — still raw field (operator may misread).  
3. **hdmi_source_resolution / vstore tools** if they hardcode 240 without RBF identity — partially fixed.  
4. **input_mailbox** — fixed comment this round.

### Guard

`tests/unit/test_label_derivation_guard.py` extended for input_mailbox + define-parity T7 contract. **true rc=0**.

---

## T4 — Soft-skip (rc=77 / UNSCORED) never counted as pass

| Path | Behavior | Evidence |
|------|----------|----------|
| `run_with_skip_summary.py` | 77→`SKIP_NOT_PASS` process_rc=77; critical skip +0 → process_rc=**78** | self-test **true rc=0**; prints process_rc=77/78 |
| `make unit` | wraps unit in run_with_skip_summary | Makefile:47 |
| `promotion_gate_check.sh` | motion vr=77 → **HARD FAIL** (agg 8) | `:552-554` |
| `rollback_v2.sh` | visual 77 → fail pair (rc 8) | `:492-496`, `:879` |
| `test_fbar_fast` | default **77** SKIP-NOT-PASS | measured true rc=77 |
| `run_menu_matrix.sh` | any RESULTS=SKIP → `hw_skip_not_pass` (not exit 0) | `:379-381` then skip path; FAIL sets fail=1 |
| glass / interval / swap ledgers | UNSCORED string; never pass on premise fail | prior units rc=0 |
| `test_deploy` plexctl host | **77 accepted as ok** for "not on MiSTer" skip | intentional host-only skip of device probe — **not** product PASS; labeled `plexctl-host-skip-on-mister-builder` |

### Residual soft-skip risks

- Scripts that parse only "PASS" substrings without process_rc (none found in unit path).  
- Human reading `GATE_RESULT=PASS_INCOMPLETE` as pass — process_rc=78 prevents CI green if CI uses exit code.  
- **Do not weaken** core_conf_geometry 77/78 or PMS CRITICAL 78.

---

## Actions taken (this commit set)

1. **define-parity T7 contract** + red hooks  
2. **Port T7 present_core** from main (source); invariants require it  
3. **PLXD freeze-safe invariant** (no bare `plxdLivenessProven_=true`)  
4. **Label≠derivation** tags: input_mailbox, media_player presents/profile, PLXD provenance, hdmi_source_resolution  
5. **label_derivation_guard** extended  

**Does not claim:** T7 works on silicon 78eff44e. Parent glass said 240 ceiling survived that fit — source contract is now enforced; silicon remains parent-owned.

---

## True rc scoreboard (this session)

| Command | true rc |
|---------|--------:|
| make define-parity (after T7 check) | 0 |
| define-parity --fault-strip-t7-native | 1 |
| define-parity pre-T7 present_core path | 1 |
| test_rtl_invariants.py | 0 |
| test_label_derivation_guard.py | 0 |
| run_with_skip_summary --self-test | 0 |
| test_no_private_data (clean) | 0 |
| test_no_private_data (injected IP) | 1 |
| check_quartus_timing neg slack | 1 |
| check_quartus_timing ok slack | 0 |
| check_quartus_fit_hierarchy empty | 1 |
| make post-fit-timing (no STA_RPT) | 2 |
| make post-fit-hierarchy (no FIT_RPT) | 2 |
| make quartus-sv-subset | 0 |
| test_fbar_fast (default) | 77 |

---

## Plain answers for parent

1. **define-parity before this round:** PASS **without** checking T7. Defect. Fixed: now requires NATIVE_V_1TO1 when FRAME_H>240; red-proven.  
2. **Red-before-green:** private-data, timing, hierarchy, define-parity, skip-summary, FBAR-77 all demonstrated.  
3. **Field/derivation:** more instances tagged; worst class remains PLXD frames_done semantics by RBF.  
4. **Soft-skip:** aggregator and promote/rollback treat 77 as non-pass; FBAR/menu skip exit non-zero.
