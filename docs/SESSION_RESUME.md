# MiSTerPlex session resume — 2026-07-25 (avsync + seek)

**Repo:** `/home/shawn/Projects/misterplex`  
**Lab:** `root@192.168.1.183`  
**RBF (tear):** **`1441d409`** — do not thrash  
**Docs:** [`MILESTONE_AVSYNC_SEEK.md`](MILESTONE_AVSYNC_SEEK.md) · [`MILESTONE_VSYNC_PRESENT.md`](MILESTONE_VSYNC_PRESENT.md)

## Snapshot

| Item | Value |
|------|--------|
| **Seek/resume** | **FIXED** — re-resolve universal + skip double `-ss` (commits `4e4ebfb` / `ba7aa89`) |
| **AUDIO_DELAY_MS** | **60** on lab (evidence from baseline median −60 ms); code default still 0 |
| **G-AV2** | **PASS** — HDMI flash↔beep harness n=12 @ delay=0 |
| **G-AV3** | **PASS** — \|median\|=**36.0 ms** n=11 MAD 2.0 @ delay=60; companion d60 −30.5 ms |
| **Trek** | show **40710**; **S1E1 episode 40868** @ ~3:54 (remote `1cdd1b7f…` REACHABLE) |
| **Trekmatch blips** | PMS Movies **9** (1080p24) / **10** (320×240@24) |
| **Open** | **G-AV4** eyes-on/HDMI Trek dialogue only (cast **40868**, seek 234000) |

### What fixed seek

1. Library `seekTo` → re-`doPlay` with new `offsetMs` (fresh universal `offset=` seconds)  
2. No FFmpeg `-ss` when URL already has universal `offset=`  
3. Resume playMedia with non-zero offset works the same path  

### What fixed lipsync (blip)

1. Measure @ `AUDIO_DELAY_MS=0` → median flash↔beep **−60 ms** (audio lead)  
2. Conf **`AUDIO_DELAY_MS=60`** (PCM hold before MrAudio) → remeasure **−36 ms** ≤ 42 ms  
3. No RBF change  

### Re-verify seek

```bash
# After cast of Sync 24fps Blip:
# seekTo offset=12000 → log: seek re-resolve … offset=12 … skip -ss
# timeline time ≈ plant + wall
```

### Next

1. **G-AV4:** cast episode **40868** (not show 40710) via remote PMS; seek 234000 (~3:54); eyes-on dialogue / optional HDMI  
2. Optional residual trim (delay ~96) only from new evidence — not required for G-AV3  
3. RBF `1441d409` leave alone  

### Evidence

- Baseline: `captures/e2e/avsync_trekmatch/avsync_report.txt`  
- G-AV3: `captures/e2e/avsync_trekmatch/avsync_report_delay60.txt` + `avsync_trekmatch_d60/`  
- Agents: `/tmp/misterplex-agent-AV-measure.txt`, `AV-remeasure.txt`, `AV-delay-remeasure.txt`, `AV-trek-probe.txt`  
