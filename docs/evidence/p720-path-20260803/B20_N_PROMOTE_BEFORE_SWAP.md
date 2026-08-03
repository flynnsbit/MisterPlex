# B20 N doorbell → N+1 promote before swap (host contract oracle)

**Lane:** w-path (host model only)  
**Tip:** see branch HEAD  
**rd-duck:** store still does `applied_geom_seq_r <= rt_geom_seq` (live) and
freezes only cw/ch/hde/vde; w-clock samples live app_*.

## Host oracle (landed)

`DdrStoreB20CoupleSim` + `b20PromoteBeforeSwapOracle` in `plxg_record.hpp`:

1. **Doorbell accept:** match `expected_plxg_seq` to committed PLXG; freeze
   **full** visual tuple `q0..q5` + `pend_geom_seq` + bank.
2. **Live promote N+1** while pend holds N — pend must not follow live.
3. **`swapApply`:** export pend (bank N / tuple N / seq N), never live N+1.
4. **NEG faulty model** `DdrStoreB20FaultyLiveSeqAtSwap`: labels applied with
   live seq/tuple at swap — oracle requires this mis-label so RTL class is red.

## Scenario

| Step | Live PLXG | Pend | Applied after swap |
|------|-----------|------|--------------------|
| commit N (320 identity) | N | — | — |
| doorbell bank0 exp=N | N | N full tuple | — |
| commit N+1 (426 pad x2) | N+1 | **still N** | — |
| swap_applied | N+1 | — | **bank0 / tuple N / seq N** |
| doorbell bank1 exp=N+1 + swap | N+1 | — | bank1 / 426@x2 / seq N+1 |

## RTL-owed (not path)

| Owner | Requirement |
|-------|-------------|
| **w-mem** | Capture `pend_geom_seq` + full visual tuple at doorbell match (not live at swap). Export on `swap_applied_pulse`. Match `db_plxg_seq` before DMA. |
| **w-clock** | Consume **store-applied** tuple only — never live mux `app_*` at ack. |

## Tests

```
./build/test_fpga_publish_ddr_frame; echo "true rc=$?"
```

Expect `B20_couple+...+N_to_N1_oracle` and rc=0.

## Honest boundary

Host already packs doorbell `[12:0]=expected_plxg_seq` and freezes couple on
publish (`lastPublishCouple`). This commit adds the **store-side contract
oracle** proving N survives N+1 promote-before-swap. Product RTL remains open.
