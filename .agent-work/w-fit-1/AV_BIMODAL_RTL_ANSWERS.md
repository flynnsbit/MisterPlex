# RTL answers — 117.10 ms A/V offset bimodality

**Branch/SHA:** see git · **NO FIT · NO device**  
**Measured separation (parent):** 117.10 ms between cluster means −314.35 and −197.25 (n=8).  
**Within-cluster spread (parent):** ~10–15 ms.  
**Daemon-side:** P5 null (all session-start fields identical across clusters).

Every number below is **quoted** (RTL constant) or **derived** (arithmetic from quoted constants).  
No “~60 Hz” handwave: display period is computed from `clk_sys` × colorbars counters.

---

## Q1 — Can the FPGA audio path start in one of two phases?

### Product path (what actually carries PCM)

| Step | Citation |
|------|----------|
| Daemon device | `arm/misterplexd/media_player.hpp:257` `/dev/MrAudio` |
| F2 core FIFO skipped when MrAudio works | `media_player.cpp:1930-1933` |
| FPGA drain | `fpga/Plex_MiSTer/sys/alsa.sv` |
| Mix + I2S | `sys/audio_out.sv` → `sys/i2s.v` via `sys_top.v:1580-1655` |
| Audio clock | `pll_audio_0002.v:22` **`output_clock_frequency0("24.576000 MHz")`** |
| `alsa` / `audio_out` `CLK_RATE` default | `alsa.sv:24`, `audio_out.sv:24` **`24576000`** |

Core `rtl/audio_fifo.sv` / `audio_ingest.sv` are **F2-only** — not product when MrAudio is up.

### Phase quanta from RTL (exact)

**Sample enable NCO** (`alsa.sv:145-154`):
```systemverilog
acc <= acc + 48000 + {hurryup,6'd0};
if (acc >= CLK_RATE) begin acc <= acc - CLK_RATE; ce_sample <= 1; end
```

| Quantity | Formula | Value |
|----------|---------|------:|
| `CLK_RATE` | quoted | 24 576 000 Hz |
| base step | quoted `48000` | 48000 |
| mean cycles/sample (hurryup=0) | `CLK_RATE/48000` | **512** exact |
| **phase quantum** | `1000/48000` ms | **0.0208333… ms (20.8̅ µs)** |
| hurryup=1 rate | `48000+(1<<6)` | 48064 Hz → 20.8056 µs |
| hurryup=4 rate | `48000+(4<<6)` | 48256 Hz → 20.7228 µs |

**I2S** (`i2s.v:36-48`, `AUDIO_DW=16`): LRCLK toggles every 16 bits; sample period still locked to the 48 kHz domain → **same 20.8̅ µs quantum**, not a larger period.

**`got_first` snap** (`alsa.sv:115-119`): on first non-empty after `reset`, `buf_rptr <= buf_wptr` (discard prefill once). Clears only on `reset` (`alsa.sv:85-91`). **One-shot**, not a recurring two-phase lattice of 117 ms.

**`a_en2` mute ramp** (`audio_out.sv:192-196`): needs `dly2[13]` ⇒ 8192 `sample_ce`  
→ `8192/48000 = 0.1706̅ s = **170.6̅ ms**` one-shot after reset. ≠ 117.10; not two-state across sessions without reset toggling.

**`hurryup` depth thresholds** (`alsa.sv:95-103`): pointer unit = 8 bytes (`[18:3]`).  
`len[18:14]` ⇒ ≥16384 units × 8 = 131072 B → `131072/(48000*4) = **682.6̅ ms**` before hurryup≥1.  
Servo target is 100 ms (`mraudio_status.hpp:114`) — below that threshold.

### Q1 answer (plain)

**No.** There is **no** audio-path state machine in this tree whose start phase is two-valued at a **117 ms** scale.

The only continuous phase variable is the free-running `ce_sample` NCO, quantum **20.8̅ µs** (derived from quoted 24.576 MHz / 48000).  
A two-cluster gap of 117.10 ms would be `117.10 / 0.0208333… ≈ 5620.8` sample periods — not a natural binary of this NCO.

**Falsifiable prediction if this negative is wrong:** raw `/dev/MrAudio` `rptr` (or `len`) at matched wall times differs between clusters by ≈ `117.10e-3 * 192000 ≈ 22483` bytes.  
**Falsify the audio-phase claim:** that difference is absent (parent P5 already points this way).

**NOT-FOUND in-repo:** kernel `MiSTer-audio-spi.c` period/buffer quantum; HDMI TMDS audio packet scheduler inside the ADV7513/board path (below `HDMI_I2S` pins).

---

## Q2 — Readable audio-side counter / mailbox for ARM?

| Observable | How | Citation |
|------------|-----|----------|
| `rptr`, `wptr`, `len`, `comp` | `read(/dev/MrAudio)` status line | Driver formats SPI read; FPGA returns `{buf_rptr, hurryup, 8'h00}` `alsa.sv:60`; `comp` ↔ hurryup (see milestone example `docs/MILESTONE_AVSYNC_SEEK.md:494`) |
| `len` parse | `parseMrAudioQueuedBytes` | `mraudio_status.hpp:39-69` |
| Core `audio_fifo.wr_level` | status telem `has_audio` / underrun only | `Plex.sv:909-911`; **level not in DDR mailbox** |
| Dedicated audio phase / NCO snapshot mailbox | — | **NOT-FOUND** |

**Already working DDR mailboxes (video/bank, not audio phase):**

| Word | Product phys | Fields |
|------|--------------|--------|
| PLXD | `0x300FF000+0x128 = 0x300FF128` | magic, free_mask, disp_bank, swap_pending, **[63:48] counter** (`mailbox_abi_spec.hpp:40-41,93-100`; pack `ddr_frame_store.sv:1074-1080`) |
| PLXD hi | `0x300FF12C` | upper 32 bits (parent PLXD4) |

**Cheap add (design note only — NO FIT authorised):** publish `alsa.buf_rptr` / `ce_sample` phase / `got_first` into a doorbell-relative qword (mirror PLXD). **Not present today.** Until then, MrAudio status line is the audio-side instrument.

**Falsifiable use now:** 1 kHz sample of MrAudio line + PLXD hi across cluster A/B starts. Audio cluster ⇒ `len`/`rptr` delta; video cluster ⇒ first PLXD counter advance time delta; neither ⇒ outside this RTL.

---

## Q3 — Video first-present two-state? Kill “3 content frames”

### Swap window (quoted)

```systemverilog
// ddr_frame_store.sv:293-307
if (vsync_pulse && swap_pending && pending_ready_s2) begin
  disp_bank <= pending_bank;
  frames_done <= frames_done + 16'd1;
  ...
end else if (vsync_pulse) begin
  vsync_toggle <= ~vsync_toggle;  // tick still advances
end
```

`vsync_pulse` = `fstart` = colorbars `frame_start` (`present_core.sv:283`, `colorbars.sv:24,76-79`).

### Display tick period — exact from RTL

| Constant | Source | Value |
|----------|--------|------:|
| `clk_sys` | `rtl/pll/pll_0002.v:46` `output_clock_frequency0("20.000000 MHz")` | 20 000 000 Hz |
| `H_LAST` | `colorbars.sv:39` | 637 ⇒ **638** ce_pix/line |
| NTSC `vc` wrap | `colorbars.sv:65-66` non-SD / SD | 261 / 523 ⇒ **262 / 524** lines |
| `ce_pix` | `colorbars.sv:51-54` | SD: every clk; else every other clk |

**NTSC (status[2]=0 default, `Plex.sv:57,435,759`):**
```
clk_per_frame = V * H * clk_per_ce
              = 262 * 638 * 2     (progressive)
              = 524 * 638 * 1     (scandouble)
              = 334312
T_disp = 334312 / 20e6 = 0.0167156 s = 16.715600 ms
f_disp = 59.824356 Hz
```
(Same T for progressive and scandouble — identical product.)

**PAL (status[2]=1):** `T_disp = 398112/20e6 = 19.905600 ms` (50.237 Hz).

### Hypothesis table vs measured 117.10 ms

| Hypothesis | Period source | n×period | \|err\| vs 117.10 | Verdict |
|------------|---------------|--------:|------------------:|----------|
| 1 content frame @ 24.000 | `1000/24` | 41.6667 | 75.43 | **REJECT** |
| 2 content frames | | 83.3333 | 33.77 | **REJECT** |
| **3 content frames** | | **125.0000** | **7.90** | **REJECT** — err 7.9 ms is same order as within-cluster 10–15 ms; parent correctly flagged; **do not adopt because “close”** |
| 1 display tick NTSC | derived above | 16.7156 | 100.38 | single-tick cannot be the gap |
| 6 display ticks NTSC | | 100.2936 | 16.81 | **REJECT** (err > spread) |
| **7 display ticks NTSC** | | **117.0092** | **0.091** | **numerically compatible** with separation |
| 8 display ticks NTSC | | 133.7248 | 16.62 | **REJECT** |
| 6 display ticks PAL | | 119.4336 | 2.33 | weaker than NTSC×7; needs PAL mode |

### Is first-present “two-state”?

**Precise answer:**

1. **Quantisation exists:** first successful swap is delayed by an **integer number of display ticks** after `swap_pending && pending_ready` become true. That integer is **not** limited to {0,1}; it is ℕ₀. So the mechanism is **multi-state**, not a binary latch.

2. **Session hold:** once `has_frame` and ARM paces further presents to `audibleClockMs` (`media_player.cpp:3133`), a constant first-picture lag relative to audio start can persist for the session. That part is real structure.

3. **Bimodality is NOT explained by the swap window alone.** Nothing in `ddr_frame_store.sv` forces the miss count to take only two values differing by 7. A numerical match of **7 × T_disp ≈ 117.009 ms** to the **gap between clusters** is necessary-compatible with “clusters are first-swap miss counts N and N+7”, but:
   - does not prove it;
   - does not explain why Δn is always 7 rather than 1,2,3…;
   - without that, treating “7 vsync” as the cause is the same class of near-fit error as “3 content frames”.

4. **3 content frames: KILLED** by arithmetic against parent’s own spread criterion (err 7.9 ms ≰ negligible vs 10–15 ms cluster width, and systematically 125 ≠ 117.10).

### Falsifiable video predictions (parent can run)

**H-VDISP7** (clusters = first-swap miss counts differing by 7 NTSC ticks):
- Measure `t1 = time of first PLXD[63:48] advance` (or first `frames_done`/`has_frame`) minus `t0 = audio first audible or first MrAudio write after prefill`.
- **Predict:** mean(t1−t0)_A − mean(t1−t0)_B ∈ { ±117.009 ± ~2 ms }.
- **Predict:** within a cluster, (t1−t0) mod 16.7156 ms concentrates near one residue.
- **Falsify:** (t1−t0) cluster delta ≪ 100 ms or not a multiple of T_disp; or MrAudio `len` differs by ~22 kB instead.

**Packing caveat on live `c5382bee`:** ARM notes PLXD[63:48] may be `bank_vsync_count` not swaps (`fpga_spi.hpp:340-343`). Settling check: rate of hi word >> 16 during play ≈ 24/s → swaps, ≈ 60/s → vsyncs. This integ tip packs real swaps (`ddr_frame_store.sv:1068-1074`).

---

## Q4 — Honest global negative?

| Region | Two-state @ 117 ms in RTL? |
|--------|----------------------------|
| Product audio (MrAudio→alsa→I2S) | **NO** — quantum 20.8̅ µs; no 117 ms boundary |
| Core F2 audio_fifo | N/A on product path; depth 42.7 ms anyway |
| Video bank-swap window | **Integer display-tick delay, multi-state**; 3 content frames **REJECTED**; 7×NTSC tick **numerically fits gap only**, does not by itself produce bimodality |
| HDMI/board below I2S pins | **NOT-FOUND** in this repo |

**Plain statement:**

> There is **no** RTL mechanism in the product **audio** path that starts in one of two phases 117 ms apart.  
> The product **video** path **can** delay first visible frame by k display ticks (T_disp = 16.715600 ms NTSC from quoted 20 MHz and colorbars geometry) and hold that lag for a session, but that is a **ladder**, not a two-state bit — and **3×(1/24 s)=125 ms is rejected** as the cluster separator.  
> A well-cited audio negative **does** eliminate “FPGA audio phase lattice” as the cause class.  
> Video remains a **candidate region only for integer-tick first-swap lag**, and only earns causal status if H-VDISP7 (or similar) is confirmed on silicon by PLXD timing. Until then, the audio **handoff / kernel / HDMI** stack below daemon observability stays equally open.

**NO FIT. No sim proposed** — a TB that does not reproduce the HDMI bimodal would be false confidence (parent lesson). Discriminators are on-device timestamps, not a green unit gate.

---

## Parent command card (device — you run)

```bash
# 1) Classify PLXD[63:48] rate (swaps vs vsyncs) during play
#    read 0x300FF12C (hi) every 50ms for 2s; delta>>16 / 2.0 = Hz

# 2) Per session start:
#    t0 = first MrAudio status with len rising through ~target
#    t1 = first PLXD frames/vsync counter increment after t0
#    log (t1-t0), MrAudio len/rptr/comp, HDMI cluster label

# 3) Pre-register:
#    H-VDISP7:  Δ(t1-t0) across clusters ≈ 117.0±2 ms, len identical
#    H-AUDIO:   Δlen ≈ 22483 B, (t1-t0) identical
#    H-NULL:    both null → leave FPGA RTL region
```
