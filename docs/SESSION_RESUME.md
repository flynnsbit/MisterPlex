# MiSTerPlex session resume — 2026-07-25 (avsync + seek)

**Repo:** `/home/shawn/Projects/misterplex`  
**Lab:** `root@192.168.1.183`  
**RBF (tear):** **`1441d409`** — do not thrash  
**Docs:** [`MILESTONE_AVSYNC_SEEK.md`](MILESTONE_AVSYNC_SEEK.md) · [`MILESTONE_VSYNC_PRESENT.md`](MILESTONE_VSYNC_PRESENT.md)

## Snapshot

| Item | Value |
|------|--------|
| **Seek/resume** | **FIXED** — re-resolve universal + skip double `-ss` (commits `4e4ebfb` / `ba7aa89`) |
| **AUDIO_DELAY_MS** | **0** (lab measure baseline; no hardcoded lag in code) |
| **G-AV2** | **PASS** — HDMI flash↔beep harness RUN n=12 |
| **G-AV3** | **FAIL** — median **−60 ms** (\|m\|=60 > 42); evidence `captures/e2e/avsync_trekmatch/avsync_report.txt` |
| **Trek title** | `/library/metadata/40710` @ ~3:54 (remote server `1cdd1b7f…`) |
| **Trekmatch blips** | PMS Movies **9** (1080p24) / **10** (320×240@24) |
| **Open** | G-AV3 lipsync (AUDIO_DELAY_MS≈60 conf remeasure); Trek eyes-on **G-AV4** |

### What fixed seek

1. Library `seekTo` → re-`doPlay` with new `offsetMs` (fresh universal `offset=` seconds)  
2. No FFmpeg `-ss` when URL already has universal `offset=`  
3. Resume playMedia with non-zero offset works the same path  

### Re-verify seek

```bash
# After cast of Sync 24fps Blip:
# seekTo offset=12000 → log: seek re-resolve … offset=12 … skip -ss
# timeline time ≈ plant + wall
```

### Next

1. **AV-delay-remeasure (lab):** set `AUDIO_DELAY_MS≈60` conf-only, soft restart, recast RK10, HDMI remeasure — do **not** mark G-AV3 PASS until \|median\| ≤ 42 ms  
2. Cast 40710 via user Web URL; seek to 3:54; eyes-on dialogue (G-AV4)  
3. RBF `1441d409` leave alone
