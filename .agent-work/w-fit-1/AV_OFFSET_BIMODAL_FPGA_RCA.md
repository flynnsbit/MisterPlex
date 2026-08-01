# A/V offset bimodal (~117 ms) — FPGA/audio path source RCA

**Lane:** w-fit · **branch:** `w-fit-integ-c5382bee-dequant-swap` · **SHA:** see status.txt  
**Constraint:** source analysis only. NO FIT. NO device.  
**Parent finding (binding):** HDMI offset clusters A ≈ −314 ms, B ≈ −197 ms, Δ ≈ **117 ms**;
daemon session-start records IDENTICAL across clusters (P5 null). Audio leads picture.

Labels on every number: **measured** (parent), **quoted** (source), **derived**, **assumed**.

---

## 0. Product audio path (which RTL actually carries PCM)

Daemon product path is **`/dev/MrAudio`**, not the Plex-core F2 `audio_fifo`:

```
arm/misterplexd/media_player.hpp:2-3
// Phase 2 media player: single-process FFmpeg → /dev/fb0 + /dev/MrAudio.
// … FPGA owns scanout … + SPI audio (MrAudio).

arm/misterplexd/media_player.hpp:257
std::string audioDev_ = "/dev/MrAudio";

arm/misterplexd/media_player.cpp:1930-1933
// Drain PCM to MrAudio. …
// F2 SPI skipped when MrAudio works (SPI thrash + no heard benefit).
```

Architecture diagram (`docs/architecture.md:51`):
```
/dev/MrAudio → SPI DMA ring → sys audio mix
```

FPGA chain after the kernel driver (quoted):

| Stage | File:line | Role |
|-------|-----------|------|
| HPS SPI master → `alsa` | `sys_top.v:1619-1655` | Kernel programs ring base/len/wptr over SPI |
| Ring drain + PCM out | `sys/alsa.sv` entire | Reads DDR ring @ ~48 kHz → `pcm_l/r` |
| Mix core+ALSA → I2S | `sys/audio_out.sv:1580-1610,246-276` | `aud_mix_top` adds `linux_audio` (alsa) to core |
| I2S serializer | `sys/i2s.v` | Bit clock / LRCLK / sdata → HDMI pins |
| Core tone/FIFO | `Plex.sv:767` `audio_en(1'b0)`; F2 only if MrAudio missing | **Not on product path when MrAudio works** |

Plex-core `rtl/audio_ingest.sv` + `rtl/audio_fifo.sv` (DEPTH=2048 ≈ **42.7 ms derived** @ 48 kHz) are the **F2 fallback**, not the MrAudio product path.

---

## 1. Where daemon observability ENDS

### ARM still controls / observes

| Observable | Source | Notes |
|------------|--------|-------|
| `write(/dev/MrAudio)` submit | `media_player.cpp:2007-2018` | Non-blocking; **does not mean played** (`mraudio_status.hpp:8-13`) |
| Ring status line `rptr/wptr/len/comp` | Driver open/read; parse `len:` `mraudio_status.hpp:18-22,39-69` | `len` = bytes queued not yet played |
| Servo target | `kFeedTargetBytes = 48000*4/10 = 19200` → **exactly 100.0 ms** (`mraudio_status.hpp:114`; **derived**) |
| Audible clock | `audibleClockMs(written, queued)` `mraudio_status.hpp:76-82` | Video paces off this (`media_player.cpp:3133`) |

### Handoff where ARM stops controlling *timing of audible samples*

After `write()` returns, the next consumer is **kernel MrAudio DMA + FPGA `alsa`**:

```
fpga/Plex_MiSTer/sys/alsa.sv:45-54   // SPI loads {buf_wptr, buf_len, buf_addr} from HPS
fpga/Plex_MiSTer/sys/alsa.sv:59-60   // SPI returns {buf_rptr, hurryup, 8'h00} to HPS
fpga/Plex_MiSTer/sys/alsa.sv:106-141 // free-running drain state machine on clk_audio
fpga/Plex_MiSTer/sys/alsa.sv:145-154 // ce_sample from 48 kHz + hurryup NCO
```

**Exact end of ARM timing authority (quoted):** the byte is in the shared DDR ring and the FPGA `buf_wptr` has been updated via SPI. From that point:

1. `alsa` decides *when* to issue the next DDR read (`ce_sample` NCO, `state` machine).
2. `audio_out` mixes and enables DC-blocker mute ramp.
3. `i2s` serializes on its own bit/LR clock.

The daemon can still **observe** `len` (queued bytes) but cannot force the sample clock phase. That is the handoff.

Parent P5 null is consistent with this: every field the daemon emits is pre-handoff or ring-depth-level; a post-handoff phase that does not change steady-state `len` is invisible there.

---

## 2. Can FPGA audio start PHASE be two-state ~117 ms?

### 2a. Free-running sample NCO — continuous, not two-state

```
alsa.sv:145-154
  acc <= acc + 48000 + {hurryup,6'd0};
  if(acc >= CLK_RATE) begin acc <= acc - CLK_RATE; ce_sample <= 1; end
```

- Period of `ce_sample` ≈ 1/48000 = **20.83 µs derived** (hurryup=0).
- Phase relative to ARM release is continuous over that period.
- **Cannot** quantize start delay into two values 117 ms apart by itself.

### 2b. I2S frame boundary — microseconds

```
i2s.v:36-48  // LRCLK toggles every AUDIO_DW=16 bits
```

Sample/frame period still **20.83 µs derived**. Not 117 ms.

### 2c. `got_first` snap (real one-shot, not 117 ms bimodal)

```
alsa.sv:115-119
  else if(buf_rptr != buf_wptr) begin
    if(~got_first) begin
      buf_rptr <= buf_wptr;   // SNAP rptr to wptr
      got_first <= 1;
    end
```

- On first non-empty observation after `reset`, **discards all PCM already in the ring** and starts from current `wptr`.
- `got_first` clears only on `reset` (`alsa.sv:85-91`).
- **Per-session bimodal only if `alsa.reset` toggles some sessions and not others** — unknown without measuring reset. Even then, the snap removes prefill rather than adding a fixed 117 ms phase; depth after snap depends on subsequent writes.
- **Not a 117 ms period boundary** in the RTL constants.

### 2d. `hurryup` — rate change when deep, not start phase

```
alsa.sv:95-103, 150
  // ramp hurryup from len[] bits; ce_sample += {hurryup,6'd0}
sys_top / SPI out: alsa.sv:60  spi_out <= {buf_rptr, hurryup, 8'h00};
```

Milestone example status line shows `comp: 4` (`docs/MILESTONE_AVSYNC_SEEK.md:494`) which is the driver-facing view of **hurryup**.

Threshold arithmetic (**derived**, pointer unit = 8 bytes = one 64-bit beat, `alsa.sv:62-64,123`):

| condition | min `len` (units) | bytes | time @ 192000 B/s |
|-----------|------------------:|------:|------------------:|
| hurryup≥1 `len[18:14]` | 2^14 = 16384 | 131072 | **~682.7 ms** |
| hurryup≥2 `len[18:16]` | 65536 | 524288 | ~2.73 s (ring-scale) |

Servo holds ~**100 ms** depth (`kFeedTargetBytes`) — **below** hurryup≥1 threshold. In steady product operation hurryup should be 0. Not a 117 ms two-state start phase.

### 2e. `audio_out` post-reset mute ramp — ~171 ms one-shot

```
audio_out.sv:192-196
  if(sample_ce) begin
    if(!dly2[13+sample_rate]) dly2 <= dly2 + 1'd1;
    else a_en2 <= 1;
  end
```

- Needs bit 13 of `dly2` → **8192** `sample_ce` ticks → **8192/48 ≈ 170.7 ms derived** mute after reset (48 kHz path).
- One-shot after reset, not a recurring two-state; magnitude ≠ 117 ms.

### 2f. Verdict on audio-phase hypothesis

**From source: the product MrAudio→alsa→I2S path has no period boundary near 117 ms.**

| Candidate | Period / delay | Near 117 ms? |
|-----------|---------------:|:------------:|
| ce_sample / I2S | 20.8 µs | no |
| audio_fifo (F2 only) | 42.7 ms | no (wrong path) |
| kFeedTargetBytes | 100.0 ms | close but ARM-side & parent-identical across clusters |
| a_en2 mute | 170.7 ms | no (one-shot, wrong size) |
| hurryup thresholds | ≥682 ms | no |
| ring size | 2.73 s | no |

**Plain negative (valuable):** *If* the 117 ms is a pure audio-start phase quantisation inside this FPGA audio RTL, **this source tree does not contain a mechanism that produces it.** A plausible story is not a finding; the constants do not support it.

Residual unknowns (not claimed as mechanisms):
- Kernel `MiSTer-audio-spi.c` is **not in this repo** — unknown whether the driver adds a buffer quantum (check would be: read driver BUFFER_LEN / period on device tree; parent owns device).
- HDMI TX / board-level audio path outside `sys_top` — not in Plex RTL.

---

## 3. Video present side — session-held whole-frame-multiple offset

### 3a. Swap rule (quoted)

```
ddr_frame_store.sv:293-307
  if (vsync_pulse && swap_pending && pending_ready_s2) begin
    disp_bank <= pending_bank;
    …
    frames_done <= frames_done + 16'd1;
    vsync_toggle <= ~vsync_toggle;
  end else if (vsync_pulse) begin
    vsync_toggle <= ~vsync_toggle;   // vsync counted even when swap does not fire
  end
```

- Swap is a **1-cycle window** on `vsync_pulse` with both `swap_pending` and `pending_ready_s2`.
- Missing the window does **not** drop the pending frame forever: `swap_pending` stays 1 until a later vsync succeeds (unless cleared by other paths).
- Each missed display vsync delays first picture by **one display period**.

### 3b. Can a startup miss establish a **session-constant** offset?

**Yes, from source structure (mechanism class, not proven cause of 117 ms):**

1. Audio begins draining on the free-running alsa clock as soon as the ring is non-empty post-`got_first`.
2. Video becomes visible only after first successful swap (`has_frame`, `frames_done` increments).
3. ARM present loop then paces *subsequent* frames to `audibleClockMs` (`media_player.cpp:3133-3140`) — so once locked, frame *N* tracks audio.
4. The **first-picture lag relative to audio start** is baked into the HDMI A/V offset for the whole session if both pipelines then run open-loop locked. That lag is an integer number of **display** vsync periods (plus sub-frame scanout), not content frame periods.

### 3c. Arithmetic vs measured 117 ms

| Quantisation unit | n × period | vs 117 ms (**measured** separation) |
|-------------------|----------:|-------------------------------------|
| Content frame 24.000 fps | 3 × 41.667 = **125.0 ms** | off by ~8 ms |
| Content frame | 2 × 41.667 = **83.3 ms** | off by ~34 ms |
| Display 60 Hz | **7 × 16.667 = 116.67 ms** | **match within 0.4 ms** |
| Display 60 Hz | 6 × 16.667 = 100.0 ms | = feed target, not Δclusters |
| Display 50 Hz | 6 × 20 = 120 ms | close |
| Display 59.94 Hz | 7 × 16.683 ≈ 116.8 ms | match |

**Derived:** 7 display periods @ 60 Hz is the best integer match to the **measured** ~117 ms cluster gap.  
**Not proven:** that display is 60 Hz on the failing runs, or that first-swap miss count differs by 7 between clusters.  
**Unknown — check that settles display Hz:** parent HDMI mode / `display_hz` OSD / modeline for those soaks.

One content frame late (41.7 ms) is **ruled out as the full 117 ms gap** by arithmetic; three content frames (125 ms) is possible but worse match than 7×60 Hz.

### 3d. Interaction with ARM A/V lock

Because video is paced to **audible** audio (`audibleClockMs`), a pure ARM hold/release difference should appear in daemon timestamps — parent measured those **identical** across clusters. That **weakens** "ARM released video on different content times" and **strengthens** "post-doorbell FPGA scanout / first-swap phase" or "something after both handoffs (HDMI stack)".

---

## 4. What would OBSERVE the clusters (parent runs on device)

### 4a. Highest value — already readable, no new RTL

**1. Raw `/dev/MrAudio` status line at high rate around t0** (not only daemon `len` EMA):

```bash
# on device — parent runs
# Example: 200 Hz sample for first 3 s of playback
for i in $(seq 1 600); do
  ts=$(date +%s.%N)
  line=$(dd if=/dev/MrAudio bs=256 count=1 status=none 2>/dev/null)
  echo "$ts $line"
  sleep 0.005
done
```

Parse `rptr`, `wptr`, `len`, **`comp`** (`comp` = hurryup from `alsa.sv:60`).  
**Pre-register:** if audio path distinguishes clusters → `len` or `rptr` phase vs wall differs by ~117 ms·192000 B ≈ **22464 bytes** at matched wall marks.  
**Pre-register null:** lines match within servo noise → audio ring does not carry the cluster (consistent with P5).

**2. PLXD bank mailbox via `devmem` (product doorbell-relative):**

```
doorbell = 0x300FF000          # product 480p YUV (mailbox_abi_spec.hpp:40-41)
PLXD     = doorbell + 0x128    # = 0x300FF128
```

Layout (`mailbox_abi_spec.hpp:93-100`, `ddr_frame_store.sv:1074-1080`):

| bits | field |
|------|--------|
| [31:0] | magic `PLXD` = `0x504C5844` |
| [33:32] | free_bank_mask |
| [34] | disp_bank |
| [35] | swap_pending |
| [63:48] | counter (see packing note below) |

```bash
# read 64-bit LE word (busybox devmem may be 32-bit — read two halves)
devmem 0x300FF128 32    # lo: magic
devmem 0x300FF12C 32    # hi: flags + counter[31:16]
```

**Critical packing note (do not guess which core is live):**
- **This integ tip** packs **real `frames_done` (swaps)** in [63:48] (`ddr_frame_store.sv:1068-1074`).
- **ARM comment claims shipping `c5382bee` packs `bank_vsync_count` instead** (`fpga_spi.hpp:340-343`).
- **Settling check (no guess):** sample [63:48] for 2 s during play; rate ≈ **24/s → swaps**, ≈ **60/s → vsyncs**. Publish which.

**Discriminators (pre-register):**

| Hypothesis | Cluster A (−314) vs B (−197) expectation |
|------------|------------------------------------------|
| H-VSWAP: first swap N vs N+7 display periods late | Wall time from audio-release → first `frames_done` 0→1 (or first `has_frame`) differs by **~117 ms**; steady `len` same |
| H-AUDIO-RING: ring phase | `len` at matched wall differs by ~22464 B; first-swap time same |
| H-HURRYUP: deep-buffer rate | `comp` non-zero differing — unlikely at 100 ms target |
| H-NEITHER (HDMI/board) | PLXD + MrAudio both null across clusters |

**3. Timestamp triad at session start (1 ms resolution):**
- `t_audio_first_write` (daemon already has)
- `t_plxd_frames_done_ge_1` (devmem poll)
- `t_hdmi_offset` (existing instrument)

`t_plxd - t_audio` is the candidate video-side session offset.  
**Pre-register:** mean(A) − mean(B) of that difference ≈ **+117 ms** if video-present quantisation explains the HDMI gap (sign: A is more audio-lead ⇒ picture later ⇒ larger `t_plxd - t_audio`).

### 4b. Core status bits (optional)

```
Plex.sv:909-911  telem_flags include has_frame, has_audio, audio_underrun
Plex.sv:972      status_telem[79:72] = {ddr_busy, swap_pending, slice_qp}
```

Via existing `UIO_GET_STATUS` / PLXS mailbox — useful for `has_frame` rise, but PLXD is the direct swap counter.

### 4c. What is NOT exposed (no address)

- `alsa.got_first`, `alsa.ce_sample` phase, `alsa.buf_rptr` **except** via MrAudio status/`comp`
- `bank_vsync_count` as a **separate** register on tip (only if packed into PLXD[63:48] on c5382bee)
- Core `audio_fifo.wr_level` on product MrAudio path (F2 idle)

---

## 5. Summary for parent

| Question | Answer from source |
|----------|-------------------|
| Where does daemon observability end? | After `write(/dev/MrAudio)`; timing owned by kernel DMA + FPGA `alsa` NCO (`alsa.sv:106-154`). Observe-only: status `len`/`rptr`/`comp`. |
| Audio two-state ~117 ms phase? | **No period near 117 ms in product audio RTL.** Correct negative unless kernel driver (out of tree) adds one. |
| Video two-state session-held offset? | **Structurally yes:** first swap waits for `vsync_pulse && swap_pending && pending_ready_s2`; miss count × display period holds for session. **7×(1/60 s)=116.67 ms** matches measured Δ; **not proven**. |
| Best observable | (1) MrAudio line incl. `comp`; (2) `devmem 0x300FF128/12C` PLXD — time to first counter advance vs audio release; (3) measure counter rate to resolve frames_done vs vsync packing on live `c5382bee`. |

**NO FIT REQUESTED.** No RTL change justified until an observable differs between clusters.

---

## Evidence citations (file:line)

- `host/libmisterplex/mraudio_status.hpp:4-22,29-33,76-82,114`
- `arm/misterplexd/media_player.hpp:2-3,257`
- `arm/misterplexd/media_player.cpp:1930-1945,2007-2085,3133-3140`
- `fpga/Plex_MiSTer/sys/alsa.sv:45-60,85-154`
- `fpga/Plex_MiSTer/sys/audio_out.sv:175-196,246-276`
- `fpga/Plex_MiSTer/sys/i2s.v:36-48`
- `fpga/Plex_MiSTer/sys/sys_top.v:1619-1655`
- `fpga/Plex_MiSTer/Plex.sv:767,878-880,909-911,972`
- `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv:293-309,1064-1080`
- `fpga/Plex_MiSTer/rtl/audio_fifo.sv:9-11` (F2 only; DEPTH=2048)
- `host/libmisterplex/mailbox_abi_spec.hpp:40-41,93-100`
- `arm/misterplexd/fpga_spi.hpp:340-343` (c5382bee packing caveat)
- `docs/architecture.md:51`
- `docs/MILESTONE_AVSYNC_SEEK.md:494-497`
