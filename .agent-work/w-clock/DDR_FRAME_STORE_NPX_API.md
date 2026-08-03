# ddr_frame_store N-wide read API (w-clock)

**Landed on w-clock-bump. Default PX_PER_CLK=1 bit-identical scalar path.**

## Ports (always present; leave open if unused)
```
parameter int PX_PER_CLK = 1  // {1,2,4}
output wire [PX_PER_CLK*8-1:0] rd_r_n, rd_g_n, rd_b_n
output wire [PX_PER_CLK-1:0]   rd_lane_valid_n
output wire                    rd_n_valid
```

## Behaviour
| PX_PER_CLK | rd_*_n | Notes |
|-----------:|--------|-------|
| 1 (default) | `assign rd_r_n = rd_r` (etc.) | No extra YUV math; scalar path unchanged |
| 2 or 4 | `yuv_bt601_npx` on commit snapshot of beam Y/U/V qwords + `src_x_r` | +1 cycle vs scalar commit |

## Alignment free lunch
With `src_x0 % PX_PER_CLK == 0` and PPC∈{2,4}, a group never straddles a Y qword
boundary (8 samples). `y_qword_hi` tied off. Odd x0 still unsupported without hi port.

## Product wiring
`present_core` opens the new ports. Does **not** feed `present_npx_path` yet.
Macro `PRESENT_MULTI_PIXEL` still OFF.

## Evidence
- `test_ddr_frame_store_warm_reset.sh` rc=0 (green + red suite)
- `test_ddr_frame_store_scanout_colour.sh` rc=0
- rtl_lint PASS
