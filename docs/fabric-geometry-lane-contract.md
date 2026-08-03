# Fabric geometry lane contract (w-scaler / w-clock / w-osd / w-mem)

**Purpose:** four lanes touch geometry. A fit that looks beautiful and is quietly
wrong is the failure mode this pin exists to prevent.  
**Gate:** `tests/unit/test_720p_geometry_lane_agree`  
**Sibling paper:** w-clock `.agent-work/w-clock/H_OWNERSHIP_W_SCALER.md` (`e0f23e5a` era)

---

## Who owns what (truth)

| Concern | Owner | Truth lives in |
|---------|-------|----------------|
| **Glass H/V, blanking, sync, H_DE** | **w-clock** when `PRESENT_MULTI_PIXEL` | `present_beam_ppc` / `present_video_timing_720p` — **H_DE=1280, V=720** |
| **Glass H/V macros OFF** | product Template | `colorbars` — **H_DE=529**, V≈480 (FBAR lock; do not move) |
| **Glass → store map (scale/window)** | **w-scaler** | `present_content_window` — `hc/py` = **beam** coords, `h_de`/`v_de` = DE size |
| **Bank coded/stride/phys READ** | **w-scaler** | `ddr_frame_store` + `ddr_frame_layout_params.svh` / `ddr_frame_layout.hpp` |
| **Bank WRITE / credit / doorbell** | **w-mem** | `fabric_ddr_writer` + Option-C ABI |
| **HDMI idle/chrome canvas** | **w-osd** | `plex_chrome` / FAB_IDLE — target **1280×720** (`kTargetOutW/H`); composites **after ascal** on `clk_hdmi` |

### Assembled multi-pixel path

```
w-clock: glass_x0/y  (H_DE=1280)     ← owns ACTIVE core DE growth
     │
     ▼
w-scaler: present_content_window     ← owns NN map; h_de MUST be 1280 here
     │   content_w/h = bank source (1280×720 native OR PMS 720×404 OR …)
     ▼
w-scaler: ddr_frame_store rd         ← Option-C base/stride when geom ON
     │
     ▼
w-clock: yuv_npx / present_npx       ← consumes qwords (incl. y_q_hi straddle)
     │
     ▼
ascal → HDMI
     │
     ▼
w-osd: FAB_IDLE / chrome             ← HDMI-space canvas; not bank geometry
```

**ACTIVE growth (parent control `ACTIVE=923×717` on `d1b24e0c`):**  
w-scaler bank width alone does **not** grow ACTIVE. Full-raster ACTIVE needs
**w-clock** multi-pixel DE and/or **w-osd** native HDMI canvas. Colour PASS
(`CYAN_PX`) is w-osd only.

---

## Numbers every lane must agree

| Symbol | Value | Notes |
|--------|------:|-------|
| Option-C base | `0x30180000` | inside reserved window |
| Bank stride | `0x180000` | pinned — not pure derive |
| Doorbell | `0x3047F000` | PLXD = +`0x128` |
| Coded / display | **1280×720** | tight Y stride 1280, C 640 |
| I420 bytes | 1 382 400 | U@921600 V@1152000 |
| Product DE | **529×480** | control arm / macros OFF |
| Multi-pixel DE | **1280×720** | w-clock `8003ef89` |
| OSD target | **1280×720** | w-osd chrome/idle |
| PMS deg tier | **720×404** | w-path below maxBR≈3100 — needs fabric scale |
| **Product source (ship)** | **960×540** | ARM decode+copy margin ~10.5 ms; fabric → 1280×720 **output** |
| Product scale | **4/3** non-integer | NN shimmer worst; bilinear V2 preferred on glass |

---

## Source geometry (variable) vs destination (mode)

| Role | Who sets | Examples |
|------|----------|----------|
| **Source** `content_w×content_h` (+ x0/y0) | Host PLXG / integration force | 1280×720 native, **720×404** PMS, 320×240 legacy |
| **Destination** `h_de×v_de` | Matches **glass DE owner** | 529×480 product; **1280×720** multi-pixel |
| **Bank coded/stride** | PLXG geom or `FABRIC_NATIVE_720P_GEOM` | Option-C when coded_w≥1280 |

Under `PRESENT_MULTI_PIXEL` + `use_ext`: window **must** take beam `glass_x0` and
`h_de=1280`. Mapping from colorbars `hc` with H_DE=529 while beam is 1280 is a
**shear/wrong-picture** class — escalate to parent, do not silently pick.

---

## Quality (first fit)

| Macro | Default | Role |
|-------|---------|------|
| (none) NN | ON path | Integration fit — 0 M10K |
| `PRESENT_WINDOW_BILINEAR` | **OFF** | Fracs + `present_bilinear_lerp` landed; tap fetch not auto-wired |

### clk_pix rate (w-clock finding)

Same-clock `clk_pix=clk_sys=20` caps ≈16.16 Hz at CEA totals. True 720p24 needs
**≈29.7 MHz** pixel clock (separate PLL — w-clock). Scaler pixel path is mul+shift
only (no divide on `ce_pix`) → correct at 29.7 and 74.25 class; no 20 MHz assumption.

### Sibling pins (quoted — escalate if drift)

| Lane | File | Pin |
|------|------|-----|
| w-clock | `present_video_timing_720p.sv` | `H_DE_L=1280`, `V_ACTIVE_L=720` |
| w-clock | `present_beam_ppc.sv` defaults | `H_DE=1280`, `V_ACTIVE=720` |
| w-clock | `present_core.sv` macros OFF | `H_DE=10'd529` Template |
| w-osd | `plex_chrome_cmds.hpp` | `kTargetOutW=1280`, `kTargetOutH=720` |
| w-scaler | `ddr_frame_layout.hpp` | Option-C + coded 1280×720 |

Gate encodes the same numbers: `tests/unit/test_720p_geometry_lane_agree.cpp`.

---

## Default OFF

`win_enable=0`, `geom_enable=0`, `FABRIC_NATIVE_720P_GEOM` undefined,
`PRESENT_WINDOW_BILINEAR` undefined → bit-identical legacy 480p path vs control
`d1b24e0c` at reset.
