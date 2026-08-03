# in_ready / store backpressure (w-clock)

## What present_core does today (quoted)

```systemverilog
// present_core.sv
wire mp_beam_en = ~reset & mp_in_ready & mp_rate_fire;  // or without rate
// beam only advances when mp_in_ready
// store coords registered one cycle on mp_beam_ce
// fstore.rd_active <= mp_de_r
// mp_npx_valid = fs_n_valid | mp_blank_push
// u_mp_npx_path.in_ready(mp_in_ready)
```

`ddr_frame_store` pipelines `rd_active` → `rd_active_r` → `rd_active_d` before
`rd_n_valid` / commit (**~2 store clocks + 1 core reg ≈ 3 sys cycles**).

## Gap (rd-duck)

If `in_ready` falls when the async FIFO is almost full and the store still
completes in-flight reads, a **pulse** `fs_n_valid` with `!in_ready` would drop
pixels (store does not hold valid).

## Mitigation landed in `present_npx_path`

1. **Sys skid (depth 16)** in front of `async_fifo`.
2. `in_ready = !skid_af` with AF at `depth-4` → beam stops with **≥4 free skid
   slots** for in-flight store/blank beats.
3. Hard accept: `skid_accept = in_valid && !skid_full` even if soft `in_ready=0`,
   so a late `fs_n_valid` after beam stall still lands if headroom remains.
4. If skid is hard-full, that is still a drop — should not occur if beam honors
   soft ready and store latency ≤ 4.

## Not yet proven in integrated RTL sim

This lane’s unit TBs drive `in_valid` with ready/valid discipline or one-shot
holes. A **full** `present_core`+`ddr_frame_store` cosim of in-flight under
backpressure is still **open** (needs store model / parent integration TB).
Arithmetic + skid headroom is the current evidence, not a closed integrated proof.

## Beam blank path

`mp_blank_push` only fires on `mp_beam_ce` (already gated by `in_ready`), so blank
groups do not bypass backpressure. DE groups from store can arrive later — skid
is for those.
