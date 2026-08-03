# B13 — Runtime true-DE (w-clock)

**Commit target:** wire `use_rt_geom=1` from `content_w`/`content_h`.  
**No Quartus fit. No device.**

## Product fact (parent N=142)
96.5% of library cannot fill 960×540. PMS never upscales. Fixed 960 DE is wrong.

## Applied
| Item | State |
|------|--------|
| `present_core` ports `content_w`/`content_h` | **ON** |
| Beam `use_rt_geom(1'b1)` + `use_rt_vtotal(1'b1)` | **ON** under `PRESENT_BEAM_960` |
| H_DE/V_ACTIVE | from content (0 → 960×540 fallback); clamp to FRAME max |
| H_TOTAL | **1182** fixed (generous blanking for small DE) |
| V_TOTAL | **564** if content_fps>25 else **705** |
| Latch | frame boundary inside `present_beam_content_de` |
| Plex.sv | wires `present_content_w/h` from ladder (PLXG when w-mem mux merged) |
| PLXG mailbox / mux force-960 | **w-mem ownership** — must prefer live PLXG over force_native_960 |

## Proof (oracle)
Whole-frame equality + line_acc=W..W for:
320×240, **624×480**, 640×360, 960×540 @ 1182×564  
Red twin per geom: drop-one-per-line caught.

## STA / overclock (honest)
| Claim | Status |
|-------|--------|
| V705 sim exact | PROVEN |
| V705 timing close @20 | **UNKNOWN** until `Plex.sta.rpt` — prereg meet 20 MHz |
| Runtime geom Fmax | **UNKNOWN** — structure = 11-bit reg compares; stub Fmax **23.46** → **17%** margin |
| Ship clk ceiling | **20 MHz**; 25 blocked on stub 23.46 |
| Prediction runtime ON nostub-class | expect meet 20; miss → HARD FAIL |

If fit shows Fmax&lt;20 with runtime ON: that is the wall — say so; do not invent BUILD_OK.
