# w-geom RTL SOURCE: can the FPGA make the 117.10 ms A/V bimodality?

**Constraint:** source + arithmetic only. NO FIT. NO device.  
**Working core:** `c5382bee` — do not disturb.  
**Report SHA:** see git tip on `w-avsync-hdmi-measure`.

Parent facts (accepted as measured, not re-derived):
- HDMI offset clusters means **−314.35** and **−197.25** ms; sep **117.10** ms; n=8 balanced; interleaved in one daemon life.
- Every daemon session-start field identical across clusters (P5 null). Hold Δ=5 ms (killed).
- Within-cluster spread ~10–15 ms.

---

## Plain answer first

| Q | Answer |
|---|--------|
| 1. FPGA audio two-phase @ ~117 ms? | **NO.** All audio-path phase quanta in-tree are **≤ 0.020833 ms** (one 48 kHz sample) or a **single ~170.667 ms post-reset mute** (not a two-state per play). **Correct negative.** |
| 2. Readable audio phase/FIFO mailbox? | **NOT-FOUND** in DDR map. MrAudio depth only via `/dev/MrAudio` status. **PLXD4 @ 0x300FF12C is the upper half of PLXD (video `frames_done`), not audio.** |
| 3. Video first-present two-state @ 117 ms? | **One-vsync quantum exists** (exact **16.715600 ms** NTSC @ 20 MHz). **3×24 fps content = 125.0 ms is REJECTED** (|125−117.10|=7.9 ms). **7× display frame = 117.009200 ms** matches sep to **0.091 ms**, but **no RTL bistable selects 0 vs 7 frames** — mechanism NOT-FOUND. |
| 4. Eliminate FPGA region? | **Audio RTL region: YES, eliminated as a 117 ms two-state source.** **Video swap: not eliminated; needs `frames_done` lag measurement.** Kernel MrAudio SPI driver still **out of repo**. |

---

## 1. Audio path — every phase quantum from RTL literals

Product heard path (MrAudio, not F2):

```
::write(/dev/MrAudio) → kernel DMA ring → SPI → sys/alsa.sv
  → pcm_l/r → sys/audio_out.sv (mix) → sys/i2s.v → HDMI I2S
```

Core F2 path is **off** product: `Plex.sv:748` `.audio_en(1'b0)`; daemon skips F2 when Mr works.

### 1.1 Clock

| Item | Value | Cite |
|------|------:|------|
| `pll_audio` out | **24.576 MHz** | `sys/pll_audio.v` retrieval `gui_output_clock_frequency0=24.576` |
| `alsa` / `audio_out` `CLK_RATE` | **24576000** | `alsa.sv:24`, `audio_out.sv:24` |
| `AUDIO_RATE` | **48000** | `audio_out.sv:66` |

### 1.2 `alsa.sv` sample CE (drain tick)

```verilog
// alsa.sv:149-153
acc <= acc + 48000 + {hurryup,6'd0};
if(acc >= CLK_RATE) begin
    acc <= acc - CLK_RATE;
    ce_sample <= 1;
end
```

**Arithmetic (hurryup=0):**  
period = `CLK_RATE / 48000` cycles = `24576000/48000 = 512` cycles  
**T_sample = 512 / 24576000 s = 1/48000 s = 0.020833… ms**

Max start-phase uncertainty vs an async ARM release: **one sample = 0.020833 ms** — not 117 ms.

`hurryup` (`alsa.sv:95-103`) adds `{hurryup,6'd0}` = hurryup×64 to the addend → rate 48000…48256 Hz. **Rate bend**, not a start-phase bistable.

### 1.3 `got_first` snap — one-shot, not two-phase 117 ms

```verilog
// alsa.sv:116-119
if(~got_first) begin
    buf_rptr <= buf_wptr;  // discard current queue
    got_first <= 1;
end
```

Cleared only on `reset` (`alsa.sv:86-91`).  
Effect: **variable** discard of whatever is queued at first notice — continuous size, **not** a fixed 117 ms quantum, **not** re-armed each play without alsa reset.

### 1.4 No fill-threshold start

After `got_first`, `rptr!=wptr` immediately schedules RAM read (`alsa.sv:121-127`). **NOT-FOUND:** wait-until-N-ms-buffered state.

### 1.5 `audio_out` post-reset unmute (fixed, reset-only)

```verilog
// audio_out.sv:176-196
if(sample_ce) begin
    if(!dly2[13+sample_rate]) dly2 <= dly2 + 1'd1;
    else a_en2 <= 1;
end
```

`sample_ce` period at `sample_rate=0`: div counts 512 clk @ 24.576 MHz → 48 kHz (`audio_out.sv:138-149`).  
Need `dly2[13]` ⇒ **8192** sample ticks.  
**T_mute = 8192/48000 s = 0.170666… s = 170.666… ms** after **audio_out reset only** (`sys_top.v` `.reset(reset|areset)` on `audio_out`).

- **≠ 117.10 ms** (|170.667−117.10|=53.6 ms).  
- **Not** a per-session A/B two-state unless reset differs between runs (daemon does not log that).

### 1.6 I2S bit/frame phase

`audio_out.sv:66-70,86-94` + `i2s.v:25-48`:  
`CE_RATE = 48000*16*8 = 6144000`; `i2s_ce` half of mclk_ce; 16-bit L/R.  
Stereo frame period = **1/48000 s = 0.020833 ms** (same sample quantum).

### 1.7 F2 `audio_fifo` (NOT product under MrAudio)

`rtl/audio_fifo.sv:11-12` DEPTH=2048 → **2048/48000 s = 42.666… ms** full depth.  
Product: `audio_en=0`, F2 skipped — **not the heard path**.

### 1.8 Q1 verdict

**There is no RTL mechanism in the product audio path whose start phase can take two values separated by ~117 ms.**

Falsify this negative: find an in-tree counter/divider with period ∈ (117.10 ± 5) ms on the MrAudio→I2S path. **None found.**  
If silicon still bimodally delays **first audible sample** by 117 ms with identical `len` trajectory, the cause is **outside** this RTL (kernel driver not in repo, or external HDMI/sink).

---

## 2. Readable audio-side counters / mailboxes

### 2.1 EXISTS (not audio phase)

| What | Where | Notes |
|------|-------|--------|
| MrAudio `rptr/wptr/len/comp` | `/dev/MrAudio` status line | depth; `comp` unused as phase |
| alsa SPI return `{buf_rptr,hurryup,8'h00}` | `alsa.sv:59-60` | to **kernel** only |
| PLXD `frames_done`, `swap_pending`, `disp_bank`, `free_bank_mask` | **0x300FF128** | **VIDEO** bank-release |

### 2.2 PLXD4 @ 0x300FF12C — NOT a separate audio mailbox

RTL packs **one** 64-bit word at `BANK_MAILBOX_PHYS = DOORBELL+0x128` (`ddr_frame_store.sv:27,1041-1049`):

```text
[63:48] frames_done
[47:36] 12'b0
[35]    swap_pending
[34]    disp_bank
[33:32] free_bank_mask
[31:0]  magic "PLXD" = 0x504C5844
```

On a little-endian 32-bit `devmem` view:
- `0x300FF128` → low 32 = magic  
- **`0x300FF12C` → high 32 = `{frames_done[15:0], 12'b0, swap, disp, free}`**

Parent’s “PLXD4 advancing monotonically” is **`frames_done` in the upper half** — video swap count, **not** audio.  
ABI table (`mailbox_abi_spec.hpp:39,53`): offsets end at PLXD `+0x128`; DIAG `+0x120` is SDRAM diag — **NOT-FOUND: audio mailbox**.

### 2.3 Could one be added cheaply?

**Yes, but that is a FIT** (not authorised here). Sketch only: pack `alsa` `buf_rptr`/`len`/`hurryup` into a spare DDR qword on the existing bank-mbox heartbeat — would need RTL+ARM. **Do not implement without exclusive slot.**

### 2.4 Actionable now (no fit)

1. Decode **PLXD high word** already:  
   `frames_done = (devmem 0x300FF12C) >> 16`  
2. MrAudio status `len/rptr` trajectory at open (daemon logs).  
3. **NOT-FOUND** audio phase reg to sample.

---

## 3. Video present phase — quanta, kills, residual

### 3.1 Swap gate (two-state per **display** frame, quantum = 1 frame)

```verilog
// ddr_frame_store.sv:271-284
if (vsync_pulse && swap_pending && pending_ready_s2) begin
    disp_bank <= pending_bank;
    frames_done <= frames_done + 16'd1;
end
```

`vsync_pulse` = `fstart` from `colorbars` (`present_core.sv` ties `.vsync_pulse(fstart)`).

### 3.2 Exact display frame period from RTL

| Constant | Value | Cite |
|----------|------:|------|
| `clk_sys` | **20.0 MHz** | `rtl/pll.v` `gui_output_clock_frequency0=20.0`; `Plex.sv:849` `CLK_VIDEO=clk_sys` |
| `H_LAST` | 637 → **638** clocks/line | `colorbars.sv:39` |
| NTSC scandouble `vc` wrap | **523** → **524** lines | `colorbars.sv:65-66,77-78` |
| `ce_pix` scandouble | 1 (every clk) | `colorbars.sv:51-52` |

**T_disp = 638 × 524 / 20_000_000 s = 334312 / 20e6 s**  
**T_disp = 0.016715600 s = 16.715600 ms**  
**fps = 59.824356 Hz** (not exactly 60).

Same T for progressive NTSC (`ce_pix`÷2, 262 lines): 638×262×2/20e6 = identical.

### 3.3 Hypothesis table vs measured sep **117.10 ms**

| Hypothesis | Predicted sep | \|err\| vs 117.10 | Verdict |
|------------|-------------:|------------------:|---------|
| 1× display frame late | 16.715600 ms | 100.38 ms | **REJECT** as full sep |
| 2× display | 33.431200 | 83.67 | REJECT |
| 3× **content** @ 24 fps | **125.000000** | **7.900** | **REJECT** (parent flag correct; 7.9 ms systematic ≠ cluster noise about a 125 ms truth) |
| 6× display | 100.293600 | 16.81 | REJECT |
| **7× display** | **117.009200** | **0.091** | **Arithmetically compatible**; **mechanism NOT-FOUND** |
| 8× display | 133.724800 | 16.62 | REJECT |
| `a_en2` mute | 170.667 | 53.57 | REJECT as sep |
| `kFeedTarget` 100 ms | 100.0 | 17.1 | REJECT as sep |
| F2 fifo full | 42.667 | 74.43 | REJECT (not product path) |

**Kill “3 content frames” properly:**  
predicted 125.0 − measured 117.10 = **7.9 ms**. Cluster means are defined to 0.01 ms class; a true 125 ms quantum cannot produce a 117.10 ms separation as the inter-cluster gap. **Rejected.**

**Do not adopt “7 display frames” as cause:**  
error is only 0.091 ms (tempting), but RTL has **no** state machine that chooses “wait 0 vs wait 7 vsyncs” at session start. Normal path: once `pending_ready`, next `vsync_pulse` swaps (**0..1** frame = **0..16.7156 ms** uniform-ish). Multi-frame delay requires `pending_ready` false across multiple `fstart`s — a **stall/prep** class, not a clean balanced 4/4 bistable coded in RTL.

### 3.4 Session-constant present lag is still *possible*

Timeline from source:

1. Gate open = first **complete rawvideo frame in ARM** (`media_player.cpp` audio_release) — audio may start.  
2. Publish + doorbell + prep → `pending_ready` → swap on `fstart` → pixels.  
3. Delay (1)→(2) is integer×T_disp after prep ready.

If that integer differed by 7 between clusters and then held, HDMI sep would match.  
**Source does not force that integer to be bimodal at 7.**  
**Measurement must decide.**

### 3.5 Falsifiable prediction (video)

**Pre-register:**

- `t0` = mono at `media: A/V audio_release`  
- `t1` = mono when PLXD `frames_done` first increments after play start  
- `N = round((t1-t0) / 16.715600 ms)`

| Outcome | Interpretation |
|---------|----------------|
| Cluster A and B have **same** N (e.g. both 0 or 1) while HDMI sep stays 117 | **Video present lag is NOT the 117 ms cause** → FPGA video region weakened; look kernel/HDMI/sink |
| Cluster A/B differ by **ΔN ≈ 7** (Δt ≈ 117 ms) | Video present **is** the discriminator; then hunt why prep/swap waits ~7 frames (still need mechanism — may be ARM publish timing vs vsync, still not a coded bistable) |
| ΔN ≈ 1 (16.7 ms) only | Explains a slice of offset, **not** full sep |

Also sample `swap_pending` bit in PLXD high word during wait: stuck 1 for many vsyncs ⇒ prep path.

---

## 4. Region elimination map

```text
                    ┌─ daemon observables ── KILLED (parent P5)
                    │
 ARM write ─────────┼─ kernel MrAudio SPI driver ── NOT IN REPO (open)
                    │
                    ├─ alsa.sv + audio_out + i2s ── ELIMINATED as 117ms two-state
                    │
                    ├─ video swap/present ── OPEN pending frames_done lag test
                    │
                    └─ HDMI scaler/sink/capture ── outside this RTL
```

**Honest negative (audio RTL):** same class as stride-shear negative.  
**Not a claim the bug is “the handoff”** — only that **in-tree audio RTL cannot be the 117 ms bistable.**

---

## 5. Sim note

No sim proposed that claims to reproduce 117 ms bimodality: **no RTL mechanism to RED against.**  
A compile-only “phase TB” would manufacture false confidence.  
If a future audio-phase mailbox is added, TB must RED without it / GREEN with observability — after FIT grant.

---

## 6. Primary citations

- `fpga/Plex_MiSTer/sys/alsa.sv:24,59-60,86-91,95-103,116-127,149-153`  
- `fpga/Plex_MiSTer/sys/audio_out.sv:24,66-70,86-94,138-149,176-196,246-275`  
- `fpga/Plex_MiSTer/sys/i2s.v:25-48`  
- `fpga/Plex_MiSTer/sys/pll_audio.v` (24.576 MHz)  
- `fpga/Plex_MiSTer/sys/sys_top.v` audio_out + alsa instance  
- `fpga/Plex_MiSTer/Plex.sv:748` `audio_en=0`; `:849` `CLK_VIDEO=clk_sys`  
- `fpga/Plex_MiSTer/rtl/pll.v` 20.0 MHz outclk_0  
- `fpga/Plex_MiSTer/rtl/colorbars.sv:39,51-52,65-78`  
- `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv:27,271-284,1041-1049`  
- `fpga/Plex_MiSTer/rtl/audio_fifo.sv:11-12` (F2 only)  
- `host/libmisterplex/mailbox_abi_spec.hpp` PLXD +0x128; no audio mbox  
- `host/libmisterplex/mraudio_status.hpp:4-14,33,149`
