# VF vertical resample defect (rd-review) — settled + ARM-only fix

**Branch:** `w-avsync-hdmi-measure`  
**Worktree SHA (pre-commit tip when written):** see `git rev-parse HEAD`  
**Scope:** source + unit only. No device. No Quartus.  
**Artifact pair for prior glass that exposed this:** RBF `8fdf440f` + daemon `7c991e47` (parent).  
**This fix is ARM-only** (daemon / `ffmpeg_vf.hpp`). No RBF change.

---

## 1. Arithmetic — CONFIRMED from source

`buildScalePadCropped` (`host/libmisterplex/ffmpeg_vf.hpp`):

```
scale=<display_w>:<display_h>[:flags=…]:force_original_aspect_ratio=decrease,
pad=<coded_w>:<coded_h>:<crop_left>+(display_w-iw)/2:<crop_top>+(display_h-ih)/2:color=black
```

Product call site builds that when `hasCrop` (display 618 ≠ coded 624) unless the new exact-coded branch fires.

`media_player.cpp` fills:

- `vfReq.coded_w/h` = DDR coded 624×480  
- `vfReq.display_w/h` = DDR display 618×480  
- `vfReq.crop_left/top` from geometry  
- under YUV DDR force-scale → `FfmpegScaleMode::Always`

**Integer model** (same file, `scaleDecreaseOutHeight`):

```
out_h = floor(src_h * box_w / src_w)   when width-limited
      = 480 * 618 / 624 = 475           for 624×480 → box 618×480
```

So parent’s mechanism is **correct**: `force_original_aspect_ratio=decrease` applies  
`s = min(618/624, 480/480) = 618/624 ≈ 0.99038` to **both** axes → content ≈ **618×475**, then pad to 624×480.  
Honest unique content rows under the **old** vf: **~475**, not 480.

Unit pin: `scaleDecreaseOutHeight(624,480,618,480) == 475` (rc=0).

---

## 2. Why 618 (not 624)

Not a stride artefact and not an accidental constant.

| Layer | Citation | Value |
|-------|----------|-------|
| ARM contract | `ddr_frame_layout.hpp:17` | `kPlex480pDisplayWidth{618}` |
| ARM crop | `ddr_frame_layout.hpp:22` | `kPlex480pCropRight = 6` |
| RTL params | `fpga/.../ddr_frame_layout_params.svh:7,12` | `DDR_FRAME_DISPLAY_WIDTH=618`, `DDR_FRAME_CROP_RIGHT=6` |
| Comment | `ddr_frame_layout.hpp:11-14` | coded 624 / display 618 after right crop of 6 / presented 640 |

**Derivation:** display = coded − crop_right = 624 − 6 = **618**.  
Right 6 columns of the coded bank are intentionally non-visible (present path crops to `DISPLAY_W`).  
Horizontal display crop is a **real product geometry** constraint. The bug was feeding that narrower box into **swscale decrease**, which couples H-crop into V-resample.

---

## 3. Fix + tradeoffs

### Fix (landed)

When `source_w/h == coded_w/h` **and** display crop is active:

```
crop=618:480:<crop_left>:<crop_top>,pad=624:480:<padX>:<padY>:color=black
```

via `buildCropPadNoScale` — **zero vertical resample**, **zero swscale**.  
Reason token: `crop_pad_no_v_scale` (or `…_unverified_delivery` when SkipIdentity + numeric match without verify).  
`scale_applied=false` → GEOM `arm_rescale=0` for exact bank (honest).

### Still uses decrease-into-display

Any source that is **not** exact coded WxH (320×240, 640×480, 1920×1080, scope 2.35, etc.) keeps:

```
scale=618:480:…:force_original_aspect_ratio=decrease,pad=624:480:…
```

### Tradeoffs

| Source class | Behaviour after fix | Risk |
|--------------|---------------------|------|
| **624×480 exact** (product 480p bank) | crop+pad only | **Fixed** — 480 unique content rows in bank |
| **320×240** | still decrease upscale into 618×480 | Unchanged; 240p still relies on `arm_rescale` |
| **Non-4:3 / letterbox** (e.g. 624×352) | still decrease + pad | Unchanged AR fit |
| **Wider than coded** (640×480, 720×480) | still decrease into 618 → some V shrink | Pre-existing; not this defect class |
| **Unknown source (0×0) + force Always** | still decrease into 618 | If PMS actually delivers 624×480 but source dims unset, old defect remains — product path sets `ffmpegScaleSourceW/H` from delivery |
| **SkipIdentity + verified exact** | still empty vf + `clearYuv420pCropPadding` | Unchanged best path |

**Rejected alternatives**

- Drop `force_original_aspect_ratio` globally → non-4:3 sources stretch.  
- Scale into coded 624×480 with decrease for all → 320×240 AR vs 624/480 still V-resamples slightly; exact 624 becomes 1:1 swscale (softer than crop).  
- Identity-skip always under force → pipe desync class returns when PMS lies.

---

## 4. Gate — red before green

**Predicate:** `vfPreservesBankHeightSource(vf)`  
— fails if vf contains `force_original_aspect_ratio=decrease` or `scale=`.

**Coverage (not empty):**

1. Arithmetic `out_h==475` for 624→618 decrease.  
2. **RED mutation:** `buildScalePadCropped(618,480,…)` string fails predicate.  
3. **GREEN product:** Always + source 624×480 → crop-pad string, predicate true.  
4. 240p still has decrease scale (must not break).

**Mutation of product branch** (`exactCodedSource && false`):

| | true rc | notes |
|--|---------|--------|
| RED (mutated) | **1** | 11 fails incl. `GREEN: exact coded source vf preserves bank height`; got legacy `scale=618:480:…decrease` |
| GREEN (restored) | **0** | `GREEN_NO_V_RESAMPLE out_h_624=475 legacy_red=1 product_crop_pad=1 p240_upscale=1` |

Also: `test_geom_frame_cost`, `test_yuv420p_chroma_480p`, `test_glass_loss_death_points` → **true rc=0**.

---

## 5. Pre-registered glass pitch (parent measures)

Capture content height used previously: **958** rows (parent).

| Model | Content rows | Pitch formula | Predicted pitch |
|-------|--------------|---------------|-----------------|
| Old vf (~475 unique) | 475 | `958/475 × 2` | **4.034** ≈ measured **4.06** |
| After this fix (480 unique) | 480 | `958/480 × 2` | **3.9917 ≈ 3.99** |

**Pre-register before parent capture:**

- Decision: pitch moves **4.06 → ~3.99** (Δ ≈ −0.07).  
- If pitch stays ~4.06 after daemon-only deploy of this fix: MISS — investigate whether session still emits decrease (GEOM `vf=` / `reason=`) or fixture/FFT bin lock.  
- If pitch ≤ 4.00 and GEOM shows `reason=crop_pad_no_v_scale` or `identity_skip_*` with no `force_original_aspect_ratio=decrease`: HIT.

**ARM-ONLY:** parent can deploy new daemon against live RBF `8fdf440f` immediately. No fit.

---

## 6. Still open (not superseded) — cadence

### `8fdf440f` **is** a swap-counter RBF

Freeze store md5 `6c39218e` (fit-t7b-prog480):

- `frames_done <= frames_done + 1` on **swap** (`ddr_frame_store.sv` ~284).  
- PLXD pack `{frames_done_d2, …}` at ~1043 — comment: real swaps, not `bank_vsync_count`.

**Healthy `p_d1` on swap-counter:** ≈ 1.0  
(`p_d1` = frac of publish pairs with `Δframes_done == 1` — **not** hold length).

Measured **0.0335** on daemon `7c991e47` is therefore **anomalous for a swap-counter RBF** — tooling/daemon semantics or read path, not “expected healthy”. Do **not** quote 0.0335 as hitch rate. Remeasure with tip daemon that emits full swap-delta line.

### `p_hold_d1` emit (tip already has it)

Derivation (`publish_swap_delta_ledger.hpp`):

- `hold_d = holdDFromIvMs(iv_ms, T_vsync)` = `round(iv_ms / T_vsync)`  
- `p_hold_d1` = frac(`hold_d == 1`) among intervals with finite iv  
- EOS: `pubSwapDelta_.formatSummaryLine` → `media_player.cpp` ~4592  

Deploy tip daemon; score `p_hold_d1` / `p_one_refresh_hold` permanently.  
Daemon `7c991e47` lacks this field → parent cannot score hitch until upgrade.

### Residual hitch RTL

- No min-2 refresh interlock (1-hold **RTL-legal**).  
- No 3:2 pacer in present path.  
- 907e already on `8fdf` store `6c39218e` (HOLDS=1 gate).  
Ledger `drops=0` does not observe 1-refresh holds — only `p_hold_d1` does.

---

## 7. Files touched

- `host/libmisterplex/ffmpeg_vf.hpp` — arithmetic helpers, `buildCropPadNoScale`, exact-coded branch  
- `tests/unit/test_ffmpeg_vf.cpp` — NO_V_RESAMPLE gate + FORCE_SCALE exact-bank pins  
- `tests/unit/test_geom_frame_cost.cpp`  
- `tests/unit/test_yuv420p_chroma_480p.cpp`  
- `tests/unit/test_glass_loss_death_points.cpp`  
- `tests/unit/test_force_scale_sws_cost.sh` — 624 path uses crop vf  

**Loud for parent:** **ARM-ONLY fix. Deploy daemon; no Quartus.**
