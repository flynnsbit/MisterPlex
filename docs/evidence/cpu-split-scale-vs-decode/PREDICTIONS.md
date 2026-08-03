# PREDICTIONS (registered before host Method C run)

Instrument A = live paced product headroom @480p (320 library source suspected).
Instrument B = unpaced FEED probe of **already-624×480** derived H.264.

| ID | Prediction | Why |
|----|------------|-----|
| P1 | On 624×480 native sample, decode_null child_cpu_ms/f **>>** scale-identity delta child_cpu_ms/f | B already showed this (22.9 vs 7.3); host should preserve **direction** (not ARM absolute ms) |
| P2 | On 320×240 sample scaled **up** to 624×480, scale delta child_cpu_ms/f **rises sharply** vs identity scale on 624 | Spatial upscale is the expensive swscale case |
| P3 | format-only path (`-pix_fmt yuv420p` without spatial scale change, or `format=yuv420p`) costs **far less** than 320→624 scale | Format convert ≠ 4× area upscale |
| P4 | Converting B's child CPU to %onecpu_at_24fps still shows decode-dominant on native-624 — **opposite class order from A** | Proves A≠B workload, not arithmetic error in either |
| P5 | Host x86 absolute ms will be **much lower** than DE10; only **ratios** and **ordering** are transferable | Architecture mismatch |

Method C formula (mandatory):
- One wall window per probe: `dwall` from steady_clock around waitpid
- Child CPU from `wait4` rusage (utime+stime)
- `child_cpu_ms_f = 1000 * child_cpu_s / frames`
- `wall_ms_f = 1000 * dwall_s / frames`
- `pct_onecpu_at_fps = 100 * (child_cpu_s / frames) * fps`  (no fps scaling of ticks; fps only maps per-frame CPU to sustained rate)
- Do **not** combine A thread % with B wall ms causally
