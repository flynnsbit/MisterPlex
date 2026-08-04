# DDR arbitration contract — decoder/MC client (w-mem)

**Status:** contract + RTL skeleton `ddr_bus_arbiter4.sv` (not product-wired).  
**Owner:** w-mem. w-nostub must not bolt a 5th master onto arbiter3.

## Masters

| ID | Role | Priority | Pattern |
|---:|---|---|---|
| m0 | present / scanout | **highest** hard-RT | line-timed reads; underrun = visible glitch |
| m3 | MC / DPB reference | high, latency-sensitive | many small/scattered reads |
| m2 | bulk frame write / DMA / PLXP | medium | long sequential bursts |
| m1 | stream path | lowest | async_fifo CDC |

## Rules (normative)

1. **No mid-burst revoke.** `wr_lock`/`rd_lock` hold owner until beats complete (same class as arbiter3 / rd-duck NACK).
2. **Burst cap.** Accepted `BURSTCNT` clamped to `MAX_BURST` (default **8**). Bounds every master's hold time.
3. **m0 one-shot steal.** After `Q_MC` (default **4**) accepted m3 beats **or** `Q_BULK` (default **8**) m2 beats while `m0_cmd`, set `m0_pri` and at the next xact boundary grant m0 even if m3/m2 still assert RD/WE.
4. **Idle re-arb order:** m0_cmd → m3_req → m2_req → m1_req.
5. **m1** keeps async_fifo MLAB path (0 M10K measured on arbiter3 analogue).

## Starvation bounds (controller idle; beats of occupancy)

Let `B = MAX_BURST`.

| Master | Worst-case wait to first accept | Notes |
|---|---|---|
| **m0 scanout** | **≤ B accepted beats of current non-m0 burst**, then grant at boundary | **Proven in sim** (`test_ddr_arbiter4_scanout_bound`) with continuous m3 singles + `Q_MC=4`: wait ≤ `B+4` cycles on ideal memory |
| m3 MC | ≤ one m0 slice + one m2 quantum + m1 window | Not hard-RT; size ref-cache for this |
| m2 bulk | under m0+m3 pressure | Throughput class |
| m1 | starved under load | OK for non-RT stream |

### Scanout bound (proof sketch)

- Non-m0 owner cannot accept a new command with `BURSTCNT > B` (clamp).
- Therefore once m0 asserts, current xact finishes in ≤ B data beats, then `m0_pri` (after at most Q_MC prior m3 accepts while m0 waited) steals.
- Visible line time @720p24: `clk_pix=28.8 MHz`, H_TOTAL=1600 → line = 1600/28.8e6 ≈ 55.6 µs.  
  At `clk_ddr=90 MHz`, B=8 beats ≈ 8 cycles issue + memory latency; **line buffer must cover WC m0 wait + DRAM latency**. Linebuf sizing is w-nostub/w-scaler; this contract only caps fabric grant delay.

**NEGATIVE control:** `FAULT_NO_M0_YIELD` with `M3_QUANTUM=255` → m0 wait exceeds bound (REPRO_OK).

## Integration

- Do **not** wire arbiter4 into `Plex.sv` until DPB master exists and counters (`DDR_PERF_COUNTERS`) have a measured baseline.
- Prefer replacing arbiter3 in one step (m0/m1/m2/m3) rather than nesting arbiters.
- Perf counters `owner[1:0]` already encodes 0..3; extend mailbox m3 fields when wired.

## Coordination

| Lane | Need |
|---|---|
| w-nostub | DPB + ref-window cache as **m3** only; max burst ≤ 8; prefer coalesced window fills over 4×4 peeks when possible |
| w-clock | MC address generation must tolerate m0 steals (retry/hold cmd under busy) |
| w-fitgate | conformance must not assume zero MC stall |
