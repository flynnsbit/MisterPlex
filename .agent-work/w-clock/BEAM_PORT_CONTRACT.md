# present_beam_content_de — port contract (COLLISION #7)

**Owner: w-clock.** w-scaler **consumes** this signature; must not trim ports.

| Artifact | Path |
|----------|------|
| JSON | `assets/present_beam_port_contract.json` |
| Gate | `tests/unit/test_beam_port_contract.sh` |
| RTL | `fpga/Plex_MiSTer/rtl/present_beam_content_de.sv` |

## Why these ports exist

Fixed `H_TOTAL=1182` @ 20 MHz → `f_h ≈ 16920.5 Hz` **constant** for every DE width.
`V_TOTAL` 564/705 selects 30.0008 / 24.0007 Hz. DE-tracking HT was quantified and
**rejected** (f_h would swing 16.9→36.9 kHz). `rt_h_total` / `htot_active` carry that
design — a merge that drops them breaks runtime line class and `beam_oracle`
(`PINNOTFOUND rt_h_total` / `htot_active`).

## Runtime ports (load-bearing)

| Port | W | Dir | Frame-latch | Reset | Meaning |
|------|--:|-----|:-----------:|-------|---------|
| `use_rt_vtotal` | 1 | in | no | n/a | enable runtime V_TOTAL |
| `rt_vtotal` | 11 | in | **yes** | n/a | 564 TV / 705 film |
| `use_rt_geom` | 1 | in | no | n/a | enable runtime H/V + HT |
| `rt_h_de` | 11 | in | **yes** | n/a | true-DE width |
| `rt_h_total` | 11 | in | **yes** | n/a | line total (product 1182) |
| `rt_v_active` | 11 | in | **yes** | n/a | true-DE height |
| `hde_active` | 11 | out | **yes** | hde_req | latched W |
| `htot_active` | 11 | out | **yes** | htot_req | latched HT (**must not drop**) |
| `vact_active` | 11 | out | **yes** | vact_req | latched H |
| `vtot_active` | 11 | out | **yes** | vtot_req | latched VT |

Also required: `clk`, `reset`, `ce_pix`, `HBlank`, `HSync`, `VBlank`, `VSync`,
`frame_start`, `hc_out`, `vc_out`.

**Apply rule:** `v_wrap` or `reset` only — mid-frame geometry change forbidden.

## Consumers

- `present_core` BEAM_960 (w-clock)
- oracles / E2E / b15 framecount TBs
- w-scaler true-DE / ascal path — **bind the full port list**
