# Unified RBF + Daemon Research

**Date:** 2026-09-12  
**Scope:** Why multi-RBF today; feasibility of one RBF that switches 240p / 480i / 480p  
**CRT constraint:** Unified RBF must switch **analog VGA native timings** (240p progressive ↔ 480i interlaced ↔ later 480p). HDMI may stay scaler-driven.

---

## Executive answer

| Piece | Status |
|-------|--------|
| **Unified daemon** | Realistic and largely done (`misterplexd.unified`, mode Scripts/TUI) |
| **Unified RBF** | Possible in principle, **not** a drop-in |
| **Near-term product** | **One daemon + Scripts mode picker + separate RBFs** |

A bank-only “unified” core that leaves VGA stuck at one native rate is **not** acceptable for CRT/VGA.

**Bottom line:** Finish daemon/TUI UX now. Treat single-RBF as a later FPGA project that must unify **storage geometry and native analog timing**.

---

## Why separate RBFs today

### Hard FPGA blockers

1. **Frame geometry is synthesized**  
   `FRAME_W` / `FRAME_H` become localparams into `ddram_frame_rd` / `present_core`. OSD content/display selectors pick among **pre-built** paths; they do not resize RAM/addressing.

2. **DDR layouts and doorbells differ**  
   - Default/240p-class: smaller banks, doorbell e.g. `0x3007F000`  
   - 480i host-paint (e36): 1 MiB banks, doorbell `0x301FF000`, coded/presented 720×480 I420  
   - True480 host (e37): doorbell `0x300FF000`, 640×480 presented, different stride  
   Unified RBF needs multi-map mux or one normalized ABI.

3. **Decoder vs host-paint resource split**  
   240p product path uses FPGA H.264 (AU buffer, DPB, MC, deblock).  
   480i/480p product path is **host FFmpeg → DDR I420** (legacy-software).  
   Combining full decoder + large multi-bank present is a fit/timing experiment (SYS85/V13 history: 11802, routing, hold pressure).

4. **True FPGA 480p decode incomplete**  
   Inter/DPB quality, High/CABAC/B rejection, bandwidth not product-ready → host-paint is the 480p product.

### Soft / process

- Mode switcher pairs **RBF + conf + daemon**; RBF does not pick the daemon.
- Allowlists / MD5 prefixes are software policy; better long-term is capability discovery.
- Audio free-run vs armed session is mostly daemon policy (`SESSION_CONTROL`, `AUDIO_DELAY_MS`, av_lock).

---

## Native VGA / CRT (user hard requirement)

### Signal classes

| Mode | Approx H rate | Nature |
|------|---------------|--------|
| 240p | ~15 kHz | Progressive |
| 480i | ~15 kHz | Interlaced fields, half-line / F1 |
| 480p | ~31 kHz | Progressive |

Scandoubler / `forced_scandoubler` **line-doubles**; it does **not** turn 240p into native 480i.

### What exists today

- Core drives `VGA_HS/VS/DE/RGB`, `VGA_SCALER`, `VGA_F1`, `VGA_SL` (`Plex.sv`).
- Non-720p builds typically `VGA_SCALER=0` (native analog); 720p24 forces scaler path for unsuitable native raster.
- `video_mixer` / `video_freak` / `ascal` support mixer, metadata, HDMI scale + some interlace **on the scaler path**.
- Historical gold artifacts are **separate** cores: `Plex_240p15`, `Plex_480i`, `Plex_480p` (see `docs/release-notes-v0.9.0-pre.md`).
- OSD “Content/Display resolution” is **not** proven to retarget PLL/Htotal/Vtotal/interlace for analog.

### What a CRT-capable unified RBF needs

Runtime-selectable **video timing generator**:

1. 240p progressive native  
2. 480i interlaced (field parity, half-line, `VGA_F1`)  
3. Later 480p progressive  
4. HDMI via `ascal` **independent** of VGA native (dual-output: native producer + buffered HDMI consumer)  
5. Safe switches at frame/field boundaries  

No checked-in historical Plex core runtime-switches native 240p↔480i on VGA in one RBF.

---

## Options A–D (revised for CRT)

| Option | Idea | Feasibility | Verdict |
|--------|------|-------------|---------|
| **A** | Full dream: one RBF, runtime geometry + FPGA decode + **native VGA mux** + independent HDMI | High risk / large project | Long-term only |
| **B** | Host-paint multi-bank + **runtime native VGA timing** (no FPGA 480p decode) | Best single-RBF shape; still needs new timing HW | First unified-RBF experiment after ABI cleanup |
| **C** | Max-res FPGA decode + scale down + native VGA switch | Highest risk (decode incomplete + fit) | Premature |
| **D** | Multi-RBF + **one daemon** + Scripts/TUI (CRT-aware labels) | Production-ready now | **Recommended near term** |

### Near-term path (D)

1. Ship only `misterplexd.unified` (aliases as fallback).  
2. TUI: `CRT 240p` / `CRT 480i` / `VGA-HDMI 480p` — each loads matching RBF + conf.  
3. Capability/pairing over filename-only tables over time.  
4. Safe transition: stop play → flush doorbells → swap conf → load RBF → same daemon.  
5. Normalize host frame ABI (base, stride, format, doorbell version) **before** option B.  
6. Option B first milestone: **native timing subsystem alone**, then multi-bank DDR.

Do **not** call bank-unified + VGA-fixed “unified.”

---

## Current lab product (reference)

| Mode | RBF (MD5 prefix) | Path |
|------|------------------|------|
| 240p | `Plex_240p_AU32.rbf` (`4ce24aa9…`) | FPGA H.264 |
| 480i | `Plex_480i_host_audio.rbf` (`56f38fff…`) e36 | Host paint 720×480, free-run ALSA, lipsync |
| 480p host | `Plex_480p_host.rbf` (`9014f49e…`) e37 | Host paint; glass not fully sealed vs 480i |

Daemon: `misterplexd.unified` (`9c057d80…`) — lipsync + chevron idle (`IDLE_SCREEN=logo`).  
Scripts: `/media/fat/Scripts/MiSTerPlex_Mode.sh`, `switch_misterplex_mode.sh`.

---

## Open questions (need fit experiment, not inspection)

1. Fit cost of multi-geometry present + multi-doorbell + timing mux + audio at proven clocks.  
2. One DDR port sustaining host DMA + scanout (+ optional decoder DPB).  
3. Shared vs duplicated PLL/timing for 15 kHz progressive vs interlaced vs 31 kHz.  
4. Capability mailbox without breaking existing doorbell ABI.  
5. Production FPGA 480p decode with real PMS profiles (separate track).

---

## File map

| Topic | Path |
|-------|------|
| Frame params / OSD res | `fpga/Plex_MiSTer/Plex.sv` |
| DDR reader / doorbells | `fpga/Plex_MiSTer/rtl/ddram_frame_rd.sv` |
| Host 480p layout | `host/libmisterplex/ddr_frame_layout.hpp` |
| Mode switcher | `scripts/switch_misterplex_mode.sh`, `scripts/MiSTerPlex_Mode.sh` |
| CRT release notes | `docs/release-notes-v0.9.0-pre.md` |
| Mixer / ascal / freak | `fpga/Plex_MiSTer/sys/video_mixer.sv`, `ascal.vhd`, `video_freak.sv` |
| Deploy bundle | `build/mode-deploy-hq-20260912/` |

---

## Recommendation summary

- **Users today:** Scripts mode picker + one daemon + named RBFs (already deployed).  
- **Engineering next for “one core”:** design runtime **native VGA timing mux** first; then host-paint multi-bank (option B); FPGA decode unification last (C/A).  
- **Do not** schedule a combined decoder+geometry+timing mega-fit as the first step.
