# w-fit integration brief (static — no slot)

## ≤10-line summary (just finished)

1. Dark-silicon **PROVED stronger**: under `DDR_FRAME_STORE`, `fs_wr_en` has no consumer (port L42 + else-only L317).  
2. `host_owns_fs`/`stub_allow` = inert for HDMI; withdrawn C1 not used.  
3. Residual path = **first-MB/48B probe** (inline CAVLC-style), not “no CAVLC.”  
4. Hierarchy method rule in `docs/phase3-decode.md`.  
5. RBF **`8fdf440f`** settled by **md5 of Plex.rbf** → `fit-t7b-prog480` (ALM 23585 / DSP **44** / M10K 465).  
6. DSP-74 / ALM~21021 = **other RBFs**, not shipping.  
7. `PRODUCT_NO_STUB` scaffolding default-OFF; research not deleted.  
8. Gates rc=0; **no exclusive fit requested/granted.**

## (1) Justification — build against THIS

Parent measured live playback: **0 drops**, ledger exact, **~103 %onecpu free** at 24 fps. Serial-pipeline hypothesis falsified.

**RETRACTED:** “ARM out of budget / fabric decode required to survive 24 fps.”

**Honest fabric rationale:**
- (a) headroom at **30 fps+**
- (b) **direct-play** (kill PMS transcode; high-bitrate sources)
- (c) user direction: move features off ARM (scaler/geometry first — ffmpeg scaler still ~50 %onecpu when forced)

Do **not** write starvation/decode-must-move-to-survive into plans.

## (3) Citation hazard — SETTLED

| Method | Result |
|--------|--------|
| `md5sum …/Plex.rbf` | prefix **`8fdf440f`** |
| Co-located fit | `fpga/Plex_MiSTer/remote_out/fit-t7b-prog480/Plex.fit.rpt` |
| Mirror build tree | `/home/flynnsbit/mplex-builds/fit-t7b-prog480/Plex_MiSTer/output_files/{Plex.rbf,Plex.fit.rpt}` same md5 |
| Totals | ALM **23,585** · M10K **465** · DSP **44** · bits 2,997,709 |
| Worktree `fpga/.../output_files/` | **absent** (not a second competing report here) |
| ALM 21,021 / DSP **74** | other designs (e.g. product-wire6 `14eaeff3`, left-edge freezes) — **not** `8fdf440f` |

## (2) decode_stub reclaim — subtree exclusivity PROVED

| Quantity | Value | Meaning |
|----------|------:|---------|
| Subtree ALM | **9,216.9** | Quartus row `decode_stub:stub` |
| Own ALM | **1,922.1** | residual after children (incl. flattened hybrid) |
| Subtree M10K | **268** | of which DPB `altsyncram:dpb_mem_rtl_0` = **256** |
| Subtree DSP | **1** | |

**Every fitted `h264_*` instance under `decode_stub` is exclusive** (0 outside-stub instances of those entity names in the `8fdf440f` fit). Includes dequant/idct/recon/mc/dpb/deblock/mv_pred.  
`lpm_divide` instances under stub: exclusive to stub path.  
`altsyncram` **type** is shared (71 outside) but **instance** `dpb_mem_rtl_0` (256 M10K) lives only under stub — PRODUCT_NO_STUB drops that instance, not ascal’s RAMs.

⇒ Quoting **~9,217 ALM / 268 M10K reclaim** for PRODUCT_NO_STUB is valid **subtree** reclaim, not own-only 1,922.

**Dark-silicon mechanism (correct):** `present_core` else-only `.wr_en(fs_wr_en)` — write port unconnected in all modes.

**Telemetry hazard (do not land wrong):**
```
telem_flags = {pps_valid, sps_valid, stub_busy, has_idr, audio_underrun, has_stream, has_audio, has_frame}
ARM masks: has_frame=1, … stub_busy=32, sps_valid=64, pps_valid=128  (fpga_spi.cpp:2018-2025)
```
Removing `stub_busy` from concat **without** a zero placeholder shifts sps/pps masks → wrong status (has_frame bit0 safe). Severity: wrong-status, not black screen.  
**Mandatory:** keep 8-bit width; tie removed slots `1'b0`. Current PRODUCT_NO_STUB else already `assign stub_busy=1'b0`.  
Do **not** delete stub from Verilator TBs (`top.stub_busy`/`stub_frames`) — gate.  
Do **not** land telem bit-layout change before **w-lint bit-position gate** exists.  
Remove dead `stub_allow` / `_keep_hybrid_product` only in same audited change as telem-safe stub gate — still not before lint gate if flags width changes.

## (4) Same-fit cargo board (when parent grants slot)

| Item | Status on tip / `8fdf440f` tree | Ride next fit? |
|------|----------------------------------|----------------|
| w-geom `907e5950` NBA hold | **Already in tip** (ancestor; ddr_frame_store lines md5-match 907e) | No — already shipped in 8fdf lineage |
| w-area −32 DSP comb dequant | **Already in tip** (`mul_norm_adjust` shift-add; fit DSP 44 not 74) | No — already shipped |
| `pending_ready` hold while prep complete | **Present** (`pending_ready_ddr <= … pending_ready_c \|\| sched…`, param comments) | Only if new hardening patch appears |
| **PRODUCT_NO_STUB** Tier A | Scaffolding default-OFF; exclusivity proved | **YES — primary new cargo** |
| w-geom fabric scaler / geometry | Needs M10K from stub reclaim | **YES — pair with PRODUCT_NO_STUB** |

**One fit when granted:** enable `PRODUCT_NO_STUB` + scaler/geometry cargo. Do not burn a slot on 907e/dequant alone.

### Pre-register (PRODUCT_NO_STUB only, vs `8fdf440f`)

| Metric | Baseline | Pred after Tier A |
|--------|--------:|------------------:|
| ALM | 23,585 | ~14,368 (−9,217) |
| M10K | 465 | ~197 (−268) |
| DSP | 44 | ~43 (−1) |
| setup/hold | +0.333 / +0.245 | ≥0 unknown until STA |

No new `set_false_path`. Miss if M10K Δ ≠ ~268.

## Do-not-ship

Working product cores (not banned): **`8fdf440f`** (T7b shipping), **`c5382bee`** (earlier working DDR — not in freeze/banned sets).  
Banned freezes/timing: `9eb1431a`, `ff2e3ca3`, `f0d3a385`, `2890baac`.  
Banned set: `{8832824e, 75da8bb1, 4d6ee356, 4deaf6cc, dabdaeb0}`.

## Process

- Worktree: `.worktrees/w-fit-integ` · branch `w-fit-ceiling-fd-min`  
- Static/sim only until parent grants exclusive Quartus slot.  
- No device. No telem layout change without w-lint gate.

## PRESENT_PROFILE (2026-08-01)

Pacer-limited at 480p24 (16.7 ms sleep). **No held RTL moves that table.** See `PRESENT_PROFILE_RTL_MEASURABILITY.md`. Quartus hold reinstated; no fit.
