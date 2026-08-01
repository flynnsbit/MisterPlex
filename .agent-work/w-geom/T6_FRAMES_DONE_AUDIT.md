# T6 — Retroactive `frames_done` / PLXD[63:48] audit

**Scope:** every consumer that treated PLXD[63:48] (`BankReleaseStatus.frames_done`) as a
**swap / presented-frame** counter while RBF **c5382bee** is live.

**Deployed pack (parent-verified chain):**
- Device RBF md5 `c5382bee73cecdee8220b811e529c297`
- Freeze RTL `.agent-work/w-fit/leftedge3-proj/rtl/ddr_frame_store.sv` md5 `c139274e814a4696c485c0bba3781ad8`
- Line ~1004: `DDRAM_DIN <= {bank_vsync_count, // [63:48] frames_done`
- Lines ~926–928: `bank_vsync_count <= bank_vsync_count + 16'd1` on every vsync edge
- Internal `frames_done++` still swap-only but **not packed** on this RBF
- Tip packs `frames_done_d2` — **not fitted**

**Silicon signature:** soak `p_dge2=0.974`, mean Δfd ≈ 3.02 ≈ mean_interval/16.667 ms → field tracks **vsyncs**, not per-publish swaps.

---

## FRAME_LEDGER — `presents` / `drops` / `publish_misses` / `unaccounted`

| Field | Derives from `frames_done`? | Verdict |
|---|---|---|
| `frames` | NO — `frameIndex` (pipe assemble) | **SURVIVES** |
| `presents` | NO — `++presentCount_` only after successful `publishDdrFrame` (`media_player.cpp` ~3584) | **SURVIVES** |
| `drops` | NO — A/V pacer `droppedFrames_` | **SURVIVES** |
| `publish_misses` | NO — failed publish path | **SURVIVES** |
| `unaccounted`/`residual` | `frames - presents - drops` (`frame_ledger.hpp`) | **SURVIVES** |

**Quoted contract** (`host/libmisterplex/frame_ledger.hpp`):
```
//   presents       = successful FPGA/DDR publishes (presentCount_)
//   drops          = deliberate A/V-pacer skips ONLY (droppedFrames_)
//   publish_misses = present attempted, DDR/FPGA publish failed
```

Parent soak `presents=7230 drops=0 publish_misses=0` is **ARM publish success accounting**, **not** fabricated from PLXD. **Not void.**

---

## Consumers — table

| ID | Location | How it uses PLXD[63:48] | On c5382bee | Verdict |
|---|---|---|---|---|
| C1 | `input_mailbox.hpp:107` comment `// monotonic swap count` | ABI doc | Documents tip/intent; **silicon disagrees** | **DOC STALE vs DEPLOYED** (tip OK) |
| C2 | `mailbox_abi_spec.hpp` `[63:48] frames_done — monotonic bank-swap` | ABI SoT | Same | **DOC STALE vs DEPLOYED** |
| C3 | `ddr_bank_release_select.hpp` HISTORICAL FAULT note | Warns against vsync pack; tip packs swaps | Correct about tip; **fault is LIVE on c5382bee** | **SURVIVES as warning**; silicon still wrong |
| C4 | `fpga_spi.cpp` `diagnosePlxdProvenance` InitOnly/Alive/LiveAdvance | `frames_done==0` / advances | Advances on **vsync**, not swap | **DEGRADED**: still proves core clocking; **cannot** prove swaps; stale detector **misses swap-stuck** (historical fault class) |
| C5 | `fpga_spi.cpp` PLXD stale / `plxdStaleCount_` | stuck `frames_done` | Stuck only if **vsync** stuck | **DEGRADED** — false LIVE if swaps freeze |
| C6 | `media_player.cpp` handoff `frames_done=` log | telemetry | Logs vsync count | **SURVIVES as raw field**; **VOID as swap lag** |
| C7 | `media_player.cpp` `pubSwapDelta_.note(..., brs.frames_done)` | Δfd skip metric | p_dge2≈0.97 | **skip_verdict must be UNSCORED** (fixed T2) |
| C8 | `publish_swap_delta_ledger.hpp` header “PRODUCT swap counter” | design comment | Tip intent | **COMMENT OPTIMISTIC vs c5382bee**; runtime UNSCORED when p_d1&lt;0.5 |
| C9 | `tools/fabric_frames_done_hold_hist.py` | hold via fd edges | Already marked INVALIDATED for hold | **INVALIDATED** (correct) |
| C10 | `tools/analyze_mraudio_handoff.py` P-FDONE | Δframes_done lag as display frames | Counts vsyncs ≈ time/16.7ms, not swaps | **VOID as swap-lag N**; may accidentally track wall time in refreshes |
| C11 | `docs/MILESTONE_AVSYNC_SEEK.md` P-FDONE / N display frames | measure fd lag | Same | **VOID on c5382bee** until new RBF |
| C12 | `docs/residual20_attribution.md` frames_done Spearman | lifetime counter | Vsync lifetime | **REINTERPRET as vsync age**; stop claims of present lag |
| C13 | `tests/unit/test_ddr_playback_bank_select.cpp` | simulates both packs | Explicit historical fault model | **SURVIVES** (test knows both) |
| C14 | `tests/unit/test_c5382bee_frames_done_pack.sh` | freezes pack | Proves (a) | **SURVIVES** |
| C15 | `tests/unit/test_rtl_invariants.py` tip must pack frames_done_d2 | tip source | Tip OK | **SURVIVES** (does not claim silicon) |
| C16 | `tests/unit/test_av_phase_rtl_quanta.cpp` PLXD4=video frames_done | bitfield decode | Decode OK; **semantics** swap-only on tip | **SURVIVES decode**; label swap only post-RBF |
| C17 | `host/libmisterplex/av_phase_rtl_quanta.hpp` hi=(frames_done≪16)\|… | bit layout | Layout OK | **SURVIVES layout** |
| C18 | Bank-select `free_mask`/`disp_bank` | other PLXD fields | Independent of fd pack | **SURVIVES** |
| C19 | O[4] / content_res | N/A | Unused for store geometry | **N/A** — synthesis FRAME macros |

---

## Claims that would have been ERROR-class if published from Δfd

1. **`skip_verdict=NO_ZERO_REFRESH_SKIP` from p_d0=0** — **VOID** on c5382bee (premise Δ∈{0,1} false). Fixed → UNSCORED when p_d1&lt;0.5.
2. **Any “presents from FPGA frames_done”** — **not in product ledger** (presents is ARM). Good.
3. **P-FDONE multi-frame video lag from Δfd** — **VOID** on deployed RBF.
4. **Fabric hold histogram from successive fd edges** — already **INVALIDATED**.

---

## What becomes valid after next RBF (tip pack)

Tip `DDRAM_DIN <= {frames_done_d2, ...}`:
- Δfd ∈ {0,1} under free-gate → skip metric **scorable**
- Provenance Alive ≈ ≥1 swap; LiveAdvance ≈ swaps progressing
- Stale detector can catch swap-stuck again

Until fit: treat PLXD[63:48] on silicon as **`bank_vsync_count` alias**.

---

## O[4] content resolution (related, not fd)

`Plex.sv:226-228` defines `content_res_640x480` / `content_width` / `content_height` from `status[4]`.
`rg` shows **no** consumer wiring them into `present_core` / `ddr_frame_store`.
Store geometry is **`FRAME_W`/`FRAME_H` VERILOG_MACRO** (`Plex.qsf:83-84` = 640/480).
**O[4] is ARM/OSD ABI only for this RBF class — not a runtime DDR geometry switch.**
