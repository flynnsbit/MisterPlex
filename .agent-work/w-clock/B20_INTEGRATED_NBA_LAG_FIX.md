# B20 integrated app/beam NBA lag fix (rd-duck)

**HEAD_BRANCH=w-clock-bump** (see `git rev-parse` at commit time)  
**B20_CLOSED=false** — PLXG↔bank generation atomic still OPEN (live `content_*`).  
**This fix only:** one-frame DE/bank non-atomic under integrated app-shadow timing.

## Finding (MEASURED — reproduced in TB)

`present_beam_content_de` sets `frame_start <= 1` at `v_wrap` (NBA).  
`visual_swap_ack = frame_start && swap_pending && pending_ready` therefore fires **next** clk (`hc` already 1).

Prior product path:
1. `v_wrap`: beam samples `rt_* = app_*` (OLD) → latches OLD DE for whole new frame; `frame_start` NBA=1  
2. `hc=1`: app_*←NEW, bank←NEW, `b20_visual_hold` cleared (live_seq==app_seq)  
3. **Full frame:** NEW bank under OLD DE (island), not black

`b20_beam_de_hold_tb` is structurally blind: drives candidates into `rt_*` with level `beam_de_apply`, no app-shadow NBA.

## Fix (applied on this branch)

| Piece | Mechanism |
|-------|-----------|
| **A feed-forward** | `b20_swap_armed = ext && swap_pending && pending_ready`; `beam_src = armed ? content_* : app_*` so `v_wrap` latches NEW DE the cycle before fstart ack |
| **B beam ACK hold** | `beam_src_seq` delayed into registered `frame_start` → `beam_disp_seq`; `b20_beam_hold = (beam_disp_seq != app_live_seq)`; OR into `b20_visual_hold` |

RED twins: `FAULT_B20_NO_BEAM_FEEDFORWARD`, `FAULT_B20_NO_BEAM_HOLD`.

## Evidence (Verilator, true rc)

```
./tests/unit/test_b20_integrated_app_beam.sh  → true rc=0
  GREEN_FF:   hde_first=NEW bank=1 island=0 black=0
  GREEN_HOLD: no FF → OLD DE + black_px>0 island=0; next wrap NEW
  RED:        no FF + no beam hold → island_px>0 REPRO_OK
./tests/unit/test_b20_visual_two_phase.sh     → true rc=0
./tests/unit/test_b20_beam_de_hold.sh         → true rc=0
./tests/unit/test_b20_atomic_coupling_open.sh → true rc=0 (still OPEN)
```

## Still OPEN (do not claim B20 closed)

- `app_*` / feed-forward still sample **live** `content_*` / `geom_live_seq` (not store doorbell snapshot)
- w-mem `applied_geom_seq_r <= rt_geom_seq` live residual
- B9 `bank_gen=0` (w-scaler)

## Ladder (modules touched)

| Module | ON_MAIN | IN_QIP | INSTANTIATED | ENABLED | MEASURE_REF |
|--------|---------|--------|--------------|---------|-------------|
| present_core.sv | no (branch) | yes if core in qip | yes | macro-dep | this branch tip |
| present_beam_content_de.sv | no (branch) | via landing | via present_core BEAM_960 | PRESENT_BEAM_960 | this branch tip |

Do not measure dirty shared main; pin a commit.
