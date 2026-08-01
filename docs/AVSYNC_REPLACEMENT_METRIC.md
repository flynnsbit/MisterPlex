# Replacement for retired `av_drift_ms` (S3 source-confirmed)

## S3 is confirmed from source (not only suspected)

`arm/misterplexd/media_player.cpp` present loop (Hold path):

```cpp
const int64_t drift = misterplex::avDriftMs(clockMs, frameMs);
avDriftMs_.store(drift);   // published telemetry
const AvAction act = avDecide(drift, leadMs, dropMs, dropRun);
if (act == AvAction::Hold) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    continue;              // re-sample until not Hold
}
```

`avDecide` (`host/libmisterplex/av_clock.hpp`):

```cpp
if (driftMs + leadMs < 0)
    return AvAction::Hold;
```

**Consequence:** `avDriftMs_` is written **inside** the loop that HOLDs until
`drift + leadMs >= 0`. Steady-state published `av_drift_ms` is the controller
deadband around setpoint `−leadMs`, **always biased negative** when locked.
It is **not** independent glass lipsync. Telemetry already labels
`av_drift_role=servo_error_not_lipsync`.

**Pacing wait correction (rd-review):** `pacing_wait_us` is **not** a scheduled
16.68 ms sleep. It is the **sum of 2 ms Hold sleeps** in that loop. Read-block
happens *before* the loop; time in `read()` removes Hold iterations —
`read_block + pacing_wait` is conserved by construction. Do not treat the split
as independent budgets.

**LEAD ∈ {20,40,80} test** remains useful as **confirmation**, not discovery.
Pre-reg bands: see `docs/AVSYNC_S3_LEAD_FALSIFIER.md`.

---


## Parent device confirmation (2026-08-01)

S3 **CONFIRMED** on silicon. See `files/prereg/RESULT_S3_av_drift_is_setpoint.md`.

| LEAD | median | min | note |
|-----:|-------:|----:|------|
| 20 | −6 | −16 | median **missed** P_MEDIAN [−22,−12] (toward 0) |
| 40 | −32 | −40 | in band |
| 80 | −72 | −79 | in band |

**min ≈ −LEAD** all arms — hard deadband edge. Falsifier (stuck −45…−15) did not fire.
A/V sync status: **UNSCORED** until HDMI flash↔beep on marker fixture.

## HARD POSITIVE — grabber HAS audio (measured this host, now)

Parent hypothesis “video only, no audio path” is **false on this workstation**.

```
$ arecord -l ; echo "true rc=$?"
**** List of CAPTURE Hardware Devices ****
card 0: MS2109 [MS2109], device 0: USB Audio [USB Audio]
true rc=0

$ cat /proc/asound/cards
 0 [MS2109         ]: USB-Audio - MS2109
                      MacroSilicon MS2109 at usb-0000:00:14.0-3.1, high speed

$ v4l2-ctl --list-devices
UVC Camera (534d:2109): ... /dev/video0   # SAME usb-0000:00:14.0-3.1

$ lsusb -d 534d:2109 -v | … 
  bFunctionClass 1 Audio
  wTerminalType 0x0602 Digital Audio Interface

$ arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 1 …/alsa_probe_now.wav
true rc=0
-rw-r--r-- 192044 bytes   # = 48000*2*2*1 + 44 WAV header
```

**Valid lipsync IS achievable** with current hardware: one `ffmpeg` process,
v4l2 `/dev/video0` + ALSA `hw:0,0`, shared wallclock timestamps.

---

## Replacement metric (outside the daemon)

| Field | Definition |
|-------|------------|
| **Name** | `hdmi_lipsync_offset_ms` |
| **Formula** | `(t_audio_onset − t_video_flash) × 1000` |
| **Sign** | **positive = audio LATE** (lags video); negative = audio EARLY |
| **Instrument** | `tools/avsync_measure_hdmi.py` |
| **Capture** | single ffmpeg Matroska: `-f v4l2 … -i /dev/video0` + `-f alsa -i hw:0,0` with `-use_wallclock_as_timestamps 1 -copyts -start_at_zero` |
| **Warm-up** | discard first **20** frames (caller default; garbage uniform frames) |
| **Duration** | ≥ **30 s** usable after warm-up for short assets; **60 s** preferred; long soak 900–1200 s for slope |
| **Fixture period** | **2.000 s** (rk=20/21/27 class) or **1.000 s** (legacy blip) — pass `--marker-period-s` |
| **Min pairs** | ≥ 15 (30 s @ 2 s markers) |
| **Absolute** | without known-zero cal: tag **`raw_uncalibrated`** (grabber path delay B unknown) |
| **Attributable** | **same-rig Δ** (e.g. LEAD A/B, seek step, +100 ms twin) and **slope_ms_per_s** cancel B |
| **Forbidden GT** | `av_drift_ms`, `clock=av-lock`, supply_bucket alone |

Host red/green (already measured on this branch):

| Pair | Δmedian | rc |
|------|--------:|---|
| AudioID 0 vs +100 ms | **+99.29 ms** | 0 |
| GlassAV 0 vs +100 ms | **+100.00 ms** | 0 |

If live grabber returns `flashes=0 beeps=0`, that is **fixture/display/capture**, not “no audio hardware”. Discriminator: `no_flash_class=DISPLAY_FLAT|WINDOW_TOO_SHORT|THRESHOLD_NO_TRIGGER`.

---

## Why existing live captures went black (mean_luma=7, flashes=0, beeps=0)

Possible causes (instrument already classifies):

1. **Wrong asset** — real BBB / OCR / idle has no full-frame flash+beep.
2. **Display flat** — DDR/publish not painting (prior parent lab wedge).
3. **Window too short** after warm-up for marker period.
4. **Audio path busy / wrong card** — beeps=0 with flashes>0 is different failure.

**Required cast for lipsync:** ratingKey **20** (offset 0) or **21** (+100), or bank GlassAV with markers every 2 s — **not** generic BBB without markers.

---

## Fixture requirements for w-asset480 (concrete — relay now)

Apply to **every** geometry in the new set (624×350, 426×240, 624×480, 640×480,
720×480, 624×352) at **24.000 and 30.000** fps where generated.

### A/V transient (mandatory)

| Parameter | Value | Rationale |
|-----------|------:|-----------|
| Period | **2.000 s** exact | matches rk=20/27; enough pairs in 60 s |
| Design A/V offset | **0.000 ms** on primary; twin **`_audioPlus100ms`** with audio delayed **+100.0 ms** | instrument RED/GREEN |
| Flash body | **full-frame white**, luma peak **≥ 220** (8-bit), floor body **≤ 20** | grabber mean~7 dark; need large contrast |
| Flash duration | **≥ 2 content frames** @ asset fps (≥ 2/24 ≈ 83 ms @24) | MS2109 ~30 fps capture; need ≥2 hot capture samples (margin gate) |
| Flash shape | **step** preferred (hard edge) OR linear ramp ≥4 frames centered on marker | step: instrument uses first-hot PTS; ramp: thr mid = beep |
| Beep | **1 kHz**, **50 ms**, peak **−1 dBFS to −3 dBFS**, **1 ms linear attack** | onset detector stable |
| Alignment | beep onset = flash design time (offset 0) or +100 ms (twin) | file PTS aligned before encode |
| Encode | H.264 **Constrained Baseline**, `has_b_frames=0`, `r_frame_rate=24/1` or `30/1` **exact** (not 23.976) | ERROR 17 |
| Duration | **≥ 120 s** per geometry (prefer **600 s** for one 480p long); plus100 twin may be 60–120 s | pairs for slope |
| Audio codec | AAC 48 kHz stereo OK if file verify recovers ±2 ms; prefer PCM in mezzanine | host verify first |

### Burned-in counter (mandatory — OCR hallucination fix)

w-instr: yellow counter on white flash is unreadable → OCR **hallucinates**.

| Parameter | Value |
|-----------|--------|
| Every frame | counter drawn **with no enable= guard** (including flash frames) |
| On flash frames | **dark text (black or deep blue) on white**, **or** yellow text inside an **opaque black box** (≥4 px pad) with **1–2 px white outline** optional |
| Off flash | yellow or white text with **black outline ≥2 px** on dark body |
| Format | `G n=DDDDDD` monotonic; optional `c=C` chroma chip |
| Placement | top-safe; outside bottom ID bar if bar used; **never** only yellow-on-white |

### Geometry notes

- Full-bleed where claimed (no unintended letterbox that shrinks flash area below detector ROI if ROI is full-frame mean — full-frame flash still wins).
- 240p tier: same flash/beep; counter scale readable at 426×240.

### Deliverables from w-asset480

1. File pair `*_avmark_p2s.mp4` + `*_avmark_p2s_audioPlus100ms.mp4` per geometry/fps.
2. Host verify before PMS scan:
   ```bash
   python3 tools/verify_avsync_glass_fixture.py --mp4 ZERO --expect-offset-ms 0 --tol-ms 5 --period-s 2
   python3 tools/verify_avsync_glass_fixture.py --mp4 PLUS --expect-offset-ms 100 --tol-ms 5 --period-s 2
   ```
3. PMS ratingKeys published in playbook.

---

## Parent LEAD confirmation (still run)

```text
MISTERPLEX_AV_PRESENT_LEAD_MS=20|40|80   # env; conf not modified
# banner: AV_PRESENT_LEAD_MS=env:N
# grep av_drift_ms= → tools/avsync_score_lead_s3.py
```

Expected if source model holds: band tracks `−LEAD`. That **confirms retirement**;
it does **not** create a lipsync number. Lipsync number = HDMI measure on rk=20+.
