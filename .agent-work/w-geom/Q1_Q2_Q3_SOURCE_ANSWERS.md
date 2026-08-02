# Q1 / Q2 / Q3 — source answers (host-only)

Branch tip at write: see `git log -1`. No device claims.

---

## Q1 — Why `618` not `624`?

### Where 618 is defined

```11:24:host/libmisterplex/ddr_frame_layout.hpp
//   coded 624x480  — H.264 payload and DDR bank layout
//   display 618x480 — after right crop of 6
//   presented 640x480 — VGA scanout after 11+11 pillarbox
constexpr CodedWidth kPlex480pCodedWidth{624};
...
constexpr DisplayWidth kPlex480pDisplayWidth{618};
...
constexpr int kPlex480pCropRight = 6;
```

Product geometry builder:

```192:204:host/libmisterplex/ddr_frame_layout.hpp
inline DdrFrameGeometry plex480pDdrFrameGeometry() {
    ...
    g.crop_right = kPlex480pCropRight;  // 6
    ...
}
```

RTL pin: `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` → `DDR_FRAME_DISPLAY_WIDTH = 618`.

### Why 6 / 618 (not off-by-one)

PMS H.264 SPS frame crop (docs + measured baseline):

- `coded=624x480` (= 39×30 macroblocks)
- `crop_lrtb=0,3,0,0` with `crop_unit=2x2`
- display width = 624 − (3 × 2) = **618**

So **618 is intentional**: the **visible H.264 crop / silicon display window**, not a FOAR “fit box” and not chroma rounding. Coded bank stays **624**; I420 reader bytes = `624×480×1.5 = 449280` (parent’s 624×720 is the same: 624×480×1.5).

### How 618 enters the live filter string

`media_player` freezes vf from DDR geometry:

```2877:2897:arm/misterplexd/media_player.cpp
const int rawDisplayW = ddrGeometry.display_width.get();  // 618 on product
...
vfReq.display_w = rawDisplayW;
vfReq.display_h = rawDisplayH;
vfReq.crop_left = ddrGeometry.crop_left;
```

**Legacy defect (device still showing it):** FOAR *into display* 618 then pad to 624:

```159:206:host/libmisterplex/ffmpeg_vf.hpp
// LEGACY buildScalePadCropped → scale=618:480:FOAR=decrease,pad=624:480:...
```

**Tip product (`e96dabae`+):** non-exact path FOARs into **coded 624** via `buildScalePadCentered`; bank-exact uses `crop=618:480,pad=624:480` (crop is correct use of 618).

```468:483:host/libmisterplex/ffmpeg_vf.hpp
// Non-exact: FOAR into CODED bank (624x480), never into display 618.
append(buildScalePadCentered(req.coded_w, req.coded_h, flags));
```

| Use of 618 | Intentional? |
|------------|--------------|
| Present/RTL display width, crop_right=6 | **Yes** |
| `crop=618:480` then pad to coded | **Yes** (keeps 480 rows) |
| `scale=618:480:FOAR=decrease` | **Defect** (destroys rows); fixed on tip; live cmdline = old binary / undeployed tip |

Host gate: `tests/unit/test_ffmpeg_vf.cpp` + `test_b2_b5_source_wiring.sh` require product vf **not** contain `scale=618:480` FOAR.

---

## Q2 — Can `measured=` take multiple values in one session?

### Single ffmpeg stderr pump — YES, multi-update is coded

```1489:1575:arm/misterplexd/media_player.cpp
if (g.w == lastInW && g.h == lastInH)
    continue;
const bool changed = (lastInW > 0 || lastInH > 0);
lastInW = g.w;
lastInH = g.h;
measuredDeliveryW_.store(g.w);
measuredDeliveryH_.store(g.h);
...
(changed ? " MID_STREAM_CHANGE=1" : " MID_STREAM_CHANGE=0")
...
if (changed) {
    log("ERROR media: MEASURED_DELIVERY mid-stream change — play-time "
        "geometry guard cannot rebuild vf; ...");
}
```

**Confirm:** one ffmpeg process **can** store different `measuredDeliveryW_/H_` values over time whenever a **new** Input/Stream Video WxH banner line parses different from `lastInW/H`. First observation sets `MID_STREAM_CHANGE=0`; second different size sets `MID_STREAM_CHANGE=1` and ERROR.

**Does not prove PMS changes mid-stream** — only that the daemon anticipates it. Alternate sources of multiple WxH lines in one stderr stream (without true mid-stream switch): multiple `Stream #` lines, re-printed banners, or mis-classified lines. Output lines go to `MEASURED_OUTPUT` and do **not** update `measuredDelivery*`.

### One session vs many sessions

- `measuredDeliveryW_/H_` reset to 0 at each rawvideo play start (`media_player.cpp` ~3198–3199).
- New daemon process ⇒ new session; N greps across respawns are **not** one observation.
- Parent’s three values (312×240, 624×480, 624×350) in one contaminated window are **consistent with multi-session** **or** multi-update in one ffmpeg; settle with `MID_STREAM_CHANGE=` and pid/playGen in the same log slice.

### Play-time geometry guard cannot rebuild vf

Plan is frozen at play start (`buildFfmpegVideoFilter` once). Mid-stream change is logged; vf is **not** rebuilt. That is a real hazard class for `identity_skip=1`; FORCE_SCALE / crop_pad keeps **output** at coded bank while filters stay live.

### Is `624×350` publish-safe?

| Check | 624×350 |
|-------|---------|
| I420 even dims (`yuv420pFrameBytesWH`) | **Yes** (350 even) → 327600 B |
| MB-aligned for `ddrFrameStoreAcceptsResolution` | **No** — height 350 & 15 ≠ 0 (`ddr_frame_layout.hpp:511`) |
| DDR product reader | Always **coded bank** 624×480 / 449280 B, not measured size |

So: can be **measured** and used for desync/telemetry; cannot be a legal **STREAM coded** accept size; rawvideo path still publishes **scaled/padded** frames at bank size when FORCE_SCALE/crop_pad/FOAR is on. Publishing raw 327600-byte frames into a 449280 reader without scale = pipe desync (identity_skip path).

`624×350` is **not** MB-aligned; it is a **display/FOAR/DAR-class size**, not a legal H.264 MB frame height for the accept helper.

---

## Q3 — Daemon self-exits `rc=0`

### Every `main()` path that returns 0

| Site | Condition | Healthy playback? |
|------|-----------|-------------------|
| `main.cpp:269-271` | `--help` → `deathBreadcrumbExit(0)` + `return 0` | N/A (no loop) |
| `main.cpp:878` | `--play-file` lab success → `exitReported(0, "lab-play-file-done")` | Lab only; not product companion loop |
| `main.cpp:1670` | Product loop: `return exitReported(0, why)` after `while (!g_stop)` ends | **Only after signal** |

Non-zero product exits: lab fail (1), lab zero frames (2), companion start fail (1).

### Product loop — **no** voluntary idle exit

```37:60:arm/misterplexd/main.cpp
// Product main loop exits ONLY when g_stop is set. The only writers are the
// SIGINT/SIGTERM handlers ...
// Handled signals yield process exit status 0 (WIFEXITED), NOT WIFSIGNALED —
// that is why a "clean rc=0" can still be an external SIGTERM.
```

```1600:1670:arm/misterplexd/main.cpp
while (!g_stop.load(...)) { ... sleep 200ms; resumeStrandedMain; ladder; heartbeat; }
// g_stop is set only by SIGINT/SIGTERM handlers → orderly return 0.
return exitReported(0, "site=main.cpp:main_loop_g_stop sig=...");
```

Handlers: `sigaction(SIGINT/SIGTERM)` → `on_signal_info` → `g_stop=true` (`main.cpp:602-607`, `47-60`).

**There is no coded path that exits rc=0 while “healthy” without SIGINT/SIGTERM (or lab/--help).**  
Supervise `EXIT … rc=0` / `wait_st=0` is **WIFEXITED(0)** after **handled** SIGTERM/SIGINT, not proof of internal idle quit.

`scripts/plexctl.sh:189-198` documents the same:

```text
st < 128  → WIFEXITED-like (handled SIGTERM → often st=0)
st >= 128 → WIFSIGNALED-like
```

### Absence of shutdown lines in daemon log

**Absence ≠ not graceful-by-design.** Orderly path **must** emit:

```text
misterplexd: EXIT_REASON code=0 why=site=main.cpp:main_loop_g_stop sig=... si_pid=...
```

(`death_breadcrumb.cpp:237-269` — always fprintf stderr). If supervise shows rc=0 but log lacks `EXIT_REASON` / `main_loop exit pending`:

- log not the same fd/file as supervise’s `$LOG`, or
- truncated/rotated, or
- process never reached `exitReported` (hang after signal — then death file may still have async-signal-safe first witness)

**Check that settles it:** for each SUPERVISE_EXIT rc=0, read `misterplexd.death` / grep `EXIT_REASON` and `si_pid`/`sender_cmd` in supervise line (plexctl already snapshots these).

### Counter reset (soak hazard) — confirmed

Per rawvideo stream start: `droppedFrames_.store(0)` (~3076), `presentCount_ = 0` (~3200).  
Lifetime totals (`lifetimeFrames_` etc.) accumulate across streams **in-process** only; **respawn zeroes everything**.

### Host reproduction (no MiSTer)

```bash
# A) documented lab rc=0
./build/misterplexd --help
echo "true rc=$?"   # expect 0

# B) SIGTERM → product-style exit 0 (needs conf that reaches main loop;
#    if companion binds, run briefly then:)
kill -TERM "$pid"
wait "$pid"; echo "true rc=$?"   # expect 0
# stderr must contain EXIT_REASON ... main_loop_g_stop sig=15
```

Gate script: `tests/unit/test_daemon_rc0_paths.sh` (this commit).

---

## Parent ops one-liners

```bash
# Q1 after deploy tip ≥ e96dabae
tr '\0' ' ' </proc/$(pgrep -n ffmpeg)/cmdline | grep -E 'scale=|crop='
# never: scale=618:480:FOAR ; ok: crop=618:480 or scale=624:480:FOAR

# Q2
grep -E 'MEASURED_DELIVERY |MID_STREAM_CHANGE=' daemon.log

# Q3
grep -E 'EXIT_REASON|main_loop_g_stop|SUPERVISE_EXIT' supervise.log daemon.log misterplexd.death
```
