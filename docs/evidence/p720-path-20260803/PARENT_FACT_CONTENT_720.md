# Parent FACT re-aim — content 720p (not output)

## Measurement identity

| Label | Value |
|-------|--------|
| Worktree | `w-path-720p` |
| This note SHA | run `git rev-parse --short HEAD` in path worktree |
| Present RTL land (parent) | **`3fa01a9b`** — measured via `git show 3fa01a9b:…` (not shared dirty tree) |
| `origin/main` at write time in this clone | may lag; prefer quoted SHA `3fa01a9b` |

## FACT 1 — 720p present path on main @ L2

Parent merged default-off present modules. At **`3fa01a9b`**:

- `files.qip` includes `present_video_timing_720p`, `present_*`, `plex_present_geom_mux`, …
- `Plex.qsf` still `FRAME_W=640` `FRAME_H=480`; enable macros commented
- `Plex.sv` `.use_frame_store(1'b0)` unchanged (force-bars **off**, not store disable)
- Ladder: **L2 IN_FILES_QIP**, not L4 ENABLED

Path lane owns **no** of those RTL modules. Path host stack remains **L0 vs origin/main** until parent sequences land.

## FACT 2 — HDMI already 720p; target is CONTENT

Parent measured live `/media/fat/MiSTer.ini`: `direct_video=0`, `vga_scaler=1`, `video_mode=0`.

In-repo SoT (`docs/crt-lcd-matrix.md`, `docs/display-resolution.md`):

| video_mode | signal |
|------------|--------|
| **0** | **1280×720@60** |

ascal upscales core **FRAME 640×480** content into that glass. Parent HDMI capture 1438×1074 ≈ 4:3 pillar in 16:9 confirms.

**Path task does NOT retire.** Delivery half was always “genuine 1280×720 pixels through host without ARM upscale.” Restated:

> Make core/daemon **produce** 1280×720 content so ascal is 1:1 quality, not “make HDMI 720p.”

### Implications for path

| Topic | Before | After FACT 2 |
|-------|--------|----------------|
| Glass B | assumed unknown | **already 720p60** on lab |
| DEFAULT_ASSUMED | likely `[Plex]` miss | lab mode is under **`[MiSTer]`**; parser must fall back; **preset 0 must be 1280×720** (osd table had wrong `{0,640,480}`) |
| Authoring A | 624×480 floor | stay floor until couple/applied DE or FRAME_1280 L4; **do not** author 1280 chrome into 624 bank just because glass is 720 |
| Route-B host emit ≤960 | still valid for 1ppc content until multi-pixel + stride | glass 720 via ascal remains live route |
| HPS_BANK_STRIDE 512KiB | w-mem blocker for 1.38 MiB I420 | path already has Option-C 720 map constants; product enable needs w-mem guard |

## Implemented this tip (path)

1. `host/libmisterplex/mister_video_mode.hpp` — correct presets + `[MiSTer]` fallback  
2. `host/libmisterplex/overlay_canvas.hpp` — SIZE A resolve; glass≠bank NEG  
3. `paintIdle` logs `idle overlay canvas=… authoring=… output=…`  
4. `tests/unit/test_mister_video_mode.cpp` — mode0=1280, glass≠bank, couple→1280 authoring  

## Ladder (path modules)

| Unit | ON_MAIN | QIP | INST | EN | Level | Ref |
|------|---------|-----|------|-----|-------|-----|
| present_* (osd) | yes @3fa01a9b | yes | (parent) | no | **L2** | parent |
| `mister_video_mode.hpp` | no | n/a | n/a | n/a | **L0** path branch | this tree |
| `overlay_canvas.hpp` | no | n/a | n/a | n/a | **L0** | this tree |
| status applied DE read | no | — | — | — | not built | needs w-mem |

## Not retired

- PMS true 720 / DP / vf identity / PLXG couple / Route-B caps — still path delivery work  
- Bank stride overflow guard — **w-mem**  
- FRAME_W=1280 L4 — parent fit HELD  
