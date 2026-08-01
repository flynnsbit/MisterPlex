# DEVICE CARD — cadence hitch / 1-refresh holds (parent runs)

**Agent:** w-geom · **no ssh / no deploy by agent**  
**Branch for daemon rebuild:** `w-avsync-hdmi-measure` @ report HEAD (include disc + hold_d + honest ledger)  
**RBF under test:** `78eff44e` (caller-supplied; do not thrash)  
**Fixture:** prefer **w-asset480 long 480p** when ready. **RK6 is only ~30 s** — past-EOF empties fields; do not score short/EOF-contaminated series.

---

## 0. Pre-flight (parent)

```bash
# Core + daemon identity (quote outputs)
ssh root@$MISTER_HOST 'md5sum /media/fat/_Utility/Plex.rbf; cat /media/fat/linux/core.rbf 2>/dev/null | md5sum; md5sum /media/fat/misterplex/misterplexd; pgrep -a misterplexd; cat /media/fat/misterplex/misterplexd.conf | grep -E "DECODE|PRESENT"'
# true rc direct:
true_rc=$?; echo "true rc=$true_rc"
```

**Require for this card:**
- RBF md5 = `78eff44e…` (full hash as on device)
- Daemon rebuilt from tip branch (md5 **≠** `7c991e47` if that build lacks `p_hold_d*` / `fd_semantics` / `publish_disc`)
- `DECODE=624x480` (user-owned; do not change unless test needs it)
- `n_daemon=1`

---

## 1. Rebuild + deploy daemon only (parent)

```bash
# On build host — exact path per your usual arm cross recipe, e.g.:
make arm-plexd
# Deploy binary only (parent script); do NOT menu-thrash RBF
# scripts/deploy_misterplexd.sh or lab equivalent
```

Confirm new md5 and `:3005/resources` rc=0.

---

## 2. Long 480p cast soak (natural EOF or ≥600 presents)

Cast long 480p fixture (not RK6 30s). Let session end cleanly.

Capture **full** end-of-session log lines containing:

- `FRAME_LEDGER` / frame ledger summary  
- `publish_swap_delta` (full tip line — must include `fd_semantics`, `p_hold_d1`, `cadence_verdict`)  
- `publish_swap_delta_alias`  
- `publish_interval` + `publish_disc`  
- `publish_swap_delta_phase_est` if present  

```bash
# Example pull (parent owns host paths):
ssh root@$MISTER_HOST 'grep -E "FRAME_LEDGER|publish_swap_delta|publish_interval|publish_disc|publish_swap_delta_alias" /path/to/misterplexd.log | tail -40'
true_rc=$?; echo "true rc=$true_rc"
```

Optional ring dump if daemon exposes publish interval path used in prior soaks.

---

## 3. PRE-REGISTERED predictions (score only if series clean)

**Series quality gates (else UNSCORED entire card):**
- `frames == presents`, `drops=0` (or drops explained), `residual=0`
- `sigma_ms < mean_ms` for interval scoring; else `interval_verdict=UNSCORED_SIGMA_GE_MEAN`
- `notes/pairs ≥ 500` preferred; **≥ 200** minimum
- No EOF empty fields mid-score

### A. frames_done semantics on this RBF

| Prediction | Pass shape | Fail / other |
|------------|------------|--------------|
| **A1 SWAP_COUNTER** if pack is `frames_done_d2` | `fd_semantics=SWAP_COUNTER`, `mean_delta ∈ [0.95, 1.05]`, `p_delta1 ≥ 0.90`, `p_delta_ge2 < 0.10` | |
| **A2 VSYNC still packed** | `fd_semantics=LIKELY_VSYNC_PACKED`, `mean_delta ∈ [1.5, 4.0]`, `p_delta_ge2 ≥ 0.5`, `skip_verdict=UNSCORED` | Tip source claims swap pack — **A2 ⇒ freeze mismatch or wrong field** |

**Parent prior log (`p_dge2=0.96`, old skip line) is A2-shaped.** Re-measure with tip daemon before claiming A1.

### B. Cadence hitch (hold_d — the user-visible signal)

`hold_src=derived_iv_over_Tvsync`, `vsync_tag` will be `DEFAULT_ASSUMED` / estimate unless measured.

| ID | Prediction | Band |
|----|------------|------|
| **B1** | User hitch real as 1-refresh holds | `p_hold_d1 ≥ 0.02` → `cadence_verdict=HITCHY_D1` |
| **B2** | Mean perfect, pattern irregular (no intentional 3:2) | `\|mean_ms − ideal_ms\| < 0.5` **and** (`cad_alt_frac < 0.85` **or** `cadence_verdict=CADENCE_IRREGULAR`) |
| **B3** | Clean film cadence (unexpected without pacer change) | `p_hold_d2+p_hold_d3 ≥ 0.95` **and** `cad_alt_frac ≥ 0.85` **and** `p_hold_d1 < 0.01` → `CADENCE_32_CLEAN` — **falsify design-gap claim if this hits on free-gate alone** |

### C. Late arrival vs late observation (disc)

| ID | Prediction | Shape |
|----|------------|-------|
| **C1 LATE_ARRIVAL** | Publisher cadence late | `disc_verdict=LATE_ARRIVAL`, `write_late_ratio` near 1, `mean_write_us_late ≈ mean_write_us_ok` |
| **C2 LATE_OBSERVATION** | Timestamp/preemption after work | `disc_verdict=LATE_OBSERVATION`, `p_write_ge5ms` elevated, arrival axis clean |
| **C3 CLEAN** | Neither | `disc_verdict=CLEAN_ARRIVAL_AND_WRITE` |

**Prior withdrawn soak must not be reused.** This disc is the one-run settler for ARM schedule vs observation artifact.

### D. Ledger honesty (smoke)

| Check | Expect |
|-------|--------|
| No `unaccounted=` duplicate of residual as independent claim | tip honest labels |
| `fpga_obs` / residual tags say supply-side | per `frame_ledger` tip |

---

## 4. What NOT to conclude from this card

- Do **not** treat `p_d1` as 1-refresh hold rate.  
- Do **not** treat `skip_verdict=NO_ZERO_REFRESH_SKIP` as pass if `fd_semantics≠SWAP_COUNTER`.  
- Do **not** score `p_ge50` if `sigma_ms ≥ mean_ms`.  
- Do **not** attribute hitch to 907e without a new sim/device proof (source RCA **kills** that hypothesis).  
- Do **not** fit min-2 or cadence-gate RBF from this card alone — cause first (C*), then design.

---

## 5. Optional PLXD freeze check (if A2 hits on “swap” RBF)

Parent-only: md5 fitted `ddr_frame_store.sv` used for `78eff44e` vs tip:

```bash
md5sum fpga/Plex_MiSTer/rtl/ddr_frame_store.sv
# Compare to w-fit freeze file for that RBF if present under .agent-work/w-fit/
rg -n "frames_done_d2|bank_vsync_count" fpga/Plex_MiSTer/rtl/ddr_frame_store.sv | head
```

Expect tip pack line contains `frames_done_d2` in `DDRAM_DIN` for BANK mailbox — not `bank_vsync_count`.

---

## 6. Success criteria for “mechanism settled”

1. A1 or A2 decided with tip `fd_semantics`.  
2. B1 or B2 scored (or B3 falsifies gap).  
3. C1/C2/C3 disc_verdict printed once on clean series.  

Then parent chooses: ARM schedule work vs RTL min-2 vs cadence-gated swap exclusive.
