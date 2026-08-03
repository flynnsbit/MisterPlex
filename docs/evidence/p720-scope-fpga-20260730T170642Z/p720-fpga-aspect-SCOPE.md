# p720 FPGA + aspect scope (`p720-scope-fpga`, `p720-aspect`)

| | |
|--|--|
| **SOURCE_SHA** | `92b8278c219aacc1d01e96b0b18343bd77190b9f` (`92b8278c`) |
| **Date (UTC)** | 2026-07-30T17:10:08Z |
| **Lane** | FPGA scoping — **READ-ONLY** (no Quartus / map / fit / RBF / deploy / device) |
| **Baseline fit** | Live product RBF `14eaeff3` — ALMs 21021/41910 (50%), DSP 74/112 (66%), **RAM blocks 465/553 (84%) → 88 free** (`.agent-work/integ-wiring/product-wire6-EVIDENCE.txt:1-5`) |
| **Verdict** | **720p needs a new intentional RBF (exclusive slot). Do not authorize that slot for 720p until 480p A/V soak is green and M10K/address/layout work is designed.** Prefer **host 720p → present into existing 480p/240p canvas** as an interim if HDMI detail is wanted without exclusive fit. |

---

## 0. Pre-registered predictions (before re-read)

| ID | Prediction | Result |
|----|------------|--------|
| P1 | `FRAME_W`/`FRAME_H` are elaborate-time only; 1280×720 cannot be selected at runtime on current RBF | **HIT** — QSF macros + parameters; `content_width` is dead |
| P2 | O[5:4] FPS comment is stale; only `status[4]` is content-res | **HIT** — code + `osd_menu.hpp` |
| P3 | Line buffers dominate width-scaled M10K; Δ at 1280 may be tens of blocks, not hundreds | **HIT on formula**; **physical Δ unknown without fit** |
| P4 | Pillarbox RTL generalises to letterbox via `PRESENT_Y` | **HIT** — `rd_visible` already 2-D |
| P5 | On-chip DPB at 1280×720 is impossible | **HIT on arithmetic**; product already cannot hold full dual I420 at 640 in 88 free blocks |

---

## A. Frame-store and geometry

### A.1 Compile-time vs runtime (quoted)

| Symbol | Where | Value / behaviour |
|--------|-------|-------------------|
| `FRAME_W` / `FRAME_H` | `Plex.qsf:83-84` | **`640` / `480`** macros |
| defaults | `Plex.sv:262-269` | 320/240 if macros absent |
| `DDR_FRAME_STORE` | `Plex.qsf:82` | product path on |
| `FRAME_LINES_8` | `Plex.qsf:85` | `LINE_COUNT=8` → **16 line slots** |
| Runtime OSD | `Plex.sv:226-228` | `content_res_640x480 = status[4]`; `content_width/height` are **`wire [9:0]`** mux 320/640 — **not connected to any port** (only definitions in tree under `fpga/`) |
| DDR geometry | `rtl/ddr_frame_layout_params.svh` + `present_core.sv:239-256` | **Hardcoded** coded 624×480, display 618×480, presented 640×480, pillar L=11, bank stride **`0x0008_0000` (512 KiB)**, doorbell `0x300F_F000` |

**Implication:** Raising native content to 1280×720 is **not** an OSD-only change. It requires elaborate-time parameter / QSF / `ddr_frame_layout_params.svh` (and host contract) changes → **new RBF**.

`content_width` max with `[9:0]` is **1023**; **1280 needs 11 bits**. Even wiring it later is a width bug class.

### A.2 What scales with width vs pixels

| Module | Scales with | Evidence |
|--------|-------------|----------|
| `ddr_frame_store` line RAMs | **CODED_W** (depth of each line buffer) | `Y_LINE_QWORDS = CODED_W/8`, `C_LINE_QWORDS = CODED_W/16`; gen `LINE_SLOTS` of Y/U/V (`ddr_frame_store.sv:77-80,167-179`) |
| `ddr_frame_store` addr | **FRAME_W/H, CODED_W/H** | `$clog2(FRAME_W)`, plane qwords `(CODED_W*CODED_H)/8` (`:73-104`) |
| `ddr_frame_store` bank map | **HPS_BANK_STRIDE_BYTES** (param) | default 524288; product uses `DDR_FRAME_YUV420P_BANK_STRIDE` (`present_core.sv:255`) |
| `frame_store` (SDRAM path) | **FRAME_W** line depth; **FRAME_W×FRAME_H** words | `frame_store.sv` — **off** when `DDR_FRAME_STORE` |
| `present_core` sampling | **FRAME_W/H** into **fixed** timing | `H_DE=529`, **`V_STORE=10'd240` hardcoded** (`present_core.sv:162-196`); scales store coords, does **not** grow DE |
| `colorbars` timing | **fixed 320-class** | `H_CONTENT=320`, `H_DE=529`, `H_LAST=637` (`colorbars.sv:37-42`) |
| `stream_path` / `decode_stub` | **FRAME_W/H** | stub `.WIDTH(FRAME_W)` (`stream_path.sv:309-311`); `DPB_FRAME_BYTES = W*H*3/2` dual bank (`decode_stub.sv:586-589`) |
| `h264_decode_core` / deblock `lb_*` | **MB_W = ceil(W/16)** | `lb_y[0:(MB_W*64)-1]` etc. (`h264_deblock_mb.sv:96-98`) — product deblock is **M10K identity** under `ifndef VERILATOR` |
| MC windows | **block-sized**, not frame | `h264_mc_*` fixed windows — **not** primary 720p cost for host-present |

**Product present path today:** host YUV → HPS DDR banks → `ddr_frame_store` linebufs → `present_core` maps into **Template DE ~529×240** → MiSTer `ascal` → HDMI/VGA `video_mode`.  
So “640×480 content” is **frame-store resolution**, not 640×480 native core timing (`docs/display-resolution.md`, `colorbars.sv` header).

### A.3 Line-buffer / M10K estimate (formula from RTL — **not a fit**)

`line_buf_ram`: `(* ramstyle = "M10K" *) reg [DATA_W-1:0] mem [0:WIDTH-1]` (`line_buf_ram.sv:16`), `DATA_W=64`.

With **`LINE_COUNT=8` → `LINE_SLOTS=16`**, three RAMs/slot (Y,U,V):

| CODED_W | Y words×64b | C words×64b | Bits (all slots) | ceil(bits/10240) | Worst: 1 M10K / array |
|--------:|------------:|------------:|-----------------:|-----------------:|----------------------:|
| 624 (params) | 78 → 4992 | 39 → 2496 | 159 744 | **16** | **48** |
| 640 | 80 → 5120 | 40 → 2560 | 163 840 | **16** | **48** |
| **1280** | 160 → **10240** | 80 → 5120 | **327 680** | **32** | **48** |

**Δ bits 640→1280:** +163 840 → **+16 M10K lower bound** if packing tracks bits.  
**Δ physical blocks:** if each dual-clock RAM already burns **one** block at 640, width doubling may add **0** blocks (still one block each) **or** break packing of shallow C RAMs — **unknown without fit**.

**Against 88 free:** bit-lower-bound **+16** fits in 88; worst-case **no growth** also fits; **risk is other width-scaled structures + ascal + DPB + decode**, not linebufs alone.

Deblock linebufs (if ever non-identity product): MB_W 40→80 → bits 40 960→81 920 (**+~4 M10K** bit-ceil) — secondary.

**On-chip DPB dual I420 (formula):**

| W×H | 2× frame bytes | bits | ≈M10K bit-ceil |
|-----|---------------:|-----:|---------------:|
| 320×240 | 230 400 | 1.84M | ~180 |
| 640×480 | 921 600 | 7.37M | ~720 |
| **1280×720** | **2 764 800** | **22.1M** | **~2160** |

Device has **553** M10K. Full-frame on-chip DPB at 480p or 720p **cannot** be the product plan. Wire6 lists `altsyncram:dpb_mem_rtl_0` (entity extract) — product **does** elaborate a DPB RAM, but address ports use **`dpb_mem_waddr[17:0]`** (`decode_stub.sv:594`) → **18-bit index (256 KiB window)**, not a honest full 640×480 dual store.  
**720p must not grow on-chip DPB with FRAME_W/H.** Keep diagnostic DPB small / DDR-backed; pin decode WIDTH separate from present FRAME_W if needed.

### A.4 DDR RTL contract (not HPS aperture — that is `w-720arm`)

| Item | Current RTL | 1280×720 I420 |
|------|-------------|----------------|
| Frame bytes | coded 624×480 → 449 280 (`params.svh`) | **1 382 400** (~1.32 MiB) |
| Bank stride (params) | **`0x80000` (512 KiB)** | **Must grow** — 1.32 MiB ≰ 512 KiB |
| `Plex.sv` stride ladder (ifdef path) | picks 1 MiB or 2 MiB from `FRAME_BYTES` (`:280-284`) | 1 382 400 → **2 097 152** |
| Doorbell | `PHYS + 2*stride - 0x1000` | Moves with stride; **must match host** |
| `$clog2(FRAME_W)` | 10 @640 | **11 @1280** |
| `$clog2(FRAME_H)` | 9 @480 | **10 @720** |
| Host caps | `kDdrFrameStoreMaxWidth{640}`, `MaxHeight{480}`; accept also `bankStride <= kPlex480pYuv420pBankStride` (`ddr_frame_layout.hpp:341-364`) | **Must raise** with RTL |
| Mailbox fixed page note | layout comment: PLXS/PLXF/PLXD at **`0x3007F100`…** “live silicon ABI” (`ddr_frame_layout.hpp:79-81`) | **Hazard:** geometry-derived doorbell at 2 MiB stride ≠ today’s `0x300FF000`; fixed mailboxes may **collide or diverge** — settle with ARM lane |

RTL believes capacity via **parameters**, not runtime status. Wrong stride/code size → wrong plane bases / doorbell.

### A.5 Does 720p require an RBF rebuild?

| Change | Needs new RBF? |
|--------|----------------|
| `FRAME_W/H` 1280/720 | **YES** |
| `ddr_frame_layout_params.svh` coded/present/stride/doorbell | **YES** |
| Line buffer depths / `$clog2` widths | **YES** (follow params) |
| OSD 2-bit tier + `v,N` bump | **YES** (CONF_STR in bitstream) |
| `VIDEO_ARX/ARY` 16:9 default or menu | **YES** if core advertises AR |
| Host-only: request 720p then **scale into existing 624×480 present** | **NO new RBF** (quality ≠ native 720p store) |

**Answer: native 720p present path requires exclusive fit/RBF. Not authorised by this scope.**

---

## B. OSD ABI

### B.1 O[5:4] comment vs code (**code wins**)

| Claim | Source | Truth |
|-------|--------|-------|
| “O[5:4] Content FPS written by misterplexd” | `Plex.sv:59-62` comment | **STALE** |
| Menu | `Plex.sv:63` | `"O[4],Content resolution,320x240,640x480;"` — **one bit** |
| RTL consume | `Plex.sv:226-231` | only `status[4]`; **`content_fps = 8'd24` fixed** |
| Daemon | `osd_menu.hpp:18-24,125-129` | bit4 → 480p coded **624×480** vs 320×240; **`[5] reserved`** |
| `status[5]` consumers in fpga/host/arm | grep | **none** |

FPS is **not** on O[5:4] in running code.

### B.2 `status[15:0]` map (daemon + CONF_STR)

| Bits | Role | Free for tiers? |
|-----:|------|-----------------|
| 0 | Reset | no |
| 1 | A/V resync | no |
| 2 | TV Mode | no |
| 3 | Audio clock trim | no |
| **4** | **Content res (1 bit)** | **widen** |
| **5** | **reserved** (`osd_menu.hpp`) | **YES — claim with version bump** |
| 9:6 | A/V offset | no |
| 10–11 | Flush T | no |
| 12–13 | DDR start/bank (HPS) | **never reuse** |
| 15:14 | Idle screen | no |
| 122:121 | Aspect (above OSD-safe echo) | separate |

`kOsdOwnedMask = 0xC3DA` includes bit4, **not** bit5 today (`osd_menu.hpp:179`).

### B.3 Proposed 2-bit encoding (`O[5:4]`)

| `status[5:4]` | Tier | Coded (ladder) | Presented (scanout canvas) |
|--------------:|------|----------------|----------------------------|
| `00` | 240p | 320×240 | 320×240 (or identity) |
| `01` | 480p | **624×480** (not 640 coded) | 640×480 pillar |
| `10` | 720p | **1280×720** (MB-aligned; crop TBD w/ PMS) | 1280×720 (or letterboxed 4:3 canvas — product choice) |
| `11` | reserved / future 1080p gate | — | — |

CONF_STR sketch:

```text
O[5:4],Content resolution,320x240,640x480,1280x720;
```

(Labels may show presented sizes; daemon must keep **coded** types — same 480p lesson.)

RTL (when implemented): replace dead `content_width[9:0]` with **≥11-bit** dims or a tier enum driving **only** software-visible telemetry until multi-geometry RTL exists. **Single compiled geometry per RBF** remains simplest (one max store); tier still selects host ladder.

### B.4 Version-bump hazard

| Item | Evidence |
|------|----------|
| Current | `"v,7;"` — “clears stale pre-480p status[4]” (`Plex.sv:82`) |
| Persist path | Main → `config/Plex_v7.CFG` (`osd_menu.hpp:177`, p480 evidence logs) |

**Must ship `v,8` (or next free) that:**

1. Resets **`status[5:4]`** (not only bit4) so old 1-bit “480p” does not become tier `01` with garbage bit5, and old reserved bit5 noise does not select 720p/`11`.
2. Documents CFG rename `Plex_v7.CFG` → `Plex_v8.CFG` (Main behaviour).
3. Updates `contentResolutionFromOsdWord`, `kOsdOwnedMask` (include bit5), unit tests, release notes.

Without bump: **garbage tier on upgrade** (same class as pre-v7).

---

## C. 16:9 HDMI + 4:3 VGA/CRT letterbox (`p720-aspect`)

### C.1 Aspect controls (quoted)

```systemverilog
// Plex.sv:44-46, 56
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;
// "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];"
```

| Menu | ARX:ARY into framework |
|------|------------------------|
| Original | **4:3** |
| Full Screen | ARX=0, ARY=0 (framework “special”) |
| ARC1/ARC2 | ARX=1/2, ARY=0 |

`video_freak.sv` / `ascal` consume ARX/ARY and HDMI/VGA scaler modes (`sys_top.v` ascal instances).  
**Default Original forces 4:3** even if content store is 16:9 — wrong for 720p unless changed to **16:9** (e.g. ARX=16, ARY=9) or user picks a non-Original mode that actually encodes 16:9 (current ARC encoding is **not** obviously 16:9 — **unknown without ascal/ARC docs experiment**).

### C.2 Output vs content (`docs/display-resolution.md`)

- **`video_mode`** (MiSTer.ini `[Plex]`) = HDMI/VGA **signal** (mode 0 = 1280×720@60 already lab-swept for **320 content**).
- **Content resolution** = decoded/present store size.
- With `vga_scaler=1`, **VGA follows HDMI mode** — high HDMI modes can make VGA unusable on 800×600 panels (`display-resolution.md` VGA guidance).

CRT checklist: **no false CRT PASS**; lab is HDMI-only (`docs/crt-lcd-lab-checklist.md`). **720p-native 15 kHz CRT is not viable** — agreed.

### C.3 Present-path scaling / letterbox

| Layer | What it does | 720p letterbox? |
|-------|--------------|-----------------|
| Host FFmpeg `scale/pad` | Already pads to coded canvas (`media_player.cpp:1963-1971`) | Can letterbox **into** coded frame before DDR |
| `DdrFramePlacement::Pillarbox` | Sets `present_x/y` center (`ddr_frame_layout.hpp:175-177`); 480p forces `present_y=0` (`:197-198`) | **Transpose = letterbox** if `present_y > 0` and presented H > display H |
| `ddr_frame_store` | `PRESENT_X/Y`, `DISPLAY_W/H`, `rd_visible`; outside → **RGB 0,0,0** (`:155-157,422-425`) — note: code is **0**, comments elsewhere say YUV black 16/128/128 | **Already 2-D**; letterbox needs nonzero `PRESENT_Y` in **params + host geometry** |
| `present_core` | Stretches FRAME into **529×240** DE | Independent of pillar/letter inside store |
| `ascal` + VIDEO_AR | Scales core DE to `video_mode`; AR controls pillar/letter **at output** | **Primary tool** for 16:9 content on 4:3 **VGA mode** |

### C.4 Pillarbox vs letterbox

**Same machinery:** crop + present origin + invisible fill.  
480p: horizontal pad into 640 (`PRESENT_X=11`).  
16:9 into 4:3 **presented** canvas: vertical pad (`PRESENT_Y = (H_pres - H_disp)/2`).

**Genuinely different problem:** driving **two different aspect policies on HDMI vs VGA simultaneously** while both share one core pixel stream and (typically) one `video_mode` via `vga_scaler=1`. Options:

1. **One 16:9 store + VIDEO_AR 16:9 + HDMI `video_mode` 720p/1080p**; VGA users stay on mode 5/6 and accept ascal letterbox/downscale — **no extra RTL** if AR fixed.  
2. **Host downscale to 4:3 coded** for “CRT profile” — ARM-only, no RBF.  
3. **Dual output timing** — **not** in tree; would be large RTL/framework work.

**Recommendation:** treat letterbox as **(a)** host pad and/or **(b)** `PRESENT_Y` generalisation of pillar, plus **(c)** correct **16:9 VIDEO_AR** for ascal; do **not** invent dual-HDMI/VGA native timings for v1.

### C.5 WIDE / full-DE interaction

P3-WIDE still tracks Template DE fingerprint (`docs/p3-wide-rca.md`). 720p store scaling through the same 529 DE **inherits** that geometry class. Native 1280 DE would be a **new timing generator** — out of scope for “add tier”, and hostile to CRT.

---

## D. Cost summary and exclusive-slot recommendation

### Must change for **native** 720p (RTL + lockstep host)

1. `Plex.qsf` `FRAME_W/H` (and likely keep `FRAME_LINES_8` until bandwidth proves otherwise).  
2. `ddr_frame_layout_params.svh` + `ddr_frame_layout.hpp` 720p constants, bank stride ≥ 1.32 MiB aligned, doorbell/map, max width/height.  
3. Address widths / plane math in `ddr_frame_store` (follow params).  
4. OSD `O[5:4]` + **`v,8`** + daemon decode/mask/tests.  
5. `VIDEO_AR` path for 16:9.  
6. `present_core` coord path audit at FRAME_H=720 with **V_STORE still 240** (scale math must remain correct; hc/vc still 10-bit).  
7. **Do not** scale on-chip `dpb_mem` to 720p frames.  
8. One exclusive **map+fit+STA**; post-fit hierarchy/timing gates.

### M10K block verdict (88 free)

| Item | Estimate | Confidence |
|------|----------|------------|
| Linebuf bit Δ | **+16 M10K** ceil | High (formula) |
| Linebuf physical Δ | **0–16+** | **Low — needs fit** |
| Full DPB @720p | **thousands of blocks** | Impossible — **forbid** |
| Headroom after linebufs | Likely OK if DPB pinned | Medium |
| **Fit without measure** | **unknown** | — |

**Check that settles physical M10K:** authorised `quartus_map`/`fit` on a 720p-param freeze; quote **Total RAM blocks** and `ddr_frame_store`/`line_buf` megafunction depths vs `14eaeff3` 465 baseline.

### Letterbox approach (v1)

| Output | Approach |
|--------|----------|
| HDMI 16:9 | Content 1280×720 (or 16:9 AR on smaller store) + `video_mode` 0/7/8/9 + **VIDEO_AR 16:9** |
| VGA/CRT 4:3 | Keep `video_mode` 5/6; ascal downscales; letterbox via AR; optional host 4:3 pad profile |
| In-canvas 16:9→4:3 | Extend placement enum/use `PRESENT_Y` (pillar transpose) — **params rebuild** |

### Exclusive fit slot?

| Question | Answer |
|----------|--------|
| Required for native 720p? | **YES** |
| Authorised now? | **NO** (per task + 480p soak gate) |
| Worth it immediately? | **NO — defer.** 480p path still soaking; M10K 84% used; layout/doorbell/mailbox ABI risk; present still 240-line Template timing; OSD ABI+version bump; WIDE still open. |
| Interim without exclusive | Host decode 720p → **scale/pad to existing 480p DDR contract**; HDMI already supports 720p/1080p **signal** modes |

### What could NOT be determined (unknown + settling check)

| Unknown | Settling check |
|---------|----------------|
| Physical M10K Δ at 1280-wide linebufs | One map/fit; diff RAM block count + line_buf entities |
| Whether ascal + 16:9 AR letterboxes cleanly on VGA mode 5/6 | Lab: set AR + modes; capture HDMI and VGA (CRT eyes-on separate) |
| HPS aperture two × 1.32 MiB + doorbell vs fixed mailboxes | **ARM lane `w-720arm`** + single ABI table signed by both sides |
| PMS real 720p coded size (crop/SAR) | Live ladder probe (host) |
| `dpb_mem` actual depth in `14eaeff3` | Fit RAM summary line for `dpb_mem_rtl_0` numwords |
| ARC1/ARC2 numeric AR | Read Main/ascal behaviour or lab measure with AR bits |

---

## E. Recommendation (decision input for `p720-decide`)

1. **Do not spend the exclusive Quartus slot on 720p yet.**  
2. Finish **480p A/V sync + soak** gates.  
3. Parallel **non-fit** work: OSD ABI design (`O[5:4]` + v8), host coded-size types for 720p, mailbox/stride ABI draft with ARM lane, AR 16:9 CONF_STR draft.  
4. If user needs sharper HDMI sooner: **ARM scale-to-480p-canvas** (no RBF).  
5. When authorised: one **LOCK_OK** design freeze → sole fit → menu deploy → FBAR → geometry/AR lab — never thrash banned RBFs.

---

## Evidence index

| Artifact | Role |
|----------|------|
| `fpga/Plex_MiSTer/Plex.sv` | CONF_STR, status[4], FRAME_*, VIDEO_AR, v7 |
| `fpga/Plex_MiSTer/Plex.qsf` | FRAME_W/H=640/480, DDR_FRAME_STORE, FRAME_LINES_8 |
| `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv` | linebufs, PRESENT_*, bank stride, black fill |
| `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` | 480p RTL contract |
| `fpga/Plex_MiSTer/rtl/present_core.sv` | V_STORE=240, ddr_frame_store instance |
| `fpga/Plex_MiSTer/rtl/colorbars.sv` | Template DE 529 |
| `fpga/Plex_MiSTer/rtl/line_buf_ram.sv` | M10K attribute |
| `fpga/Plex_MiSTer/rtl/decode_stub.sv` | DPB_FRAME_BYTES, [17:0] addr |
| `host/libmisterplex/osd_menu.hpp` | bit map, contentResolutionFromOsdWord |
| `host/libmisterplex/ddr_frame_layout.hpp` | pillar, max 640×480, 512 KiB stride cap |
| `.agent-work/integ-wiring/product-wire6-EVIDENCE.txt` | 465/553 M10K |
| `docs/display-resolution.md`, `docs/crt-lcd-lab-checklist.md`, `docs/p3-wide-rca.md` | output vs content, CRT, WIDE |

**No RTL implemented. No fit run.**
