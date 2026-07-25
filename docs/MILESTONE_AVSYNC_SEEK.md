# Milestone: A/V lipsync baseline + Plex Web seek/resume

**Date:** 2026-07-25  
**Builds on:** vsync present **`1441d409`** / git `588e528` (tear-free — RBF unchanged)  
**ARM:** redeployed `misterplexd` with seek re-resolve + `AUDIO_DELAY_MS`  
**Title SoT:** TNG S1E1 `/library/metadata/40710` (server `1cdd1b7f…`) — dialogue ~3:54  
**Lab conf:** `PRESENT=fpga` `STREAM=0` `DECODE=320x240` **`AUDIO_DELAY_MS=0`**

---

## Problems

1. **Lips out of sync** on MiSTer cast (Trek dialogue) while local Plex is fine.  
2. **Seek + resume from Plex Web cast broken** — only start-from-beginning worked.

---

## What fixed seek / resume

### Root cause

Product cast uses PMS **universal** URLs that already bake `offset=` in **seconds**.  
`MediaPlayer` also applied FFmpeg **`-ss`** with the same offset in **ms→s** → **double-seek** (resume/scrub failed or restarted wrong). Mid-play `seekMs` re-used the **stale** universal URL with only `-ss` (HTTP live transcode does not seek reliably).

### Fix

1. **Re-resolve on library seek** (`main.cpp` `seekAsync`):  
   `seekTo` / step → `doPlay(lastPlay with new offsetMs)` → fresh universal URL with `offset=`.
2. **Skip FFmpeg `-ss` when universal already has `offset=`** (`media_player.cpp` `urlHasUniversalOffset`).  
   Timeline still uses `startMs`; demux starts at PMS offset only.
3. **Unit:** `universalOffsetSeconds(234000)==234` (Trek 3:54).

### Lab evidence (2026-07-25)

| Case | Result |
|------|--------|
| seekTo 12000 mid-play on Sync 24fps Blip | `seek re-resolve … offMs=12000`, URL `offset=12`, `skip -ss`; timeline **playing** ~15.5 s after settle |
| playMedia offset=15000 (resume) | ACK `offMs=15000`, URL `offset=15`, `skip -ss`; timeline **playing** ~19 s after settle |
| Unit `make unit` | PASS including seek re-resolve path in browse smoke |

---

## A/V lipsync (fresh baseline — no hardcoded lag)

### Policy

- **`AUDIO_DELAY_MS=0` by default** — no guessed lag constants.  
- Conf-only intentional PCM hold before MrAudio (positive delays audio vs video).  
- Set from **measured** flash↔beep evidence only.

### Fixtures

| Asset | Class | PMS ratingKey (local Movies) |
|-------|--------|------------------------------|
| `sync_trekmatch_1080p24_blip.mp4` | 1080p24 ~8 Mbps Trek-class source | **9** |
| `sync_trekmatch_320x240_24_blip.mp4` | product twin 1.5 Mbps | **10** |
| existing `sync_{24,30,60}fps_blip.mp4` | product DECODE | 6/7/8 |

Generator: `scripts/gen_avsync_blip.py`  
Flash + 1 kHz beep every 1.0 s + mouth bar + labels.

### Measure status (2026-07-25 HDMI flash↔beep)

| Item | Value |
|------|--------|
| Title | Sync Trekmatch 320×240@24 Blip **RK10** |
| Lab | `PRESENT=fpga` `STREAM=0` `DECODE=320x240` **`AUDIO_DELAY_MS=0`** |
| RBF | `1441d409` (unchanged) |
| Capture | `captures/e2e/avsync_trekmatch/capture_12s.mkv` |
| Report | [`captures/e2e/avsync_trekmatch/avsync_report.txt`](../captures/e2e/avsync_trekmatch/avsync_report.txt) |
| Samples | flashes=12 beeps=12 matches=**n=12** |
| **median_offset_ms** | **−60.0** (audio earlier than flash) |
| mad / mean / range | 1.5 / −59.4 / [−62 … −55] |
| abs_median_le_42ms | **False** |

- **G-AV2 PASS** — harness RUN; flash↔beep method locked with `sample_count=12`.  
- **G-AV3 FAIL** — \|median\| = **60 ms** > 42 ms (≤1 frame @24p). Do **not** invent green.  
- **Next (lab owns):** set conf **`AUDIO_DELAY_MS≈60`** (positive holds PCM → delays audio), soft restart, recast RK10, HDMI remeasure — worker **AV-delay-remeasure**. No non-zero default in code without remeasure PASS (conf-only policy).

### Trek 40710 probe

Local PMS (`4edd44…` / `192.168.1.41`) does **not** host 40710 (lives on Web server `1cdd1b7f…`). Cast from user Plex Web URL still valid; G-AV4 eyes-on when that server is reachable with token.

---

## File map

| Area | Files |
|------|--------|
| Seek | `arm/misterplexd/main.cpp`, `media_player.cpp` |
| Delay conf | `media_player.{cpp,hpp}`, `assets/misterplex.conf.example` |
| Offset helper | `plex_resolve.hpp` `universalOffsetSeconds` |
| Fixtures | `assets/avsync/*trekmatch*`, `scripts/gen_avsync_blip.py` |
| Tests | `tests/unit/test_resolve.cpp` |

---

## Gates

| Gate | Status |
|------|--------|
| G-AV0 AUDIO_DELAY_MS=0 | **PASS** (lab conf + log `delay_ms=0`) |
| G-AV1 Trek-matched blip | **PASS** (assets + PMS 9/10) |
| G-AV2 measure harness | **PASS** (`avsync_report.txt` n=12 flash↔beep) |
| G-AV3 \|median\| ≤ 42 ms | **FAIL** — median **−60 ms** (\|m\|=60 > 42); path `captures/e2e/avsync_trekmatch/avsync_report.txt` |
| G-AV4 Trek 3:54 | **PENDING** (needs 40710 access + seek) |
| G-SEEK1 mid-play seekTo | **PASS** (lab blip evidence) |
| G-SEEK2 resume offset≠0 | **PASS** (lab blip evidence) |
| G-SEEK3 unit | **PASS** (`make unit`) |
| G-REG tear RBF | **PASS** (no RBF change) |

---

## How to re-verify

```bash
# Seek
# cast /library/metadata/6, then:
curl -G 'http://PMS:32400/player/playback/seekTo' --data-urlencode offset=12000 \
  -H 'X-Plex-Target-Client-Identifier: misterplex-183' -H "X-Plex-Token: $TOK"
# log: seek re-resolve … offset=12 … skip -ss
# timeline time ≈ plant + wall

# Resume
curl -G '…/playMedia' --data-urlencode key=/library/metadata/6 --data-urlencode offset=15000 …

# Lipsync (after measure script)
# cast ratingKey 9 or 10; AUDIO_DELAY_MS=0; capture HDMI A/V
```
