# CADENCE JITTER RCA (w-geom) — single-refresh holds / “frames dropped”

**Branch:** `w-avsync-hdmi-measure`  
**HEAD:** `37256b53` (at report write; re-check `git rev-parse --short HEAD`)  
**Scope:** source + unit only. No device / no Quartus.  
**Parent device (caller-supplied, not re-measured here):** RBF `78eff44e`, daemon `7c991e47`, soak n=720,  
`frames=presents=720 drops=0 residual=0`,  
`p_d0=0 p_d1=0.0335 p_dge2=0.9639 mean_ms=41.659 ideal=41.667`,  
`interval_verdict=ARM_LATE_OR_BIMODAL skip_verdict=NO_ZERO_REFRESH_SKIP`.

---

## Standing rule (field names)

| Field | Derivation |
|-------|------------|
| `p_d*` / `p_delta*` | Δ of PLXD[63:48] `frames_done` between successive **ARM publish notes** — **not** display hold refreshes |
| `p_hold_d*` | `round(publish_iv_ms / T_vsync)` with `T_vsync` from `vsync_hz` (default **ESTIMATE_60Hz** until measured) |
| `presents` | `++presentCount_` after ARM publish OK (`media_player`) — supply-side |
| `drops` | A/V pacer Drop path — supply-side |
| `frames_done` tip RTL | `frames_done++` only on bank swap (`ddr_frame_store.sv` swap arm) |
| `frames_done` c5382bee | packed `bank_vsync_count` (HISTORICAL FAULT; void as swap metric) |

**Parent misread (must correct):**  
`p_d1 = 0.0335` was taken as “3.35% of frames held for one 16.7 ms refresh.”  
**That is false under tip ledger semantics.**  
`p_d1` = fraction of consecutive publish pairs with **Δframes_done == 1**.  
**1-refresh hitch signal is `p_hold_d1`**, not `p_d1`.  
Unit alias line states this explicitly:  
`p_d1_is=delta_frames_done_eq1_NOT_hold_refresh`  
(`host/libmisterplex/publish_swap_delta_ledger.hpp` `formatCompatAliasLine`).

Synthetic hitchy case (unit): `p_delta1=1.000` (swap counter healthy) **and** `p_hold_d1=0.0326` → `cadence_verdict=HITCHY_D1`.  
That is the shape parent needs on device — not `p_d1`.

---

## T1 — Why a frame can be held for exactly one refresh

### Swap path (quoted)

`ddr_frame_store.sv` (product):

```systemverilog
// Capture new doorbell before vsync-swap decision...
if (swap_req_s2 != swap_req_seen) begin
    swap_req_seen <= swap_req_s2;
    pending_bank <= pending_bank_s2;
    if (!(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC
          && vsync_pulse && swap_pending && pending_ready_s2))
        swap_pending <= 1'b1;
end

if (vsync_pulse && swap_pending && pending_ready_s2) begin
    disp_bank <= pending_bank;
    ...
    frames_done <= frames_done + 16'd1;
    vsync_toggle <= ~vsync_toggle;
end else if (vsync_pulse) begin
    vsync_toggle <= ~vsync_toggle;
end
```

- Swap is a **1-cycle window**: `vsync_pulse && swap_pending && pending_ready_s2`.
- **No min-2-refresh interlock** exists anywhere in this always block (grep: no `min_hold` / `hold_count` in present/DDR RTL).
- Therefore **1-refresh holds are RTL-legal**: doorbell arms `swap_pending`; next vsync with ready swaps; if the **next** doorbell is armed in time for the **following** vsync, prior frame displayed for exactly one refresh.

### 907e same-cycle race — KILLED as the 1-hold mechanism

Parameter default: `SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1` (product).

**What 907e fixes (quoted intent in RTL):** same-cycle `swap_req` + `vsync` used to NBA-clear `swap_pending` and **drop the new doorbell** (freeze / lost pending). Hold-across path **re-arms** `swap_pending` for the **newly latched** bank after the **current** swap of the **old** pending.

**What it does not do:** advance the **previous** frame’s swap one refresh early. Timeline under HOLDS=1 same-cycle:

1. Vsync fires with old `swap_pending` → **old** bank becomes `disp_bank` (swap now).
2. New doorbell same cycle → `pending_bank` updated; HOLDS keeps `swap_pending=1` for **new** bank.
3. New bank swaps at **next** vsync — not this one.

So 907e prevents **lost new frame / freeze**, not “prior hold shortened to 1.”  
**Verdict: 907e is NOT the mechanism of 1-refresh display holds.**

### How 1-refresh holds actually arise (mechanism)

Product present path is **async free-gated** (unit `test_cadence_swap_path` C1–C4, source-locked):

1. ARM pacer decides Present (audio/wall drift servo — T3).
2. `publishDdrFrame` → memcpy bank → doorbell (`fpga_spi.cpp` hot path; no wait-for-vsync).
3. RTL swaps at **next** qualifying vsync after `pending_ready`.
4. Hold length on glass = **vsyncs until next successful swap** = function of (publish phase relative to vsync) × (inter-publish interval).

If publish B lands soon enough after swap(A) that B is ready before the next vsync after A’s first full refresh ends, hold(A)=1.

Unit model C4 (async + late jitter) produces `hist={1:248, 2:1057, 3:846, 4:142, 5:106}` — **hold=1 is real under free-gate + timing jitter**.  
C3 (healthy free-gate, steady 24→60 phase) produces **only {2,3}** — so **ideal free-gate alone does not force d1**; **interval/phase jitter does**.

### Min-2-refresh interlock — right fix?

| | |
|--|--|
| **Pros** | Hard-kills single-refresh hitch; simple RTL (`hold_since_swap < 2` → suppress swap). |
| **Cons** | At 30 fps ideal≈33.3 ms, min-2 = floor latency = one full refresh always; phase lag stacks; 60 fps content broken; does not create true 3:2 film cadence — only clamps floor. Error moves to longer average latency / occasional ≥4 catch-up if publisher keeps early. |
| **Better product fix** | Intentional 2,3,2,3 (or cadence-gated swap requiring `pending_ready`) **after** ARM vs RTL cause is settled (T2). Unit C5 shows cadence-gated kills ge4 under jitter; tradeoff note already in `test_cadence_swap_path`. |

**Do not fit min-2 or cadence wire until T2 disc + `p_hold_d1` are scored on a daemon that emits them.**

### Parent soak vs tip classifier (fd semantics)

Tip `summarize()` when `p_delta1 < 0.5` and `p_delta_ge2 ≥ 0.5` and `mean_delta ∈ [1.5,5]`:

- `fd_semantics = LIKELY_VSYNC_PACKED`
- `skip_verdict = UNSCORED`

Parent log shape `p_d1=0.0335 p_dge2=0.9639` + `skip_verdict=NO_ZERO_REFRESH_SKIP` **without** `fd_semantics` / `p_hold_d*` / `cadence_verdict` matches **old daemon ledger** (`7c991e47`), not tip `formatSummaryLine`.

Under **true swap counter** tip RTL (`frames_done++` only on swap; PLXD packs `frames_done_d2`), **one doorbell → ≤1 swap per interval** ⇒ expect `p_delta1 ≈ 1`, `p_delta_ge2 ≈ 0`, `mean_delta ≈ 1`.  
Parent’s `p_dge2≈0.96` is **vsync-pack shaped**, not swap-counter shaped.

**Rule 0 statement:**  
Tip **source** packs `frames_done_d2` (quoted PLXD pack block).  
Whether RBF `78eff44e` matches that pack is **unknown without freeze md5 of fitted `ddr_frame_store.sv` / PLXD pack lines** — not claimed here.  
**Check that settles it:** deploy tip daemon; print `mean_delta fd_semantics`; if `LIKELY_VSYNC_PACKED` on claimed swap RBF → pack freeze mismatch or wrong field read.

---

## T2 — ARM-side vs RTL-side

### Discriminator — already implemented (ARM-only; no RBF)

`host/libmisterplex/publish_interval_ledger.hpp`:

- `note(pre_us, post_us)`: pre = immediately **before** DDR/SPI write begins; post = **after** return.
- `arrival_iv = Δpre`; `write_us = post−pre`.
- `LATE_ARRIVAL`: arrival `p_ge50` elevated, write duration flat.
- `LATE_OBSERVATION`: arrival clean, write_us fat tail on long intervals.

Unit: `test_publish_interval_ledger` **true rc=0** (LATE_ARRIVAL / LATE_OBSERVATION synthetic both green).

**Device gap:** parent daemon md5 `7c991e47` predates full disc + hold_d lines.  
**Action:** rebuild/deploy daemon from this branch (parent owns deploy). Cheap: C++ only.

### Fabric refresh phase — NOT ARM-readable today

- `vsync_toggle` flips every vsync (swap arm **and** else-if vsync) — **internal reg only**.
- `bank_vsync_count` still increments on CDC vsync edge in DDR domain — **not packed into PLXD[63:48] on tip** (tip packs `frames_done_d2`).
- `phase_tag=ESTIMATE_60Hz` / `DEFAULT_ASSUMED` until `setVsyncHzMeasured`.

**Can refresh phase be measured from fabric without new RBF?**  
**No** — not from current PLXD ABI.  
**Cheapest future RBF (cost only, do not implement now):** pack `bank_vsync_count` or `vsync_toggle` into PLXD reserved `[47:36]` (12 bits free in pack comment) so ARM can measure Δvsync independently of swap counter. Separate exclusive.

Until then: score `p_hold_d*` with explicit `vsync_tag=ESTIMATE_60Hz` and treat as estimate-dependent.

---

## T3 — Is 3:2 pulldown attempted?

**No. Design gap, not a latent bug in an existing 3:2 engine.**

### Product pacer (quoted)

`host/libmisterplex/av_clock.hpp`:

```cpp
enum class AvAction { Present, Hold, Drop };

inline AvAction avDecide(int64_t driftMs, int64_t leadMs, int64_t dropMs, int dropRun,
                         int maxDropRun = 1) {
    if (dropMs > 0 && driftMs > dropMs && dropRun < maxDropRun)
        return AvAction::Drop;
    if (driftMs + leadMs < 0)
        return AvAction::Hold;
    return AvAction::Present;
}
```

`media_player.cpp` (~4050+): loop `avDecide` → on Hold `sleep_for(2ms)` → retry; on Present call `presentCleanFrame` (publish). Default `presentLeadMs_ = 40`.

- Master clock = audible audio bytes (or wall if no audio).
- Target = exact rational `frameContentMs(frameIndex)` + offset.
- **No** display-tick counter, **no** forced 2,3,2,3 pattern, **no** wait-for-vsync before doorbell.

### Cadence model exists but is not product-wired

`test_cadence_swap_path` C1 (source-locked):

- `present_cadence` → bars/stats only; `Plex.sv`: legacy cadence fixed; **daemon handles pacing**.
- DDR swap remains `vsync_pulse && swap_pending && pending_ready_s2`.
- `cadence.hpp` has no arm/ references on product path.

**Therefore:** publisher aims for **mean** content time ≈ 1000×den/num ms (24 → 41.667).  
An aperiodic pattern that **averages** 2.5 refreshes **will judder** even when `mean_ms ≈ ideal` — exactly parent’s observation shape.  
That is a **design gap** relative to film 3:2, not a counter lying about drops (ledger correctly shows drops=0).

---

## T4 — Metrics ownership

**w-instr** owns metric definitions / sigma gates / `p_ge50` vs `p_hold_d1` scoring policy.  
**w-geom** owns mechanism (this doc). No re-derivation of w-instr bands beyond citing tip headers already on branch.

---

## T5 — Device card

See `DEVICE_CARD_CADENCE.md` (same directory).

---

## Unit gates (this report)

| Gate | true rc |
|------|---------|
| `./build/test_publish_swap_delta_ledger` | **0** |
| `./build/test_publish_interval_ledger` | **0** |
| `./build/test_cadence_swap_path` | **0** |
| `./build/test_avclock` | **0** |

---

## Bottom line for parent

1. **User is not seeing drops** at publish layer (your soak: frames=presents, drops=0) — **confirmed supply-side**.
2. **Visible hitch can still be real** via **1-refresh holds** (RTL-legal, no min-2) and/or **irregular 2/3 without intentional 3:2**.
3. **Do not use parent `p_d1=0.0335` as hold-1 rate** — wrong field; need tip daemon → `p_hold_d1` + `cadence_verdict`.
4. **907e race is NOT the 1-hold root cause** (killed from RTL timeline).
5. **No 3:2 attempted** — free-running drift servo + async swap = design gap for film cadence.
6. **Next decisive device step:** deploy tip daemon (disc + hold_d + fd_semantics); re-soak long 480p; score `disc_verdict` + `p_hold_d1` + `fd_semantics`. Only then choose min-2 vs cadence-gate vs ARM schedule work.
7. **RBF needed?** Not for discriminator/ledger honesty (ARM-only). RBF only if packing vsync into reserved bits for measured phase, or implementing min-2 / cadence-gated swap after cause settles.
