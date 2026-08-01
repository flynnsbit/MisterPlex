# w-geom SOURCE: FPGA A/V path vs ~117 ms bimodal HDMI offset

**Date:** 2026-07-31  
**Lane:** w-geom (source only — no fit, no device)  
**Main SHA at write:** see `git rev-parse HEAD` on report branch  
**Integ binary (geometry, unrelated to this RCA):** `w-integ-m0-p5-osd` @ `1e01bb0b` md5 `239c6bc7…`

Parent measured: clusters A≈−314 ms / B≈−197 ms (audio LEADS picture), sep≈117 ms;
daemon session-start records IDENTICAL across clusters (P5 null). Hold Δ=5 ms (falsified).

This note answers four source questions. Rule 0: quotes or “unknown”.

---

## 0. Product audio path (what is live)

Product cast uses **MrAudio**, not the Plex core F2 `audio_fifo`:

| Fact | Quote |
|------|--------|
| Daemon target | `media_player.hpp`: “FFmpeg → /dev/fb0 + /dev/MrAudio” |
| F2 skipped when Mr works | `media_player.cpp` (~2059): “F2 SPI skipped when MrAudio works” |
| Core tone/FIFO off | `Plex.sv:748` `.audio_en(1'b0)` |
| Core samples still wired | `Plex.sv` `assign AUDIO_L/R = al/ar_audio` but tone gated off when `has_frame`; FIFO empty ⇒ silence on core leg |
| Heard path | `sys_top.v` `alsa` → `audio_out(.alsa_l/r)` → I2S HDMI |

F2 `audio_fifo` DEPTH=2048 @ 48 kHz ≈ **42.7 ms** (`rtl/audio_fifo.sv:11-12`) is **not** the product drain under MrAudio.

---

## 1. Where daemon observability ENDS

```text
ffmpeg s16le 48k stereo
  → audioPump hold (gate closed) / writePacedChunk (gate open)
  → ::write(/dev/MrAudio)          ← LAST userspace store  [media_player.cpp writePacedChunk]
  → kernel DMA ring 512 KiB          [mraudio_status.hpp:4-14, :33]
  → SPI buf_info → FPGA alsa.sv      [sys/alsa.sv]
  → audio_out mix → i2s → HDMI       [sys/audio_out.sv, sys_top.v]
```

### Last thing the daemon **controls**

1. **Gate:** `audioStartGate_` closed until first complete video frame  
   (`media_player.cpp` ~3442–3448, ~3691–3732). No MrAudio write while gated.
2. **Which bytes** and **software pace** of `::write` after open  
   (`writePacedChunk`: `audioDue` + `feedRateBytesPerSec`).
3. **Ring depth sample** used only to servo feed rate and build `audibleClockMs`  
   (`mraudio_status.hpp:111-117`, `:149` `kFeedTargetBytes = 19200` = **100.0 ms**).

### First things the daemon does **not** control

From `mraudio_status.hpp:4-14` (in-tree driver notes):

- `write()` **never blocks**, never consults `rptr` — copy + wrap.
- Lab: 10 s PCM accepted in 116 ms (submitted ≠ heard).
- **FPGA drain schedule** (when `rptr` advances) is not set by misterplexd.
- HDMI A/V phase vs video scanout is outside the process.

### Observability ceiling (product)

| Signal | Source | Limit |
|--------|--------|--------|
| `audioBytes_` submitted | after `::write` | not heard time |
| `len` / `rptr` / `wptr` | open MrAudio O_RDONLY status line | depth only; ~every 4th chunk |
| `audibleClockMs` | `(written−queued)/192000` | assumes 48 kHz drain; **subtracts** depth ⇒ constant post-write phase cancels |
| `av_drift_ms` | frameIndex vs that clock | **blind** to fixed HDMI offset (parent-measured) |
| PLXD `frames_done` | DDR `0x300FF128` | **video swap count**, not audio |

**Handoff where ARM stops controlling timing:** return from `::write` into the MrAudio ring. After that, timing is kernel SPI + `alsa.sv` NCO + `audio_out` + HDMI.

---

## 2. Can FPGA audio start PHASE be two-valued near 117 ms?

### Mechanisms in `sys/alsa.sv` (product consumer)

**A. `got_first` snap (one-shot after `reset` only)** — `alsa.sv:86-91`, `:116-119`:

```verilog
if(~got_first) begin
    buf_rptr <= buf_wptr;   // discard whatever is currently queued
    got_first <= 1;
end
```

- Fires once when `rptr!=wptr` after alsa `reset`.
- Discard amount = ring contents at first notice — **continuous**, not a fixed 117 ms quantum.
- Does **not** re-arm between plays unless alsa is reset (core reload / audio reset path).
- **Not** a two-state 117 ms phase detector from source alone.

**B. Free-running sample NCO** — `alsa.sv:145-154`, `CLK_RATE=24576000`:

```verilog
acc <= acc + 48000 + {hurryup,6'd0};
if(acc >= CLK_RATE) begin acc <= acc - CLK_RATE; ce_sample <= 1; end
```

| Constant | Value |
|----------|------:|
| Base sample period | **20.833 µs** (1/48000) |
| NCO cycles/sample | 512 |
| Max phase uncertainty vs ARM release | **one sample** (~21 µs), not 117 ms |

**C. `hurryup` rate bend** — `alsa.sv:95-103`: levels 0/1/2/4 from `len` bit thresholds → rate 48000…48256 Hz. **Continuous rate**, not start-phase quantisation.

**D. No fill threshold before drain** after `got_first`: next `rptr!=wptr` issues RAM read immediately (`alsa.sv:121-127`).  
**No** “wait until N ms buffered then start” state machine in this file.

**E. `audio_out` post-reset mute** — `audio_out.sv:176-196`:

- `a_en2` rises after `dly2[13]` @ `sample_ce` ⇒ **8192 samples ≈ 170.7 ms** mute after **audio_out reset only**.
- Single fixed post-reset class, **not** a per-session A/B two-state unless reset differs between runs (not logged by daemon).
- Separation parent needs is **117 ms**, not 171 ms.

### Verdict Q2 (plain)

**The product MrAudio FPGA path (`alsa.sv`) cannot, from its RTL constants, produce a two-state start delay separated by ~117 ms.**

Closest free-running period is **20.8 µs**. Closest one-shot fixed mute is **~171 ms after audio_out reset**, not 117 ms, and not re-armed each play without reset.

This is a **correct negative** of the same class as “no stride shear”: source forbids that shape inside `alsa.sv`.  
It does **not** prove the 117 ms is elsewhere — only that **this** block is not a 117 ms two-phase quantiser.

Residual **unknowns** past this negative (need measurement, not more alsa reading):

- Kernel MrAudio driver start / SPI push timing (source cited as `sound/drivers/MiSTer-audio-spi.c` — **not in this repo**).
- HDMI sink / capture pipeline phase (external).
- Video present lag (Q3).

---

## 3. Video present: persistent whole-frame-multiple offset?

### Swap gate (DDR product path)

`ddr_frame_store.sv:271-284`:

```verilog
if (vsync_pulse && swap_pending && pending_ready_s2) begin
    disp_bank <= pending_bank;
    ...
    frames_done <= frames_done + 16'd1;
end
```

- **1-cycle window** each display frame (`vsync_pulse` = `fstart` from present timing).
- Missing the window defers to the **next** vsync (classic freeze class when `pending_ready` stuck — `9eb1431a`).
- Display rate: `Plex.sv:435` `display_hz = status[2] ? 50 : 60` → **16.667 ms** (NTSC) or **20 ms** (PAL) per chance.

### Numerics vs parent sep (arithmetic only — not a cause claim)

| Quantum | ms |
|---------|---:|
| 1× 60 Hz | 16.667 |
| **7× 60 Hz** | **116.667** |
| Parent A−B sep | **~117.1** |
| 3× 24 fps content | 125.000 |
| 6× 50 Hz | 120.000 |
| `kFeedTargetBytes` | 100.000 |

**7×NTSC frame equals the measured separation within ~0.5 ms.** That is a **numerology flag**, not a finding: **no RTL counter or state machine locks present latency to 7 display frames.**

### Can a **session-constant** multi-frame video lag exist?

**Yes, in principle, for the first picture:**

1. Audio gate opens at **first complete rawvideo frame in ARM** (`media_player.cpp` ~3691–3732) — **before** DDR publish/scanout.
2. Picture appears only after: publish → doorbell → prep (`pending_ready`) → **vsync swap** → beam.
3. Delay from (1) to first `frames_done++` is **integer display frames** once prep is ready (0 if swap on next vsync, +1,+2,… if `pending_ready` late).
4. That integer, if stable after first swap, is a **constant A/V content offset** for the session (audio already running from t=0 content at gate open).

**What source does *not* show:**

- A bistable that prefers specifically **7** frames.
- Cadence (`present_cadence.sv`) gating the bank swap — cadence advances `content_index` for stats; **swap is independent** on every ready doorbell at vsync.
- Steady-state “lose 3 content frames every session start” as a coded policy.

**Honest bound:**  
one-frame late = **16.7 ms** (60 Hz); three content frames = **125 ms**; **seven display frames = 116.7 ms matches sep numerically**.  
Whether silicon ever takes a multi-vsync first present is **unknown — check below**.

OSD `O[9:6]` Video delay (`Plex.sv:70`) is read by the **daemon** as `avOffsetMs_` (ARM pacer), **20 ms steps** — not an FPGA two-state, and not 117 ms.

---

## 4. What would OBSERVE a cluster discriminator?

### A. Already on ARM (use across A/B)

| Measurable | How | Expect if audio-path phase |
|------------|-----|----------------------------|
| `ring_at_open` / `ring_after_first_write` | daemon logs (`rptr/wptr/len`) | differ if start depth/phase differs; **identical ⇒ weakens ring-depth story** (parent trajectory still useful) |
| `held_ms` / `hold_wall_ms` | already | parent: Δ=5 — **killed** |
| Steady `lat_ms` ~100 | servo target | same both clusters by construction |

### B. Video present lag (best on-device discriminator for Q3)

**PLXD bank mailbox — product address:**

- Doorbell `0x300FF000` + `0x128` = **`0x300FF128`**
- Magic `0x504C5844` (“PLXD”) low 32 bits  
  (`mailbox_abi_spec.hpp`, `ddr_frame_store.sv:1033-1049`)

Packed word (FPGA→ARM):

| bits | field |
|------|--------|
| [31:0] | magic PLXD |
| [33:32] | `free_bank_mask` |
| [34] | `disp_bank` |
| [35] | `swap_pending` |
| [63:48] | **`frames_done`** (monotonic **swap** count) |

**Parent check (device-owned):**

```bash
# After cast start, poll PLXD (busybox devmem). STRICT_DEVMEM may block dd;
# devmem 64-bit read of 0x300FF128 if available:
# Decode: magic==PLXD, frames_done = word[63:48]
```

**Prediction to pre-register before measuring:**

- Log wall/`mono_ms` at `A/V audio_release` (daemon already).
- Poll until `frames_done` increments from the pre-play baseline.
- **Δt = t(first frames_done++) − t(audio_release).**

| If Δt clusters at ~0–17 ms both A and B | multi-frame present lag **weak** as 117 ms cause |
| If Δt differs by ~117 ms (e.g. ~0 vs ~7×16.7) between HDMI clusters | **video present** is the discriminator |
| If Δt identical and HDMI still bimodal | present lag **not** the 117 ms; look **past** PLXD (HDMI/sink/capture) or kernel audio |

Also sample `swap_pending` bit[35]: stuck 1 across many vsyncs ⇒ prep/path stall class (should also hurt picture).

### C. Audio FPGA — **no** DDR phase register

- `alsa.sv` exposes `{buf_rptr, hurryup, 8'h00}` on **SPI miso** only (`alsa.sv:59-60`) — consumed by the **kernel** into the MrAudio status line (`rptr`, and whatever it maps from the rest).
- **No** HPS-mapped audio phase / sample-counter mailbox in the Plex DDR map.
- `comp:` on the status line is parsed (`mraudio_status.hpp`) but **not** used as a product phase sensor.
- Core `stat_has_audio` / `audio_underrun` reflect **F2 FIFO**, not MrAudio (`present_core.sv` + `Plex.sv:748 audio_en=0`) — **do not** treat them as MrAudio underrun evidence.

### D. External (already authoritative for lipsync)

`tools/avsync_measure_hdmi.py` — only valid lipsync judge (fleet broadcast).  
Pair with (B) to split “video late” vs “audio early” vs “neither on FPGA”.

### E. Kernel driver (out of tree)

`sound/drivers/MiSTer-audio-spi.c` is **cited** in `mraudio_status.hpp` but **not present** in this repo.  
Unknown without that source: buffer commit points, SPI update rate, whether open() resets FPGA-visible pointers in a two-valued way.  
**Check that would settle it:** read that file on the MiSTer rootfs / linux tree the image was built from.

---

## 5. Summary table for parent

| # | Question | Source answer |
|---|----------|----------------|
| 1 | Observability end | `::write(/dev/MrAudio)`; after that only `len/rptr/wptr` depth, not audible phase |
| 2 | Audio two-state ~117 ms in FPGA? | **NO** in `alsa.sv` — periods 20.8 µs / optional ~171 ms post-reset mute / variable got_first discard. **Correct negative.** |
| 3 | Video multi-frame present offset? | **Possible** (vsync + pending_ready); 1 frame=16.7 ms; **7×60 Hz=116.7 ms matches sep numerically** but **no coded 7-frame bistable**. Measure `frames_done` vs `audio_release`. |
| 4 | Best new observable | **Δ(audio_release → first PLXD frames_done++)** @ `0x300FF128`; plus ring_at_open trajectory; HDMI remains ground truth |

**Do not** use `av_drift_ms` / `clock=av-lock` as PASS.  
**Do not** fit Quartus for this — no RBF change is justified by this analysis alone.

---

## 6. Line index (primary quotes)

- `host/libmisterplex/mraudio_status.hpp:4-14,33,111-117,149`
- `arm/misterplexd/media_player.cpp` `writePacedChunk` `::write`; gate ~3442+; release ~3691+
- `fpga/Plex_MiSTer/sys/alsa.sv:59-60,86-91,95-103,116-127,145-154`
- `fpga/Plex_MiSTer/sys/audio_out.sv:176-196,246-258` (alsa mix)
- `fpga/Plex_MiSTer/sys/sys_top.v` `audio_out` + `alsa` instance
- `fpga/Plex_MiSTer/Plex.sv:37,70,435,748`
- `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv:271-284,1033-1049`
- `fpga/Plex_MiSTer/rtl/audio_fifo.sv:11-12` (F2 only)
- `host/libmisterplex/mailbox_abi_spec.hpp` PLXD offset `0x128`, magic
