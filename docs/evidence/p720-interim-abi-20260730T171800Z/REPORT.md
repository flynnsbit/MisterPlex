# p720 interim path + O[5:4]/v8 ABI (no fit)

| | |
|--|--|
| **SOURCE_SHA** | `e9a9d766` (worktree at write) · prior scope base `92b8278c` |
| **TS_UTC** | 2026-07-30T17:20:03Z |
| **Lane** | FPGA+host ABI — **no** Quartus / fit / RBF / deploy / device |
| **Related** | `docs/evidence/p720-scope-fpga-20260730T170642Z/` · ARM CPU `docs/evidence/p720-scope-arm-20260730T170939Z/REPORT.md` |

---

## 1. Product name (non-negotiable)

| Say this | Never say this |
|----------|----------------|
| **16:9-framed 480p** | “720p” |
| Widescreen 480p canvas | “720p mode” / “native 720p” |
| Same spatial present as 480p tier | “720p on MiSTerPlex” |

**What the user sees on the interim path**

- **Present store:** still the existing DDR contract — coded **624×480**, presented **640×480** pillar (`ddr_frame_layout_params.svh` / host 480p geometry).
- **Spatial resolution:** **480p-class**, not 1280×720.
- **Framing:** 16:9 sources are **letterboxed inside** that 4:3 canvas by host FFmpeg `scale=…:force_original_aspect_ratio=decrease,pad=624:480:…` (`media_player.cpp` — already on the STREAM=0 path).
- **HDMI signal** may still be 720p/1080p via MiSTer `video_mode` — that is **output mode**, not content pixels (`docs/display-resolution.md`).

If ARM ever decoded 720p and scaled down, that would still be **720p-sourced 16:9-framed 480p**, not native 720p present. ARM scope projects **~276 %onecpu @24 fps** vs **200% ceiling** — full-rate 720p decode is **not** the interim product.

---

## 2. Does anything require an RBF?

| Change | RBF? | Notes |
|--------|------|-------|
| Host FFmpeg letterbox into 624×480 | **No** | Already present |
| OSD/host decode of wider tier field | **No** for host binary | Works on shipping **v7** RBF when bit5=0 |
| Menu text `O[5:4]` + three options + **`v,8`** | **Yes to appear on device** | Staged in `Plex.sv`; Main only sees it after next intentional RBF |
| `VIDEO_AR` Original → 16:9 (`ARX=16,ARY=9`) | **Yes** | Today `Plex.sv:44-46` hardcodes Original → **4:3** |
| RTL `PRESENT_Y` letterbox params | **Yes** | Compile-time in `present_core` / `ddr_frame_layout_params.svh` |
| Host pad letterbox (in-frame) | **No** | Substitute for `PRESENT_Y` |
| Native 1280×720 FRAME_W/H + stride | **Yes** | Deferred exclusive slot |
| Dead `content_width[9:0]` | N/A | Still unused; cannot hold 1280 |

### Decisive answer

**The no-RBF interim path is host-only:** keep the 480p DDR canvas; letterbox 16:9 in software; name it **16:9-framed 480p**.

**Clean ascal 16:9 output AR (no windowboxing of a 4:3 frame on a 16:9 TV) needs an RBF** to change `VIDEO_ARX/ARY`. In-frame letterbox under 4:3 AR is still correct picture content, but a 16:9 TV in “original” may add outer pillars (windowbox). Document that tradeoff; do not claim HDMI AR is fixed without fit.

`PRESENT_Y` RTL is **not** required for interim if host pad supplies top/bottom bars inside coded YUV.

---

## 3. Interim path — exact touchpoints

```
PMS / local file
    → weak ladder videoResolution=624x480  (tier 01 or 10)
    → ffmpeg decode + fps filter
    → scale+pad into coded 624x480 (16:9 → letterbox inside canvas)
    → publish I420 to existing DDR banks (512 KiB stride, doorbell 0x300FF000)
    → ddr_frame_store (shipping RBF) → Template DE ~529×240 → ascal
    → HDMI/VGA per video_mode + VIDEO_AR (still 4:3 Original unless RBF)
```

| Layer | File | Action now |
|-------|------|------------|
| Tier decode | `host/libmisterplex/osd_menu.hpp` | **Done** — O[5:4], policies, honest userLabel |
| Play log | `arm/misterplexd/main.cpp` | **Done** — logs user=, policy=, tier= |
| PMS profiles | `plex_resolve.cpp` | **Unchanged** — still 240p + 480p only (no 1280x720 profile) |
| FFmpeg pad | `media_player.cpp` | **No change required** for letterbox |
| CONF_STR / v8 | `fpga/Plex_MiSTer/Plex.sv` | **Staged** — needs RBF to boot on device |
| Native 720p RTL | layout params, QSF | **Not built** |

### HDMI vs VGA/CRT

| Output | Interim behaviour |
|--------|-------------------|
| HDMI | Higher `video_mode` still scales the **480p canvas**; 16:9 active area is **inside** the frame if source is 16:9 |
| VGA/CRT | Keep mode 5/6; same canvas downscaled; **no** 720p-native CRT timing |
| Letterbox bars | Host YUV pad (black) and/or pillar in RTL present_x — not a second scaler path |

---

## 4. ABI `O[5:4]` + `v,8` (implemented host-side; RTL staged)

| `status[5:4]` | PMS `label` | `userLabel` | `presentPolicy` | Coded W×H |
|--------------:|-------------|-------------|-----------------|----------:|
| `00` | `320x240` | `320x240` | NativeCanvas | 320×240 |
| `01` | `624x480` | `624x480` | NativeCanvas | 624×480 |
| `10` | `624x480` | **`16:9-framed 480p`** | Widescreen480pCanvas | 624×480 |
| `11` | `624x480` | (480p fallback) | NativeCanvas | 624×480 |

- **Default remains 240p** (`00` / power-on zero word).
- **v7 RBF compatibility:** bit5=0 → tiers 00/01 identical to old O[4].
- **`kOsdOwnedMask`:** `0xC3DA` → **`0xC3FA`** (bit5 owned).
- **`v,8`:** Main clears **both** tier bits on CFG upgrade (staged in `Plex.sv`).
- **Never** put `1280x720` in `label` for PMS on this path.

### Stride table (coordinate with ARM — quote only)

| Tier | frame_bytes | bank_stride (align 256 KiB) | doorbell (geom) | Host accept today |
|------|------------:|----------------------------:|-----------------|-------------------|
| 320×240 | 115200 | 0x40000 | 0x3007F000 | yes |
| 624×480 | 449280 | 0x80000 | 0x300FF000 | yes |
| 1280×720 | 1382400 | 0x180000 | 0x302FF000 | **no** — max 640×480 + stride cap; **native path only after RBF+remap** |

Fixed mailboxes stay at `0x3007F1xx` (ARM report). Interim path **does not move** doorbell/stride.

---

## 5. Native 720p RBF (scoped, unbuilt)

Remains as prior FPGA scope: FRAME_W/H, layout params, linebufs (+16 M10K bit-ceil), bank stride, VIDEO_AR 16:9, forbid on-chip 720p DPB. **Not authorised.** Only interesting with FPGA decode or proven ARM reduced-fps — not with current 2 620 cy/MB @240p decoder headroom story.

---

## 6. Tests run (host)

| Command | rc | evidence |
|---------|---:|----------|
| `g++ -std=c++17 … -o build/test_osd_menu … && ./build/test_osd_menu` | **0** | `test_osd_menu: OK` |
| `g++ … test_resolve.cpp plex_resolve.cpp && ./build/test_resolve` | **0** | `test_resolve: OK` |
| `bash tests/unit/test_osd_menu_red.sh` | **0** | RED OK idle + bitrate mutants |

Pre-register: widescreen tier must keep PMS label `624x480` and userLabel without substring `720`.

---

## 7. Recommendation to parent / user

1. **Ship narrative:** optional **16:9-framed 480p** tier — better framing for widescreen titles on the **existing** core, **not** 720p pixels.  
2. **No exclusive fit** for this.  
3. **Host ABI is ready** now; menu third item appears only after a future intentional RBF with staged `v,8`. Until then, conf/`--decode` 480p + natural 16:9 pad already letterboxes.  
4. **VIDEO_AR 16:9** = separate small RBF if windowbox on HDMI bothers users — still not native 720p.
