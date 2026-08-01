# Where daemon observability ENDS on the audio path

**Lane:** w-avsync  
**Branch:** `w-avsync-hdmi-measure`  
**Rule 0:** every claim is CITED (file:line) or NOT-FOUND. No plausible mechanisms.

Parent context: HDMI offset bimodal A≈−314 / B≈−197 ms (sep 117.10 ms, n=8).
Hold, H-RING, origin-record fields, delivery geometry all FALSIFIED as discriminators.

---

## Q1 — Path from daemon handoff to sound (every buffer)

| # | Stage | Depth / phase | ARM-readable at runtime? | Cite |
|---|--------|---------------|--------------------------|------|
| 1 | `writePacedChunk` → `::write(out,…)` into `/dev/MrAudio` | bytes daemon chooses | submitted count `audioBytes_` | `media_player.cpp:2190` (`::write`); last **userspace store** |
| 2 | Kernel DMA ring | **512 KiB** | **YES** via status line `rptr,wptr,len,comp` on O_RDONLY open/read | `mraudio_status.hpp:4-22,33`; parse `mraudio_status.hpp:77-103`; pump sample `media_player.cpp:2020-2052` |
| 3 | Kernel SPI master → FPGA | driver schedule | **PARTIAL** — only what driver puts in status line. Driver source `sound/drivers/MiSTer-audio-spi.c` **NOT-FOUND in this repo** (comment only) | `mraudio_status.hpp:4` |
| 4 | FPGA `alsa` SPI slave latches `buf_info` = `{wptr,len,addr}` | host-published | FPGA→SPI MISO returns `{buf_rptr, hurryup, 8'h00}` every `spi_ss` | `sys/alsa.sv:44-60` |
| 5 | FPGA `alsa` DDR PCM buffer | `buf_len` from SPI; rptr local | rptr reflected in kernel `rptr:` **if** driver maps SPI word that way (format shown in unit strings; **comp↔hurryup mapping NOT-FOUND in-tree**) | `alsa.sv:62-72,116-140`; lab lines in `tests/unit/test_mraudio_status.cpp:32-34` |
| 6 | `alsa` `got_first` snap | one-shot after reset: `rptr←wptr` | **NOT readable** (no status bit) | `alsa.sv:86-91,116-119` |
| 7 | `alsa` sample CE NCO | free-run @ 48000+hurryup vs `CLK_RATE=24576000` | hurryup only if exposed as `comp` — **mapping NOT-FOUND** | `alsa.sv:24,145-154,95-103` |
| 8 | `audio_out` mix `alsa_l/r` + core | filter/`a_en2` mute after **audio_out reset** only | **NOT** session-logged by daemon | `audio_out.sv:176-196,249-273`; wire-up `sys_top.v:1639-1655,1604-1605` |
| 9 | I2S / HDMI audio | PHY | **NOT-FOUND** readable phase register in-tree | `audio_out.sv:96-108` i2s |
| F2 alt | `audio_ingest`→`audio_fifo` DEPTH=2048 (~42 ms @48k) | wr_level, has_audio | `has_audio`/`audio_underrun` via UIO_GET_STATUS flags | `audio_fifo.sv:11-12`; `Plex.sv` telem_flags; `fpga_spi.cpp:2015-2017` |
| F2 use | Product **skips F2 when MrAudio opens** | — | F2 not on product heard path when `wantMr` | `media_player.cpp:2062-2063,2059` comment |

**Daemon control ends at return from `::write` into the ring.**  
**Daemon observability of audio ends at the MrAudio status line (`len` primarily; now full snap logged).**  
Everything after SPI leave (NCO phase, got_first, mix mute, HDMI packet phase) is **not** in any daemon log field parent already proved identical.

`audibleClockMs = (written − queued) / 192000` (`mraudio_status.hpp:111-117`) — subtracts depth, so a **session-constant post-write phase** cancels from the pacer clock (compatibility with blindness; **not** a cause claim).

---

## Q2 — Start anchored to device wakeup / periodic boundary?

| Candidate | Period from source | Bimodal ~117 ms? |
|-----------|-------------------|------------------|
| `alsa` `ce_sample` NCO | `CLK_RATE/48000 = 512` cycles @ 24.576 MHz ⇒ **1/48000 s = 20.833 µs** (`alsa.sv:24,150-153`) | **NO** — max phase uncertainty one sample |
| `hurryup` | rate bend 0..4 (`alsa.sv:95-103`), not a start latch | **NO** as 117 ms quantum |
| `got_first` snap | **event**, not period; discard = whatever queued; re-arms only on `reset` (`alsa.sv:86-91,116-119`) | **NOT** a fixed 117 ms two-state from RTL constants |
| `audio_out` `a_en2` | `dly2` to bit 13 @ `sample_ce` ⇒ **8192 samples ≈ 170.7 ms after reset only** (`audio_out.sv:176-196`) | Fixed post-reset class; **≠117 ms**; not per-play without reset |
| ALSA `buffer_time` 100 ms | **NOT-FOUND** in this path (MrAudio, not ALSA userspace) | Parent already rejected as numerology |
| 7× display frame | T_disp cited elsewhere ~16.7 ms; 7×≈117 ms | **Video** lag candidate; **no RTL bistable 0-vs-7** in audio path (w-geom). Measure `frames_done` |

**Q2 answer:** CITED free-running audio period is **20.833 µs**. **NOT-FOUND** any audio-path period of ~117 ms or a coded two-state start delay of that size. Do not import ALSA defaults.

---

## Q3 — Readable start state not already proven identical?

Parent proved identical: pcm_silence_head, conf_adelay, delivery geom/bytes, identity_skip, desync_risk, MID_STREAM_CHANGE, vf, held_ms (±5), ring **depth** steady ~99–101 ms, audible-clock branch.

**Still readable and NOT proven identical across A/B (until parent greps new logs):**

| Signal | How | Why it could differ while `len` matches |
|--------|-----|----------------------------------------|
| `rptr`, `wptr` absolute | status line | same `len` with different absolute phase |
| `comp` | status line | lab values 0/2/4; SPI packs `hurryup` (`alsa.sv:60`) — **name map NOT-FOUND** |
| `frames_done` (PLXD) | `readBankRelease` / `0x300FF128` | **video** swaps only — lag N frames could be 117/16.7≈7 |
| early `len` trajectory | first chunks | open depth path vs steady 100 ms target |
| `got_first` | — | **NOT readable** |

**Not “nothing readable”** — absolute ring pointers + `frames_done` + early trajectory were the gap. Instrumentation below samples them.

---

## Q4 — Instrumentation (deployable) + falsifiable predictions

**Binary:** `build/arm/misterplexd` md5 `cac2ae439c5478881944fda36dff99cc` (this commit’s arm-plexd).

**New log lines (tag=measured):**
- `media: MrAudio ring_at_open … rptr= wptr= len_B= …` (existing)
- `media: MrAudio ring_after_first_write …` (existing)
- `media: MrAudio handoff_at=audio_release … rptr= wptr= len_B= comp= frames_done=`
- `media: MrAudio handoff_at=first_video_present …`
- `media: MrAudio early_traj chunk=0..15 …` (~320 ms)

### Parent commands (parent owns hardware)

```bash
# After deploy + N casts of rk8 480p with HDMI avsync:
grep -E 'MrAudio (ring_at_open|ring_after_first_write|handoff_at=|early_traj)|median_offset|cluster' /path/to/daemon.log
# Pair by run: extract rptr,wptr,len_B,frames_done at handoff_at=audio_release and first_video_present
```

### Pre-registered meanings

| Observation | Means |
|-------------|--------|
| A vs B: `rptr` (or `wptr`) differs by **≈22464 B** (±20%) at `audio_release` or `first_video_present` while `len_B` within ~5 ms | ring **phase** tracks cluster (117 ms × 192000 B/s = 22464 B). Mechanism still may be upstream of rptr. |
| A vs B: all rptr/wptr/len/comp/early_traj **identical** within instrument noise, HDMI sep stays 117 | **kill** MrAudio-visible ring state as discriminator; next is kernel-not-in-repo or post-SPI (HDMI/grabber) / video `frames_done` lag |
| A vs B: `frames_done` delta (release→first present or first frames_done++) differs by **6–8** | video multi-frame present lag candidate (7×~16.7≈117). **Falsifier:** delta identical across clusters |
| `early_traj` len curves parallel, offset constant ≠ 22464 B | steady servo depth; not a one-quantum phase step at start |
| `comp` differs systematically A vs B | possible hurryup/SPI word difference — still needs driver map |

**Wrong if:** any claim that `av_drift_ms` or steady `lat_ms≈100` separates clusters (already measured false).

---

## Held PCM / origin rebase (still required)

| Q | Answer | Cite |
|---|--------|------|
| Held PCM from content t=0 after release? | **Yes** when gate held: dump `holdBuf` from begin; `audio_bytes_at_release` must be 0 (`checkAudioReleaseOrigin`) | release log path `media_player.cpp` audio_release; hold dump before live reads |
| Origin ever rebased mid-play? | **No** steady-state rebase of content origin; gate opens once per play; seek/new play resets | av_clock / gate sites (prior hold trace) |

Hold duration is **not** the 117 ms cluster discriminator (parent Δheld_ms=5).

---

## Plain summary

1. **Observability ends** at MrAudio status (`rptr/wptr/len/comp`) after `::write`. FPGA drain NCO, `got_first`, mix mute, HDMI phase are past that wall.  
2. **No cited ~117 ms audio period**; cited sample period is **20.833 µs**.  
3. **Readable leftover:** absolute `rptr/wptr`, `comp`, `frames_done`, early trajectory — now logged.  
4. **Cheapest falsifier:** parent A/B grep of `handoff_at=` + `early_traj` vs HDMI cluster label.

---

## Parent update absorbed: SESSION-LATCHED (2026-07-31)

Three captures inside one 360 s session: medians −293.33 / −296.00 / −292.67 (spread 3.33 ms).  
Between-cluster sep ~117 ms. **Device defect confirmed; instrument confounds killed.**

Analyzer: `tools/analyze_mraudio_handoff.py` scores P-RPTR and P-FDONE on handoff logs.
