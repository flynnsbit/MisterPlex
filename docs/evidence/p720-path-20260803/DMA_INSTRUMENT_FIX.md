# DMA instrument fix (false 98k fps)

## Incident
Parent ran `--dma-only --duration-s 30` on `172a0111`:
```
pl330_dma_ms_per_frame=0.010 ok_frac=1.000 iters=2950903 sustained_fps=98363
```
⇒ 136 GB/s — ~40× DE10-Nano DDR3 peak (3.2 GB/s). Instrument lie.

## Root cause (code, not guess)
Linux `pl330.c` `_execute_DBGINSN(as_manager=true)` for DMAGO:
```
DBGINST0 = (opcode << 16) | (channel << 24)   // e.g. ch0 ns0 → 0x00A00000
DBGINST1 = program_pc
```
Our code wrote `(channel << 8) | 0xA0` (opcode in low byte). Channel **never left STOPPED**.
Wait loop treated already-stopped as success → microsecond “completions”.
`ok_frac` checked CSR only — never destination bytes.

**Retraction:** prior `chunked ok` / 23.8 ms and 0.010 ms DMA figures are **INVALID**.
They did not prove bytes moved. Route A concurrency remains **unmeasured**.

## Fix (this commit)
1. Linux-correct DMAGO encode (`pl330DbgInst0GoManager`)
2. `ok` requires `saw_executing` then STOPPED (not stopped-from-idle)
3. Content verify: full match on first xfer; sentinel poison + sample/full on loop
4. `INSTRUMENT_FAIL` rc=2 if throughput > 3.2 GB/s ceiling
5. Completion wait is `usleep(100)` only — no tight spin; report `cpu_over_wall`
6. Metrics: `verified_frames` only; pure `transferBlocking` ms separate from loop wall
7. `--bank-sweep` STAND DOWN (parent: awk contamination)

## PRE (parent re-run)
| # | Expect |
|---|--------|
| P1 | `saw_exec=1` + content match **or** honest `never_executed` / `NO_REAL_DMA` |
| P2 | if verified: `dma_ms >= ~0.43` else no triumphant number |
| P3 | `ok_frac` = verified/attempts (content); can be &lt; 1 |
| P4 | `cpu_over_wall` reported; near 1.0 ⇒ wait still on-CPU |
| P5 | impossible throughput ⇒ rc=2 `INSTRUMENT_FAIL` |

```bash
ddr_pl330_ingest_bench --dma-only --duration-s 25 --bank 1
# only if pl330_verdict=VERIFIED_REAL_DMA, pair with decode probe
```
