# B20 host couple (w-path) + RTL-owed remainder

## Host landed (this branch)

1. `writePlxgRecord` then `kickDdrDoorbell(bank, committedPlxgSeq)` — never bare frame gen.
2. PLXK hi packing (`ddrDoorbellHiCoupled`):
   - `[31]` bank
   - `[30:29]` format
   - `[28:13]` frame_gen
   - `[12:0]` **expected_plxg_seq** (`kDdrDoorbellPlxgSeqMask` / `kPlxgDoorbellSeqFieldMask`)
3. `lastPublishCouple()` snapshots visual tuple `plxg_q[0..5]` + seq + doorbell token from the **same** publish transaction.
4. `PlxgPollerSim` matches reset baseline: first valid = `Baseline`, later seq = `Promote`; same-seq skip (q5-only).

## NOT closed on host alone (w-mem / w-clock)

- `ddram_frame_rd` still exports only start_req/bank — no expected PLXG match.
- Store must **wait/match** doorbell `[12:0]` against committed PLXG before DMA/snapshot.
- `applied_geom_seq` at swap must be the **store doorbell snapshot** seq, not live candidate N+1.
- Lock must cover full visual tuple (win enable/origin/fps/q5), not only cw/ch/hde/vde.
- Product proof needs real `plxg_ddr_poller` RTL, not only `PlxgPollerSim`.

## Honest status

| Piece | Status |
|-------|--------|
| Host PLXG+kick same transaction | DONE |
| Doorbell carries expected PLXG seq | DONE (host pack) |
| Store wait/match before DMA | **RTL-OWED w-mem** |
| applied_seq from doorbell snapshot | **RTL-OWED w-mem** |
| app_* from store snapshot not live | **RTL-OWED w-clock** |

## Modules (parent reporting)

| Unit | ON_MAIN | IN_FILES_QIP |
|------|---------|--------------|
| host couple (`fpga_spi`, `ddr_frame_layout` pack) | no (branch) | n/a |
| `plxg_ddr_poller.sv` | not path-owned | — |
| store match logic | not path-owned | — |
