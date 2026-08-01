# PLXD freeze-blindness (c5382bee daily-driver SAFETY)

## Confirmed from code (host, no device this run)

`arm/misterplexd/fpga_spi.cpp` (pre-fix) set `plxdLivenessProven_ = true` when
`brs.frames_done != plxdLastFramesDone_`, and `[STALE]` only when the counter
stopped. Comment claimed this detects “mailbox never written / residue.”

On **c5382bee** (parent md5-verified device + frozen source): PLXD[63:48] packs
`bank_vsync_count` (increment every vsync). Counter advances with clocks alone.
**Swap freeze ⇒ counter still advances ⇒ [STALE] never fires.**

Tip RTL already documents the class (`ddr_frame_store.sv` pack comment) and packs
`frames_done_d2`. **Daily driver is NOT YET FITTED** with that pack.

## Other defeated checks (same class)

| Check | Trusted signal | Defeated when |
|-------|----------------|---------------|
| Degeneracy / plxdLivenessProven_ | frames_done Δ | vsync-packed fd |
| diagnosePlxdProvenance LiveAdvance | frames_done Δ in 5 ms | same |
| publish_swap_delta NO_ZERO (pre-fix) | p_d0 only | same |
| STALE after proven (fd stop) | fd stop | never stops on vsync pack |

## Signals that still work on c5382bee (ARM interim)

| Signal | Derivation | Detects |
|--------|------------|---------|
| `disp_bank` change / display-ack | PLXD[34] vs last publish | swap/display progress |
| `swap_pending` held across counter ticks | PLXD[35] + fd as **timebase** | swap engine stuck |
| free_eq_disp / bank-select Drop | free/disp identity | stale free / timeout (already) |
| frames_done alone | — | **NOT swap health** |

**Plain answer:** There is **no** ARM-readable true swap counter on c5382bee.
Interim mitigation = treat fd as vsync timebase + detect stuck `swap_pending` /
failed display-ack. Full cure = fitted RBF packing `frames_done_d2`.

## Fix on this branch

- `host/libmisterplex/plxd_liveness.hpp` + `test_plxd_liveness` (RBG cases)
- `fpga_spi.cpp` uses observe; emits `[SWAP_STUCK]` / residue `[STALE]` with
  derivation tags; never equates counter motion to swap_live
- Label≠derivation gate + `docs/PRE_RETRACTION_CHECK.md`
- HISTORICAL note: `c5382bee daily-driver NOT YET FITTED`

```
./build/test_plxd_liveness; echo "true rc=$?"
# case2 VSYNC_PACKED + swap_pending stuck → stuck=1  true rc=0
```
