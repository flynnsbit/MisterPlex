# w-promote merge notes — w-osd-hires → main `87d72720`

**Do not naive-deploy main.** Main has **no** `pause overlay DDR` / `publishPausedOverlayFrame`.
Daily driver would lose sticky pause chrome.

## Merge-base

`2675c2b4` (approx). Overlay lineage to take entire:

`8cf8b6a0 → ed1fc22f → 8475a8dd → 46981b36 → eab6471a → 4ed6a096 → 1c531e3f` (+ localize pair tip)

## High-risk files (real conflicts expected)

### 1. `arm/misterplexd/media_player.cpp` — **highest risk**

| Side | Owns |
|---|---|
| **w-osd-hires** | `publishPausedOverlayFrame`, pause latch, sticky pause loop republish, `paintIdle` bank canvas + font log, `renderOverlay` YUV paint, even-y/scale chrome |
| **main `87d72720`** | `frame_ledger.hpp`, avsync pause/session, `threadMain` present path telemetry, poison-macro guards |

**Resolve by integration, not ours-or-theirs:**
- Keep **all** main ledger/avsync call sites.
- Keep **entire** osd pause publish + idle bank geometry + overlay YUV path from w-osd.
- `pause()` must: show overlay → `publishPausedOverlayFrame()` → then existing avsync/SIGSTOP order from main.
- `presentCleanFrame` / play loop: main ledger hooks **and** `rememberPauseFrame` + overlay composite from w-osd.

### 2. `host/libmisterplex/playback_overlay.hpp` — **prefer w-osd whole file**

Main ≈560 lines (old 5×7-era / no dual font / no sticky Paused / translucent panel).  
w-osd ≈1095 lines (12×16/8×13, scale≥2, sticky Paused+Stopped, opaque `panelBg`, title).

Unless main added unrelated APIs (grep before merge), **take w-osd file** and re-add any main-only symbols if present (unlikely).

### 3. `arm/misterplexd/main.cpp` — low (+2/−0 on osd branch)

Likely `setOverlayTitle` on doPlay. Keep both title wire-up and any avsync main changes.

### 4. Tools / tests — additive

- `tools/readback_overlay_text.py`, `tools/measure_overlay_word_span.py`, `tools/even_row_cull_glyph_gate.py`
- `tests/unit/test_playback_overlay.cpp`, `test_panel_empty_center_static.py`, `test_pause_*_static.py`, fixtures under `tests/unit/fixtures/overlay_readback/`
- `docs/osd-hires.md`, `docs/osd-output-raster-feasibility.md`

Main probably lacks these — add cleanly.

## Smoke after merge (host)

```bash
python3 tests/unit/test_panel_empty_center_static.py; echo "true rc=$?"
python3 tests/unit/test_pause_overlay_publish_static.py; echo "true rc=$?"
python3 tools/readback_overlay_text.py --selftest-pause-localize; echo "true rc=$?"
make arm-plexd; echo "true rc=$?"
# grep must find:
rg -n "publishPausedOverlayFrame|pause overlay DDR|panelBg|frame_ledger" arm/misterplexd/media_player.cpp host/libmisterplex/playback_overlay.hpp
```

## Deploy binary identity

Pre-merge candidate: **md5 `14b00f600aa62ac0948e24273e7030a1`**.  
Post-merge rebuild will change md5 — parent re-prints and scores that hash.
