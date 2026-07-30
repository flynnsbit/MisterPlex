# 720p host/ARM scope

Full evidence report (tables, layout math, device recipes, verdict):

**[`docs/evidence/p720-scope-arm-20260730T170939Z/REPORT.md`](evidence/p720-scope-arm-20260730T170939Z/REPORT.md)**

## Headline (evidence-backed)

| Item | Result |
|---|---|
| Current ABI at `0x30000000` | **720p double-buffer dead** — bank0 stomps fixed mailboxes `0x3007Fxxx` and bitstream ring `0x30100000`/`0x30140000` |
| Physical DRAM for 2×1.32 MiB | Not the limiter; needs **remap** (candidate frame base `0x30180000`) + RBF |
| DDR push @ 24 fps | **Marginal** — project ~29–32 ms `frame_tx` of ~41.7 ms (from 480p 8–11 ms / ~59 MiB/s archive) |
| CPU | **Extrapolation** ~50% onecpu (band 50–80%); not measured |
| Coded size | **1280×720** identity (MB-aligned); do **not** repeat 640-for-624 |
| Default | Unchanged **320×240**; no tier implemented |

Gated on 480p soak PASS + parent map decision + `w-device` D1–D4 measures in the report.
