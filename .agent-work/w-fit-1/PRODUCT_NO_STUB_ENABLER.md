# PRODUCT_NO_STUB — enabler for OSD hi-res overlay (no fit)

**Quartus hold stands. No fit requested.**  
**Next exclusive fit (when granted):** `PRODUCT_NO_STUB` **+** w-osd-hires post-ascal plane **together**.

## 1) Re-scope (not “area only”)

Throughput PRESENT_PROFILE: PRODUCT_NO_STUB moves **0 ms** (pacer-limited; flat table = control). That still stands.

**User-visible value is M10K for bug #2 (low-res player overlay):**
- Chrome is authored into the **624×480 bank** and stretched by `present_core`+`ascal` → ARM cannot match HDMI output resolution.
- ARM cannot discover applied HDMI timing (Main private `v_cur`; no usable query). Fabric has `HDMI_WIDTH`/`HDMI_HEIGHT` (`emu_ports.vh:34-35`, driven from `sys_top`).
- Fix = **post-ascal RTL overlay plane** (w-osd-hires). Blocker has been **M10K headroom**.

| | M10K used / 553 | Free |
|--|--:|--:|
| Shipping `8fdf440f` | **465** | **88** |
| After PRODUCT_NO_STUB (−268 exclusive stub subtree) | **~197** | **~356** |

**~4× free block RAM** for the overlay plane: “probably cannot fit” → “comfortably fits” (estimate until combined fit).

This is **deleting unreachable logic**, not a behavioural product change: shipping `DDR_FRAME_STORE=1` excludes `present_core` else branch; only consumer of `fs_wr_en` is `.wr_en` there → stub write port **physically unconnected** in every shipping mode.

## 2) Citation hazard — SETTLED (no guess, no new fit)

**Method:** md5 of `Plex.rbf` must match deployed prefix; use **co-located** `Plex.fit.rpt` only.

| Artifact | md5 prefix | ALM | M10K | DSP | Role |
|----------|------------|----:|-----:|----:|------|
| `…/fit-t7b-prog480/Plex.rbf` + same-dir `Plex.fit.rpt` | **`8fdf440f`** | **23,585** | **465** | **44** | **Deployed / shipping T7b** |
| mplex-builds mirror of same slot | **`8fdf440f`** | same | same | same | identical |
| **Main tree** `MisterPlex/fpga/Plex_MiSTer/output_files/Plex.rbf` | **`2890baac`** | **21,082** | (same bits class) | **74** | **Do-not-ship FREEZE** — not shipping |

Parent’s “output_files says 21,021 / DSP 74” class matches **stale/do-not-ship trees** (also product-wire6 `14eaeff3` @ 21,021/74), **not** `8fdf440f`.  
Worktree has **no** `fpga/.../output_files/` for product tip — only `remote_out/fit-t7b-prog480/`.

**Stub subtree on that same `8fdf440f` fit.rpt entity row:**
- `decode_stub:stub` ALM **9216.9** (own **1922.1**) / M10K **268** / DSP **1**
- `altsyncram:dpb_mem_rtl_0` M10K **256** / bits 2,097,152  
- All fitted `h264_*` under stub: **exclusive** (0 outside instances)

Headroom math: free 88 → **356**; used 465 → **197**. ALM free 18,325 → **~27.5k**.

## 3) Telemetry gate — PRESERVE (coordinate w-lint)

```systemverilog
// Plex.sv:890-893
wire [7:0] telem_flags = {
	pps_valid, sps_valid, stub_busy, has_idr,
	audio_underrun, has_stream, has_audio, has_frame
};
```

ARM fixed masks (`fpga_spi.cpp:2018-2025` — note: masks live here, not 2050):
`has_frame=1 … stub_busy=32, sps_valid=64, pps_valid=128`.

| Rule | Action |
|------|--------|
| Never shorten concat | Removing `stub_busy` without placeholder shifts sps/pps → **wrong status** (has_frame bit0 safe) |
| PRODUCT_NO_STUB else | already `assign stub_busy = 1'b0` / `stub_frames = 0` — **width preserved** |
| Verilator | TBs ref `top.stub_busy`/`stub_frames` — **gate, never delete** module from research builds |
| w-lint bit-position gate | **must exist before any telem layout change lands**; coordinate, do not race |

Dead `stub_allow` / `_keep_hybrid_product` may drop with PRODUCT_NO_STUB only if flags width unchanged.

## 4) Combined-fit pre-register (when parent grants — not now)

| Score | Prediction |
|-------|------------|
| PRESENT_PROFILE (480p24) | **FLAT** — all fields within noise of parent baseline; **any movement = bug** |
| User win | **Viewed pixels** of overlay at **1080p HDMI output** (parent capture only) — readable chrome matching output res |
| Fit resources | M10K used **~197 + overlay**; free must stay >0; stub row **absent**; no banned RBF md5 |
| STA | setup/hold ≥0, TNS 0; no new unjustified `set_false_path` |
| Freeze sim | red-before-green FAIL on broken RTL; PINNOTFOUND/%Error = rc=2 RED |

**Do not fit PRODUCT_NO_STUB alone** — unmeasurable on throughput, wastes slot vs pairing with OSD plane.

## 5) Untouched / banned

- Working cores **`8fdf440f`**, **`c5382bee`**: do not thrash/corrupt.  
- Do-not-ship: `2890baac` (main tree output_files!), `9eb1431a`, `ff2e3ca3`, `f0d3a385` + banned set.

## Process

Static/sim only. Own worktree. No device. Hold stands until parent grants **combined** slot.
