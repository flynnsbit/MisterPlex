# Geometry-side cost of 480p drops (w-geom)

Branch: `w-avsync-hdmi-measure`  
Scope: source + host gates only. No device. No RBF.  
Question: does the 624×480 path **structurally** cost frames that the 240p path does not?

## Verdict (loud)

**NO — the FPGA DDR canvas and post-decode ARM path are the SAME size for DECODE=320×240 and DECODE=624×480.**  
Both publish **449280 B** I420 into coded 624×480 / display 618×480 / crop_right=6.

What **does** differ is the **ffmpeg decode + FORCE_SCALE scale/pad leg** (heavier at 480p on host, decode-dominated).  
That can raise pacer `drops` via CPU/A-V lag; it is **not** a larger DDR bank or extra geometry copy unique to 480p.

`drops` alone is **blind** to publish stalls — use `publish_misses` + `PRESENT_PROFILE`.

---

## Q1 — Per-frame cost that scales with 480p geometry?

### Same after decode (both tiers, FPGA present)

| Step | Evidence | 240 vs 480 |
|---|---|---|
| DDR geometry | `ddrFrameGeometryForFpgaPresent` **ignores** decode W/H → `productDdrFrameStoreGeometry()` (`ddr_frame_layout.hpp:234-241`) | **identical** 624×480 |
| frame_bytes | `kPlex480pYuv420pBytes = 449280` (`ddr_frame_layout.hpp:33`) | **identical** |
| pipe read | `rawW/rawH = coded_*` → 449280 B/frame | **identical** |
| `clearYuv420pCropPadding` | strip-only crop (`media_player.cpp:176-214`); crop_right=6 → **4320 B** touch | **identical** |
| `repairDeadYuv420pChroma` | full U+V inspect every frame (`yuv420p_chroma_health.hpp:66-97`, call `media_player.cpp:3836-3854`) = **74880 samples ×2** | **identical** |
| DDR `memcpy` + PLXD | full bank both tiers | **identical** |

Gate lock: `test_geom_frame_cost` **P1** — `true rc=0`:
```
P1_OK coded=624x480 display=618 crop_right=6 frame_bytes=449280 (both tiers)
```

Host microbench **tag=measured** (x86 host ≠ A9; order-of-magnitude only):
```
chroma_inspect_us_f=59.75  memcpy449280_us_f=15.03  clear_strip_us_f=1.34
```
Chroma full-scan dominates post-decode pixel work on host; **same both tiers**.

### Differs: ffmpeg decode + product FORCE_SCALE vf

Product vf (both tiers when force on):
`scale=618:480:force_original_aspect_ratio=decrease,pad=624:480:…`  
(`media_player.cpp:2724-2739`, `ffmpeg_vf.hpp` scale/pad).

Host gate `test_force_scale_sws_cost.sh` **tag=measured** `true rc=0`:
```
cpu_ms_f 320_default=1.2216  624_default=1.6192  624_fb=1.5479  320_fb=1.1683
RATIO_624_over_320=1.325
H1_624_total_ge_320_total HIT
H2_fast_bilinear_le_1_20x_default_624 HIT
```

**Pre-register miss (published):** first H1 assumed “320 upscale scale-delta ≥ 624 mild scale-delta ⇒ 320 total ≥ 624 total”.  
**Measured:** product **total** (decode+scale+pad) is **higher at 624** (ratio 1.325). Decode cost dominates; mild 618 shrink does **not** make 480p cheaper than 240p+upscale.

Prior method_c (`docs/evidence/cpu-split-scale-vs-decode/method_c_host_results.json`):
- host scale_up 320→624 **delta** cpu_ms_f ≈ **0.696**
- host scale_id native624 **delta** ≈ **0.307**
- ARM FEED 624: decode_null_cpu_ms_f ≈ **22.87**, scale_delta_cpu_ms_f ≈ **7.28** (`published_instrument_B_ARM`)

`FFMPEG_SWS_FLAGS=fast_bilinear` (user conf): H2 HIT — not worse than default on 624 (1.55 vs 1.62 ms/f host). Does **not** invert the 624>320 total ranking.

**Implication for user “frames dropped”:** geometry path does **not** invent extra DDR work at 480p. Higher `drops` is consistent with **heavier ffmpeg leg + dual-A9 headroom**, not a bigger bank. w-instr owns glass identity; parent should split pacer vs publish (Q3).

---

## Q2 — What `DDR_YUV_FORCE_SCALE=1` actually does

**Do not propose turning it off** (user-owned; silicon needs it for colour).

Source:
- Product default **ON** in code: `ddrYuvForceScale = true` (`main.cpp:210`).
- Conf `DDR_YUV_FORCE_SCALE=0` **alone is IGNORED** unless `DDR_YUV_FORCE_SCALE_LAB=1` (`main.cpp:203-206`, loud warn ~727).
- At play: `forceScale = yuvDdrPresent && ddrYuvForceScale_` → `ffmpegScaleModeForDdrYuvPresent(SkipIdentity→Always)` (`media_player.cpp:2728-2733`, `yuv420p_chroma_health.hpp:113-128`).
- Emits **per-frame** scale+pad into coded bank for **both** 240p and 480p sources (320≠624 so force is never a pure no-op at 240p either — comment at 128 is stale relative to Always).

Gate **P2** + `test_force_scale_ffmpeg_out.sh` (`true rc=0`): Always → `pad=624:480`, **449280×N** bytes for bank and non-bank sources.

**Implicated in drops?** Only as a **shared** per-frame scale cost on both tiers; 480p still pays **more total** ffmpeg CPU (Q1). Not a 480p-only extra stage.

---

## Q3 — DDR publish keeping up? (`drops` vs `publish_misses`)

| Counter | Meaning | Source |
|---|---|---|
| `drops` | A/V pacer **only** `AvAction::Drop` | `media_player.cpp:3986-4014`, `av_clock.hpp` |
| `publish_misses` | present attempted, DDR/FPGA fail | `frame_ledger.hpp:56-62`, increment path ~3493 |
| residual | `frames - presents - drops` | `frame_ledger.hpp:63` |
| explained | residual == publish_misses | `frameLedgerResidualExplainedByPublishMiss` |

1 Hz already emits both via `frameLedgerTelemetryFragment` (`media_player.cpp:4050-4060`).  
Also logs every pacer drop: `media: A/V resync drop wall_s=… drops=…` (`3997-4014`).

Gate **P4** `true rc=0`: counters distinct; residual explained by publish_misses.

`PRESENT_PROFILE=1` → `media: present_profile` with `read_us_f`, `pixel_us_p`, `ddr_*_us_p`, `drops=` (`media_player.cpp:3282+`).

### Parent recipe (you run device)

```bash
# On device conf (USER-OWNED — backup first): PRESENT_PROFILE=1
# During 480p FORCE_SCALE=1 cast, after ≥300 frames / ≥21 s:

grep -E 'media: (frames=|A/V resync drop|present_profile|publish_misses=)' /path/to/daemon.log

# Pre-register:
#   G1: if publish_misses≈0 and residual≈0 while drops≈12 @21s → pacer/CPU, not DDR stall
#   G2: if publish_misses tracks residual and rises with 480p → PLXD/bank-select stall
#   G3: present_profile ddr_wait_us_p + ddr_copy_us_p << 41666 us_f (24fps budget)
#   G4: compare same window 240p vs 480p on drops AND publish_misses separately
```

---

## Q4 — 624 vs 618 crop

Constants (`ddr_frame_layout.hpp:15-22`):
- coded **624**, display **618**, crop_left=0, **crop_right=6**, presented 640.

Handling:
1. **Once** in vf plan: `scale=618:480:…,pad=624:480:…` (session-fixed at play — `media_player.cpp:1407` comment).
2. **Per frame** strip clear only: `clearYuv420pCropPadding` right pad cols (Y:480×6, U/V:240×3) — **not** full-frame geometry recompute.
3. Gate **P3**: strip_bytes=4320, ratio_x1000=9 vs full frame.

---

## V_STORE=240 (quality, not drops)

`present_core.sv:162-164`, `Plex.qsf FRAME_H=480`:
```
V_STORE = 240
STORE_Y_SCALE = (FRAME_H * 65536) / 240 = 131072  # exact 2.0 Q16
```
Gate **P5**: py→store_y even only (0,2,…478). **Discards odd store rows at scanout** — vertical detail cap. **Does not increment `drops` or skip frames.** No RBF without parent grant; c5382bee undisturbed.

---

## Gates (host, true rc direct)

| Gate | Result |
|---|---|
| `build/test_geom_frame_cost` | **rc=0** PASS P1–P5 + bench |
| `bash tests/unit/test_force_scale_sws_cost.sh` | **rc=0** H1 HIT H2 HIT ratio=1.325 |
| `bash tests/unit/test_force_scale_ffmpeg_out.sh` | **rc=0** (prior) |
| unit-rollcall | **rc=0** (also wired peer `test_glass_ledger_fixture.sh` into Makefile — was rollcall-only) |

---

## What would falsify this report

1. Device `publish_misses` ≫ 0 at 480p while 240p ≈ 0 → geometry-side DDR stall (we said unlikely).
2. Device `present_profile` shows `pixel_us_p` or `ddr_*` exploding only at 480p beyond decode difference.
3. Source change making `ddrFrameGeometryForFpgaPresent` return decode-dependent size (would break both tiers).

---

## Honest CPU note

Parent: ~166/200 %onecpu at 240p. Host ratio 1.325× on ffmpeg product path at 480p **plus** same full-bank post-decode work predicts **less** headroom at 480p → more pacer drops is **plausible** without any geometry bug. Confirm with G1–G4 above; do not treat `av-lock` as lip-sync.
