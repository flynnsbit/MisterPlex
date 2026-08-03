# B20 w-mem residual — still not closed (rd-duck)

**Read-only inspect:** `/home/flynnsbit/Projects/MisterPlex-wt-mem/.../ddr_frame_store.sv`  
**w-clock does not edit that file.**

## MEASURED on w-mem store

### Improved
- Doorbell path can match `db_plxg_seq = db_token[28:16]` to live PLXG low-13
  (`db_geom_coupled`).
- At doorbell accept (~805): snapshots `pend_beam_cw/ch/hde/vde` + pitch `pend_app_*`.
- At bank swap (~818+): promotes `pend_app_*` / `pend_beam_*` into `app_*` when
  `b20_atomic && pend_app_valid`.

### Still broken (rd-duck — confirmed)

**1. Generation labeled from LIVE at swap, not pend**
```
// ~845 (bank swap promote)
applied_geom_seq_r <= rt_geom_seq;   // LIVE
```
Also free-run path ~922: `applied_geom_seq_r <= rt_geom_seq`.

If PLXG N+1 promotes while bank N waits prep/VS, bank+pend geometry **N** is
exported as seq **N+1**.

**Required:** `pend_geom_seq` captured at **doorbell acceptance** (the matched
`db_plxg_seq` / full seq for that request). On swap:
`applied_geom_seq_r <= pend_geom_seq` (never `rt_geom_seq`).

**2. Visual tuple incomplete in pend/app beam export**
Pend/app beam carries cw/ch/hde/vde (+ store pitch/crop/disp).
**Missing for present visual consumers:** win_enable, content x0/y0, fps, DAR
(and any other app_* present_core uses).

**3. w-clock still live (this tip)**
`present_core.sv`: on `visual_geom_apply`, `app_* <= content_*` / `geom_live_seq`
(live mux). Even a perfect store export is unused until w-clock switches.

## Oracle (must fail naive live-seq labeling)

```
1. Doorbell N accepted (bank N, tuple N, seq N snapshotted in pend)
2. Promote PLXG N+1 (live seq advances) BEFORE N reaches swap
3. At N swap: expect disp bank N + visual tuple N + applied_seq N
   NOT applied_seq N+1
4. Then doorbell N+1 → swap: bank N+1 + tuple N+1 + seq N+1
```

Host programs PLXG every frame → N+1 during N prep miss is the **common** case.

## Close criteria (all owners)

| # | Owner | Done when |
|---|-------|-----------|
| M1 | w-mem | `pend_geom_seq <= matched db/full seq` at accept; apply that at swap |
| M2 | w-mem | Full visual tuple in pend (win, x0/y0, fps, DAR, …) + export on `swap_applied_pulse` |
| C1 | w-clock | `app_* <= store_applied_*` only; never live mux on ext path |
| T1 | joint | Hierarchy TB implements oracle above; GREEN product + RED live-seq twin |

**B20_CLOSED=false** until M1∧M2∧C1∧T1.
