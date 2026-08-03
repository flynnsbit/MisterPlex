# Pre-reg: distribution + threads (before measure)

Parent challenge: 34.50−0.9=33.58 vs 33.333 (−0.25) may be noise / wrong statistic.

| id | prediction |
|----|------------|
| **P-p99** | p99 of per-frame wall on decode+raw path exceeds mean by **>0.25 ms** (IDR spikes) — FAIL/PASS on mean alone is unsafe both ways |
| **P-var** | Repeated full-run means scatter by **≥0.25 ms** device-class equivalent OR host run-to-run CV makes −0.25 inconclusive |
| **P-idr** | IDR/key frames cost **≥1.5×** median P-frame on null-decode wall |
| **P-pipe** | Product pipe between ffmpeg stdout and reader is **OS pipe (~64 KiB default) + optional enlarge**; holds **≪ 1 full 777600 B frame** unless enlarged — little jitter absorption for full frames |
| **P-thr-now** | `:3219` child **already multi-core** under default (no `-threads`) — pct of 1c ≫ 100% |
| **P-thr-help** | Explicit `-threads 2` does **not** beat default mean; may not shrink p99 much either |
| **P-thr-pipe** | Threading helps decode, **not** pipe/copy portion of 34.50 |

Parent pre-reg (quoted): p99 exceeds mean by >0.25 ms; threads help decode not pipe write.
