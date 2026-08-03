# B20 PLXG↔bank atomic coupling — OPEN (rd-duck)

**Status:** BLOCKER · **B20_CLOSED=false** · w-clock alone cannot close  
**Date tip:** f5ee7bbd+  

## Finding (verified on this tree)

### MEASURED — host doorbell has no PLXG identity
`arm/misterplexd/fpga_spi.cpp` `kickDdrDoorbell`:
```
// Pack: [31:0]=magic, high=[31]=bank, [30:29]=format, [28:0]=sequence.
++doorbellSeq_;
const uint32_t seq = doorbellSeq_ & 0x1FFFFFFFu;
```
Sequence is an **independent** `doorbellSeq_` counter. No PLXG `{epoch,seq}` field.

### MEASURED — w-clock app_* samples LIVE mux at swap_ack
`present_core.sv` (~261–302):
```
wire visual_swap_ack = frame_start && swap_pending && store_pending_ready;
...
end else if (visual_geom_apply) begin
    app_content_w <= content_w;   // LIVE present_* inputs
    app_live_seq  <= geom_live_seq;
```
`content_*` / `geom_live_seq` are **current** latch/mux outputs, not a store doorbell snapshot.
If PLXG promotes N+1 between bank prep of N and fstart ack, app_* can take **N+1** with bank **N**.

### MEASURED — this branch’s product store pin list
`ddr_frame_store.sv` (non-`DDR_FRAME_STORE_RUNTIME_GEOM` body on tip) exports
`pending_ready` only among B20 extras — **no** `applied_geom_*` publish bus.
`present_core` **ifdef RUNTIME_GEOM** *expects* `.rt_geom_seq(geom_live_seq)` etc. into the
store (live feed for prep), which is the opposite direction of “store owns the
tuple that must display with this bank.”

### INFERRED (rd-duck; not re-derived here)
- PLXG poller ~512 clk vs doorbell poller ~256 clk → races.
- `ddram_frame_rd` start_req/bank only.
- Path `PlxgPollerSim` ≠ `plxg_ddr_poller` reset baseline — E2E cannot prove reset.

## Required contract (owners)

| Step | Owner | Requirement |
|------|-------|-------------|
| 1 | **w-path** | Doorbell carries expected PLXG `{epoch,seq}` **or** host waits for PLXG-accepted ACK before `kickDdrDoorbell`. |
| 2 | **w-mem** | On doorbell: wait/match expected PLXG seq before DMA/snapshot; snapshot **full** visual tuple (cw/ch/x0/y0/hde/vde/win_en/fps/DAR/crop/display/coded/strides + seq) with the bank; export `store_applied_*` + `applied_seq` + `swap_applied_pulse`. Lock must cover win/fps/origin, not only cw/ch/hde/vde. |
| 3 | **w-clock** | `app_*` loads from **`store_applied_*` on `swap_applied_pulse` / fstart-ack**, never from live `content_*` when ext-store path is active. Hold/black until applied_seq matches the bank being displayed. |
| 4 | **tests** | Hierarchy TB: delay PLXG promote vs doorbell; assert bank N + visual N; mid-gap live N+1 must not paint. Real `plxg_ddr_poller` reset baseline, not first-valid-only sim. |

## What w-clock will NOT do unilaterally
- Invent doorbell high-word bits (ABI; w-path/w-mem).
- Edit `ddr_frame_store.sv` snapshot machine (w-mem).
- Claim B20_CLOSED on fstart-gated live capture (current code).
- Treat combining “live capture at fstart” + “store dims at start” as atomic — **rd-duck: may choose N+1 visual with N bank.**

## w-clock readiness (when w-mem ports land)
Consume (names negotiable with w-mem):
```
store_applied_valid
store_applied_seq[15:0]
store_applied_content_w/h/x0/y0
store_applied_win_enable, win_h_de, win_v_de
store_applied_fps
swap_applied_pulse   // same edge as bank flip
```
`visual_geom_apply` on ext path := `swap_applied_pulse` (or fstart&&matched),  
`app_* <= store_applied_*` (not `content_*`).

## Prior B20 work still valid (narrower scope)
Product polarity, fstart-qualify vs mid-active ready, mode-exit hold, app_win map —
these remain necessary but **insufficient** for generation↔bank atomicity.
