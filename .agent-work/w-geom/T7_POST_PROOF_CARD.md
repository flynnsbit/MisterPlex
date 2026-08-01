# T7 post-RBF glass card (parent runs)

**Before bank:** `.agent-work/w-geom/SILICON_V_CEILING_FACT.md` on `c5382bee`.

## Deploy (parent)
1. Fit RBF carrying T7 vertical (`NATIVE_V_1TO1` / V_STORE_SD=480) + `frames_done_d2`
2. ONE menu deploy; verify RBF md5 ≠ banned set
3. Optional: daemon with bank-identity PLXD liveness (`7b6815a3+`)

## Commands (parent; agent does not ssh)
```bash
# Product publish path, codec out:
push_frame --ddr --pattern mid_grey   --hold-ms 8000
push_frame --ddr --pattern even_black --hold-ms 8000
push_frame --ddr --pattern even_white --hold-ms 8000
push_frame --ddr --pattern odd_black  --hold-ms 8000
push_frame --ddr --pattern odd_white  --hold-ms 8000
# Capture each with ffmpeg /dev/video0 → mean/std
```

## PRE-REGISTER (commit before capture)
| Pattern | PASS after T7 | FAIL (still ceiling) |
|---------|---------------|----------------------|
| mid_grey | mean≈137, std≈0 | — |
| even_black | mean low (black), **not** inverted by phase | odd_black solid white |
| even_white | mean high (white) | odd_white solid black |
| odd_black | mean **low** (black) | mean high (inverted) |
| odd_white | mean **high** (white) | mean low (inverted) |

**Hard fail:** any odd_* still solid-inverted vs even_* with std=0.

## Also log
- PLXF underrun Δ (see UNDERRUN_BASELINE.md)
- `plxd_liveness_proven=` and any `[STALE]` with bank-identity text
- Do **not** score skip from frames_done until p_d1 distribution proves swap counter
