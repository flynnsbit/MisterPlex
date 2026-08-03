# Core ↔ daemon mode / overlay contract (w-path)

## Measurement identity

| Label | Value |
|-------|--------|
| Worktree branch | `w-path-720p` |
| Worktree SHA | run `git rev-parse --short HEAD` in this tree |
| Fleet main | `origin/main@85bef583` (blobs via `git show`, not shared dirty tree) |
| Log-format SoT (not on path HEAD / not on origin/main) | commit **`68c40b99`** (`fix(osd): crispness… DEFAULT_ASSUMED output tag`) |
| Mode-parse SoT | commit **`f18223ab`** (`mister_video_mode.hpp`) |
| Live device (parent) | RBF md5 **`41adb98c`**, CORENAME=Plex, daemon under `/media/fat/misterplex_v2/` |

**Honest:** the exact log string parent quoted is **w-osd-hires lineage**, not present on
`w-path-720p@HEAD` nor `origin/main`. Path HEAD `paintIdle` still hardcodes **320×240**
RGB idle + 624×480 DDR encode path without the canvas= log line.

---

## 1. Ground truth: `output=DEFAULT_ASSUMED` and `mode=?`

### Emitter (quoted)

From **`68c40b99:arm/misterplexd/media_player.cpp`**:

```cpp
// Cached MiSTer output geometry for logs + future chrome-plane list builder.
// Does NOT change bank authoring size (still plex480p). plane=0 until RTL (c).
inline std::string overlayOutputGeomTag() {
    static const MisterVideoMode kMode = [] {
        if (const char* p = std::getenv("MISTERPLEX_MISTER_INI")) {
            if (p[0] != '\0')
                return loadMisterVideoModeFromIni(p);
        }
        return loadMisterVideoMode();
    }();
    constexpr const char* kAuth = " authoring=624x480";
    if (!kMode.ok) {
        return std::string(" output=DEFAULT_ASSUMED mode=? source=none") + kAuth;
    }
    return std::string(" output=") + … + " source=ini" + kAuth;
}
```

Idle log site (same commit), `MediaPlayer::paintIdle()`:

```text
log("media: idle overlay canvas=" + cw + "x" + ch + " font=" + … +
    " scale=" + bodyScale + " chrome=0|1" + overlayOutputGeomTag());
```

with `cw/ch` from **`plex480pDdrFrameGeometry()`** → **624×480** (bank), not HDMI.

### What it tried to read

From **`f18223ab` / `68c40b99:host/libmisterplex/mister_video_mode.hpp`**:

| Step | Code | Failure → DEFAULT_ASSUMED |
|------|------|---------------------------|
| Path | `kMisterIniDefaultPath = "/media/fat/MiSTer.ini"` or env `MISTERPLEX_MISTER_INI` | `ifstream` open fails → `ok=false` |
| Section | Only lines inside **`[Plex]`** (case-insensitive) | `video_mode` only under `[MiSTer]` → never seen → empty |
| Key | Prefer `video_mode=`; else first of `video_mode_ntsc` / `_pal` | missing → empty |
| Parse | Integer preset table (e.g. 7→1280×720, 8→1920×1080) or custom `W,H,…` / `WxH` | unparsed → `ok=false` |

**It is not “never designed”.** A mode-report path **exists on w-osd commits** and **falls back** when ini load/parse fails. It is **unwired on origin/main and on w-path HEAD** (no `mister_video_mode.hpp`).

### What DEFAULT_ASSUMED is *not*

- **Not** core beam DE / PLXG H_DE.
- **Not** a read of the FPGA.
- **Does not change authoring:** `authoring=624x480` is a **hardcoded string** even when ini succeeds (`source=ini`). Success only replaces `output=WxH mode=N`.

So parent’s log means: **ini→WxH failed** (`source=none`), while F1 chrome is still pinned to **624×480 bank** by design of that tag.

### Path HEAD idle (this branch)

`w-path-720p` `media_player.cpp` `paintIdle()`:

- fb0/RGB idle buffer **320×240** hardcoded.
- DDR publish uses **`plex480pDdrFrameGeometry()`** (624×480) when `useDdrF1_`.
- No `idle overlay canvas=` / `DEFAULT_ASSUMED` log on this SHA.

---

## 2. Design: core → daemon mode report for 720p

### Two different sizes (do not conflate)

| Size | Meaning | Who owns | 720p need |
|------|---------|----------|-----------|
| **A. Bank / content DE** | DDR payload + overlay authoring raster | core present + PLXG q1–q2 | Learn **1280×720** (or Route-B **960×540**) when beam/L4 enables |
| **B. HDMI glass** | ascal output (`video_mode`) | MiSTer.ini / scaler | May stay 1080p/1440 while bank is 720 |

Parent’s fit risk: fabric **A=1280×720** while daemon authors **A=624×480**. Fixing only **B** (ini) does **not** fix authoring.

### Chosen channel (prefer existing)

**Primary (bank A): PLXG record the daemon already publishes + status freeze.**

| Mechanism | Why |
|-----------|-----|
| **Host write path (exists)** | `writePlxgRecord` / `DdrPublishCouple` already carries full visual tuple q0..q5 including **q2 H_DE/V_DE** and q1 content. After a successful publish, daemon **already knows** the mode it programmed. |
| **Idle / pre-first-frame** | No couple yet → need **core default** or conf. |
| **Core→HPS readback (gap)** | Extend **existing** 16-byte status telemetry (`FpgaSpi::readStatusRaw`, `Plex.sv` status_telem) with **latched applied H_DE/V_DE/fps** from store/present (same tuple B20 must freeze at swap). Daemon polls; on change, rebuild overlay canvas. **Reuses SPI status surface — no new doorbell protocol.** |
| **Reject as sole source** | MiSTer.ini `video_mode` alone — that is glass **B**, already partially designed in w-osd; insufficient for bank **A**. |
| **Reject** | New PLXC-only side channel when PLXG+status already carry geom. |

**Secondary (glass B):** keep/port `mister_video_mode.hpp` for logs + future native chrome plane layout (`computeOutputChromeLayout`). Fix parse to also accept `[MiSTer] video_mode` if lab ini has no `[Plex]` section (likely cause of live DEFAULT_ASSUMED).

### Daemon authoring policy (target)

```text
canvas_w/h = max( core_reported_applied_DE , last_plxg_couple DE , product_floor_480 )
overlay authored at canvas (not 320)
font scale = PlaybackOverlay::layoutMetrics(canvas_w, canvas_h).bodyScale
```

Route-B until multi-pixel: host emit ≤960×540; glass 720 via ascal (path prior work).

---

## 3. Overlay not on glass — source separation (no guess of live root cause)

### (a) `Plex.sv` `.use_frame_store(1'b0)` — **NOT “frame store disabled”**

Pinned `origin/main` + this tree `present_core.sv`:

```systemverilog
// present_core.sv:39
input  wire use_frame_store, // OSD force bars when 1
// :344-345
wire use_ext = has_frame && !use_frame_store;
wire show_pattern = !use_ext && (use_frame_store || (pattern != 2'd0));
```

| `use_frame_store` | Meaning |
|-------------------|---------|
| **1** | Force color bars (`eff_pattern=1`), **ignore** external frame |
| **0** (product hardwire) | Use external frame **when `has_frame`**, pattern only if `pattern!=0` |

`Plex.sv:749` `.use_frame_store(1'b0)` with `.pattern(2'd0)` ⇒ **enable** frame path when `has_frame`, **not** disable DDR.  
**rd-duck/parent “DISABLED frame store” reading of this pin is inverted vs RTL comments/logic.**

Scanout still needs `has_frame=1` after a successful swap into the store the present path reads.

### (b) Version mismatch — **real class, separate check**

From `docs/idle-screensaver-audit-v030.md` (live **41adb98c**):

- Core: **320×240 RGB565** product at tag `v0.3.0` / `cacd871…`
- Conf often still says `DECODE=624x480`
- Idle at that tag hardcodes 320; DDR logo golden matched **because** idle matched core, not conf

A **v2 daemon** that paints **624×480 YUV** F1 into a **v0.3.0 320 RGB** map is a **layout/ABI mismatch** class (bank stride, format, doorbell). That can yield: publish “ok” but wrong pixels, or publish fail → `has_frame` never rises → non-overlay picture.

Colour-band TEST PATTERN with moving MEAN: consistent with **bars path** or **non-overlay core pattern**, not with successful idle logo latch (v0.3.0 logo golden was 2-color). **Source cannot pick (a) vs (b) for the live box without parent device checks below.**

### Device checks (parent-only) — settle (a)/(b)/publish

Run on device; paste logs. Do **not** thrash core.

```bash
# Identity
cat /tmp/CORENAME
md5sum /media/fat/_Utility/Plex.rbf
md5sum /media/fat/misterplex_v2/bin/misterplexd
# expect RBF 41adb98c… if still v0.3.0 baseline

# Daemon path outcome (grep last idle cycle)
grep -E 'idle overlay canvas|idle screen painted|idle paint DDR|idle FPGA|DEFAULT_ASSUMED|PRESENT=|has_frame' \
  /media/fat/misterplex_v2/misterplexd.log | tail -40

# Ini mode parse (explains DEFAULT_ASSUMED)
grep -n -i 'video_mode\|^\[Plex\]\|^\[MiSTer\]' /media/fat/MiSTer.ini | head -40

# If status telemetry exposes has_frame (daemon/tools):
#   any existing status dump / companion that prints has_frame
```

| Observation | Interpretation |
|-------------|----------------|
| `idle paint DDR failed` / no `idle screen painted` | Publish path broken → glass ≠ overlay (mismatch or SPI) |
| `idle screen painted` + DDR bank matches host idle golden | Daemon wrote idle; if glass is bars → **scanout not showing that bank** (present path / wrong core) |
| `idle screen painted` + DDR ≠ golden / wrong size | **version/geometry mismatch** |
| `output=DEFAULT_ASSUMED source=none` | ini `[Plex] video_mode` missing/unreadable — **log only**; authoring still 624 pin on osd builds |
| RBF md5≠41adb98c but log says v2 624 authoring | different core — re-baseline |

HDMI: keep using `scripts/hdmi_capture_idle.sh` (not single-frame ffmpeg).

---

## 4. Authoring scale for 1280×720 canvas

### Today (osd 624 path)

| Field | Value | Mechanism |
|-------|------:|-----------|
| canvas / authoring | 624×480 | `plex480pDdrFrameGeometry()` |
| font | 12×16 when w≥600 \|\| h≥480 | `PlaybackOverlay::layoutMetrics` |
| bodyScale | **2** on 480-tall bank | even-row present fetch needs scale≥2 (`docs/osd-hires.md`) |
| glass | ascal ← `video_mode` | stretch bank → HDMI |

Overlay is **authored to bank size**, then scaled by ascal to glass — **not** authored at 1920×1080 on product F1.

### 1280×720 bank

| Change | Detail |
|--------|--------|
| Authoring target | **1280×720** (or Route-B **960×540** until multi-pixel) via core-reported DE / couple |
| Font | Still 12×16 cell if h≥480 |
| bodyScale | `layoutMetrics`: scales with canvas; on 720p height, scale rises vs 480 (see `computeOutputChromeLayout` ~ `H/240` clamp 2..8 on **output** path). Bank path uses content metrics — **must re-pin even-y / scale≥2** if present still decimates rows |
| Readability | At scale=2, 12×16 → **24×32** px glyphs on a **720** canvas: similar **fraction of height** as 24×32 on 480 (~4.4% vs 5% of H). On **1080 glass** via ascal, appears sharper if bank is 720 than if bank is 480. If bodyScale stays 2 while glass is 1440, chrome looks **small** relative to glass (user judgment on capture). |
| Bytes | 1280×720 I420 = 1 382 400 B/frame (path prior); DDR ABI must hold banks (w-mem) |

**Fixed-size-then-scale vs target:** product F1 is **target bank authoring**, then ascal to glass. Native chrome plane (osd “plane=1”) would author in **output** pixels — not shipped (plane=0 in log).

---

## Ladder (path-owned pieces for this work)

Measured: branch `w-path-720p` + `origin/main@85bef583` blobs.

| Module / unit | ON_MAIN | IN_QIP | INST | EN | Level |
|---------------|---------|--------|------|-----|-------|
| `mister_video_mode.hpp` (osd) | **no** (absent origin/main) | n/a | n/a | n/a | **L0 on osd branch only** |
| path `paintIdle` 320/624 | no (path vs main differs) | n/a | daemon | yes on device binary | device ≠ this SHA |
| `present_core` use_frame_store pin | yes | yes | yes | **tied 0** (= not force bars) | **L4 semantics: force-bars off** |
| PLXG host couple / mode freeze | path L0 vs main | n/a | branch | branch | **L0** |
| status telem DE readback | **no** | — | — | — | **not designed in RTL yet (w-mem/present)** |

---

## Path next implementation (when coding resumes)

1. Port `mister_video_mode.hpp` + `[Plex]`/`[MiSTer]` fallback; unit test DEFAULT_ASSUMED vs ini ok.  
2. Single `resolveOverlayCanvas()`: couple DE > status DE > plex480 floor; drive paintIdle.  
3. Coordinate status DE fields with w-mem B20 applied tuple (not live).  
4. Do **not** set `use_frame_store=1` thinking it “enables” store.

## Parent fit readiness

Without (2)+(3), a 720p L4 fit can show correct beam with **daemon still authoring 624** (or 320 on older path HEAD). Ini-only fix is **insufficient**.
