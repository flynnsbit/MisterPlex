# B20 visual two-phase (broader than beam DE)

## rd-duck defect (quoted intent)

Bank+store geometry are atomic only with each other; **beam DE was gated** but
PLXG promote on raw VSync still free-runs mux/window/crop/DAR/fps while store
`app_*` stays old until `swap_pending && pending_ready`. Beam-only `rt_de_apply`
is **insufficient**.

## What w-clock implemented (present_core)

**Two-phase candidate → applied** for all *in-core* visual consumers:

| Consumer | Source after fix |
|----------|------------------|
| Beam H_DE / V_ACTIVE | `app_content_w/h` |
| Cadence + Bresenham film class | `app_content_fps` |
| Window ports (shadowed) | `app_win_*`, `app_content_x0/y0` |
| Epoch / blackout | `app_live_seq` vs `geom_live_seq` |

**Apply qualifier** (same fire as bank swap):

```
visual_geom_apply = !use_frame_store
                 || (swap_pending && store_pending_ready)
                 || idle/legacy (content_w==0 || !geom_enable)
```

**Blackout:** `b20_visual_hold` when live seq ≠ applied seq → OR into
`stat_geom_hold_black` and **force core RGB black** (`visual_force_black`).
ascal `HDMI_BLACKOUT` is size-only; core black covers fps/window mismatch too.

**Store prep intentionally free-runs** candidate `geom_*` into `rt_*` so w-mem
cache prep still sees the pending pitch (do not starve B20 store half).

## RED

- `FAULT_B20_BEAM_FREE_RUN` — beam DE from candidate
- `FAULT_B20_VISUAL_FREE_RUN` — always apply shadows + no hold

## Still open (honest)

| Owner | Gap |
|-------|-----|
| w-mem `present_geom_latch` | Still promotes live at VSync; consumer hold is the mitigation |
| w-osd `Plex.sv` | DAR / `VIDEO_ARX/ARY` may free-run outside present_core |
| Full hierarchy TB | Parent: delay pending_ready past fstart with latch+store+beam |

**B20_CLOSED=false** until DAR path is coordinated and a merged hierarchy test
exists. This commit closes the **present_core visual free-run** half.

## Gates

- `tests/unit/test_b20_visual_two_phase.sh`
- `tests/unit/test_b20_beam_de_hold.sh` (updated structure; beam TB unchanged)
