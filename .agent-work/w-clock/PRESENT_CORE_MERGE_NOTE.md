# present_core merge note (rd-duck)

w-clock BEAM_960 / B13 / B15 / cadence_display_hz live in **this** tree's
`present_core.sv`.

w-mem `present_core` is an **incompatible** older fixed-beam file plus B16
hold-black outputs. **Do not whole-file-winner** either side.

Manual merge required:
1. Keep w-clock BEAM_960 beam ports, runtime geom, film<=24, cadence_display_hz=core.
2. Keep w-mem B16 hold-black / geom epoch outputs and any latch wiring.
3. Port contract: `assets/present_beam_port_contract.json` — beam ports must survive.
4. DDR swap remains `fstart && swap_pending` (not `advance`) — C1.
