# B20 beam DE hold (rd-duck cross-lane hole)

## Hole

w-mem B20 makes **bank + store app_*** atomic at `vsync && swap_pending && pending_ready_s2`.
`present_geom_latch` still promotes PLXG `content_w/h` at frame_boundary, and the beam
used to latch those into `hde_act/vact_act` at **every** `v_wrap`.

If DDR prep delays `pending_ready` past one fstart:

| Domain | State after delayed fstart |
|--------|----------------------------|
| Beam DE | NEW H_DE/V_ACTIVE |
| Store bank/app | OLD |
| Result | island / tear — violates old/new/black |

w-mem's B20 TB instantiates **only** `ddr_frame_store` — cannot see this.

## Fix (w-clock owned)

1. `present_beam_content_de.rt_de_apply` — DE latch gated at v_wrap; V_TOTAL still free (Bresenham).
2. `present_core` product: `beam_de_apply = !use_frame_store || (swap_pending && store_pending_ready) || idle/legacy`.
3. `ddr_frame_store.pending_ready` export (`= pending_ready_s2`) for the swap_fire term.
4. `FAULT_B20_BEAM_FREE_RUN` red twin always applies DE (REPRO island).

## Gate

`tests/unit/test_b20_beam_de_hold.sh` — delays `pending_ready` past one fstart; GREEN holds OLD DE; RED free-run takes NEW.

## Honest scope

- Does not implement w-mem app_* atomicity (already their B20).
- Couples **beam DE** to the **same qualifier** as bank swap.
- Full hierarchy store+latch+beam still for parent/fitgate; this gate proves the beam half with the delayed-ready scenario rd-duck named.
