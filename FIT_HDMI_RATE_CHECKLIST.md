# FIT_HDMI_RATE_CHECKLIST — prove ~24 Hz after Cut B fit

**Owner lane:** w-clock (Wave-3 checklist only)  
**Executor:** parent / lab with device token + exclusive RBF  
**Date:** 2026-08-04  
**No device in this lane. No FIT_GO. No invented PASS.**

Companion: `LAND_CUT_B.md` (w-integ), `docs/PRESENT_CLK_PIX_PLL_ENABLE.md`, `tools/measure_refresh_hz.py`.

---

## 0. Why this exists

Cut B enables CEA-pack 720p with `PRESENT_CLK_PIX_PLL` so pixel rate is **29.700 MHz**, not `clk_sys` 20 MHz.

| Path | Math | Expected glass refresh |
|------|------|------------------------|
| **Cut B PLL ON** | `29_700_000 / (1650 × 750)` | **24.000 Hz** |
| **16 Hz trap** | `20_000_000 / (1650 × 750)` | **≈ 16.16 Hz** (MULTI + CEA totals, no working pix PLL) |
| Geometry-only still | any | **NOT** a refresh proof |

Parent scoreboard already requires: *HDMI rate proof after RBF (150-frame warm-up)*.  
A 720p still, a green define-parity, or STA Fmax alone **must not** be scored as 24 Hz PASS.

---

## 1. Pre-flight (RTL / land — no grabber yet)

### 1.1 CLK_VIDEO on PR #17 tip (already landed — do not re-cherry-pick)

Verified on `origin/integ/720p-compose` @ **`970889df`**:

```text
# git show origin/integ/720p-compose:fpga/Plex_MiSTer/Plex.sv | rg CLK_VIDEO
`ifdef PRESENT_CLK_PIX_PLL
assign CLK_VIDEO = clk_pix_pll;
`else
assign CLK_VIDEO = clk_sys;
`endif
```

Also on same tip: `.clk_pix(clk_pix_pll)` under `PRESENT_CLK_PIX_PLL`.  
w-clock SHA `7a8fc578` is **content-equivalent / SHA-not-landed** (`LAND_CUT_B` §0 / §1.D) — **skip cherry-pick**.

### 1.2 Cut B QSF must be the fitted netlist

```tcl
PRODUCT_NO_STUB=1
FRAME_W=1280 FRAME_H=720 FRAME_LINES_16=1
PRESENT_MULTI_PIXEL=1 PRESENT_PX_PER_CLK=2
PRESENT_CLK_PIX_PLL=1
SDC_FILE Plex_clk_pix.sdc
FABRIC_FRAME_DMA=1
# ABSENT: PLEX_PRESENT_720P_L4, PRESENT_CLK_PIX_74_25, BEAM_960 hollow 640x480
```

PLL SoT: `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` default out3 `"29.700000 MHz"`.

### 1.3 Miss codes that void rate claims before HDMI

| Code | If true → do not claim 24 Hz |
|------|------------------------------|
| M3 | PLL flag ON but STA general[3] missing / 0 MHz |
| M4 | clk_pix Fmax &lt; 29.70 |
| M6 | `Plex_clk_pix.sdc` omitted |
| M7 | `CLK_VIDEO` still on `clk_sys` while MULTI emits on `clk_pix` |
| — | Fit never ran / wrong RBF / L4 compact path stacked with MULTI |

---

## 2. Lab preconditions (parent)

| Item | Requirement |
|------|-------------|
| Device token | Parent holds device |
| RBF | Cut B fit artifact only (digest + provenance logged) |
| Core | Plex loaded; not stale wrong RBF |
| Grabber | `/dev/video0` (or env override) present |
| Exclusive open | `fuser -v /dev/video0` clean of OBS/preview/other agents |
| Host | Prefer misterplexd with `MISTERPLEX_PRODUCT_DDR_720P=1` when scoring content path; **idle beam alone is enough for refresh Hz** if PLL drives the beam |
| Scratch | Project-local only (`.agent-work/…`) — never score from `/tmp` alone |

**Do not** start rate scoring if:

- device busy → `DEVICE_BUSY` (never report 0.0 Hz)
- no `/dev/video0` → `NO_DEVICE` / `NO_DATA`
- RBF provenance unknown

---

## 3. Measurement recipe (SoT tool)

**Tool:** `tools/measure_refresh_hz.py`  
**Principle:** modal inter-frame PTS Δ after warm-up → `refresh_hz = 1 / modal_dt`.  
**Forbidden:** inventing PASS from empty capture, mean luma, or md5 “distinctness”.

### 3.1 Parent-mandated 150-frame warm-up

Default tool warm-up is **15** (MS2109 junk length). Parent WAVE3 mandate is **150-frame warm-up** — force it:

```bash
# From repo root of the fitted tree (device token held).
# Capture enough frames AFTER warm-up for ≥10 usable Δt samples.
# 150 warm-up + ≥60 scored → --frames ≥ 210; use 300 for margin.

OUT=.agent-work/w-clock/hdmi_rate_cutb_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"

# Stamp pair required for scoreable MEASURED (see artifact_stamp).
# Parent fills real artifact digests; do not pass fake stamps.

python3 tools/measure_refresh_hz.py \
  --device /dev/video0 \
  --size 1280x720 \
  --frames 300 \
  --warmup 150 \
  --rbf-md5 "$RBF_MD5" \
  --daemon-md5 "$DAEMON_MD5" \
  --decode-src cutb_hdmi_rate \
  2>&1 | tee "$OUT/measure_refresh_hz.txt"

# Alternate: --rbf-file /path/Plex.rbf --daemon-file /path/misterplexd
# or --stamp-json from tools/avsync_stamp_artifacts.sh
# Without a valid stamp pair the tool returns UNSCORED (rc=77) — do not --allow-unstamped to fake PASS.
```

### 3.2 Manual capture fallback (same math)

Only if the tool cannot run; still **no invent PASS**:

```bash
DEV=/dev/video0
SIZE=1280x720
FRAMES=300
WARMUP=150
MKV="$OUT/cap.mkv"

# Exclusive check
fuser -v "$DEV" && exit 2   # busy → DEVICE_BUSY, not 0 Hz

ffmpeg -v error -f v4l2 -input_format mjpeg -video_size "$SIZE" \
  -i "$DEV" -frames:v "$FRAMES" -c copy -y "$MKV"

ffprobe -v error -select_streams v:0 -show_entries frame=pts_time \
  -of csv=p=0 "$MKV" > "$OUT/pts.txt"

# Then: discard first WARMUP pts; modal Δt on remainder; hz = 1/modal_dt
# Empty pts / short series → NO_DATA (never 0.0 Hz PASS)
```

### 3.3 What to log (every run)

Copy into evidence (or parent status):

```text
device=
rbf_md5=          # or provenance digest
rbf_sha=          # git tip that produced RBF
qsf_cut_b=        # yes/no list of macros from §1.2
capture_size=
frames_requested=
warmup_discarded=150
pts_n=
dt_n=
modal_dt_s=
refresh_hz=
refresh_hz_der=1/modal_pts_dt_after_warmup
verdict=          # MEASURED | NO_DATA | DEVICE_BUSY | UNSCORED
fuser=
stamp_pair=
```

---

## 4. Scoring bands (honest)

Parent assigns **PASS / FAIL / UNSCORED** only from MEASURED numbers + provenance.

| Observed `refresh_hz` | Interpretation | Score |
|----------------------:|----------------|-------|
| **23.5 … 24.5** | PLL path consistent with 29.70 / (1650×750) | **RATE_PASS** (refresh only) |
| **15.5 … 16.8** | **16 Hz trap** — CEA totals on 20 MHz / PLL not on glass path | **RATE_FAIL_TRAP16** |
| **~30** or **~60** (stable) | Grabber reclock / scaler / wrong size / not core beam | **UNSCORED_OR_INVESTIGATE** — not 24 Hz proof |
| modal_dt ~ 0 / empty / busy | No measurement | **NO_DATA / DEVICE_BUSY** — **not PASS** |
| STA green only, no HDMI | — | **not a rate claim** |
| Single PNG still “looks 720p” | Geometry | **not a rate claim** |

**Tolerance note:** band 23.5–24.5 is for grabber PTS quantization and USB jitter.  
If modal lands **exactly** on 24.000 with long span, still record MEASURED numbers — do not upgrade language to “CEA certified”.

### Explicit non-claims

- **RATE_PASS ≠ unique content 24 fps.** PPC/feed walls can underrun while the **beam** still runs at 24 Hz.
- **RATE_PASS ≠ lipsync PASS.** Use AVSYNC tools separately.
- **RATE_PASS ≠ Fit/STA PASS.** Fit is parent FIT_GO; this checklist is post-RBF glass rate only.
- **P3 Fmax ≥ 29.7 ≠ measured 24 Hz.**

---

## 5. Discrimination quick tests (optional, after MEASURED)

Use only to explain FAIL / GRABBER cadence — not to invent PASS.

| Hypothesis | Check |
|------------|--------|
| Trap16 | Compare to `20e6/1_237_500 ≈ 16.16`; re-verify QSF has `PRESENT_CLK_PIX_PLL=1` + SDC + RBF from that fit |
| M7 domain split | Re-read fitted tree `Plex.sv`: `CLK_VIDEO` must be `clk_pix_pll` under PLL flag (already on #17 @ `970889df`) |
| 74.25 / 60 Hz path | Confirm `PRESENT_CLK_PIX_74_25` **absent** on fitted QSF |
| Grabber locked wrong size | Retry `--size 1280x720` and `1920x1080`; log both if they disagree |
| Busy grabber | `fuser -v /dev/video0`; never zero-fill |
| **Grabber reclock (~31.25)** | MS2109 UVC has **no 24 Hz interval**. Modal ~31.25 (`dt=0.032`) or modal tracking `--framerate` 20/30/60 with `span_hz≈request` is **USB/UVC delivery**, not glass. Tool: `cadence_class=GRABBER_OR_USB_CADENCE`, `rate_pass_eligible=0`. Cross-RBF invariance (STALE + cut-b same modal) seals it. |

**Discriminator recipe** (grabber free; same stamp pair):

```bash
# Primary (150 warm-up, ≥300 frames after warm-up → --frames ≥450)
python3 tools/measure_refresh_hz.py --device /dev/video0 --size 1280x720 \
  --frames 450 --warmup 150 --discriminate \
  --rbf-md5 "$RBF_MD5" --daemon-md5 "$DAEMON_MD5" --decode-src cutb_hdmi_rate

# Multi-request probe — if modal follows --framerate, glass is NOT observed
for FR in 20 30 60; do
  python3 tools/measure_refresh_hz.py --device /dev/video0 --size 1280x720 \
    --framerate $FR --frames 120 --warmup 30 --discriminate \
    --rbf-md5 "$RBF_MD5" --daemon-md5 "$DAEMON_MD5" --decode-src probe_fr$FR
done
# Lab: fr30 → modal 31.25 span~30; fr60 → modal 62.5 span~60; fr20 → span~20
# Glass candidate only if modal ∈ 23.5..24.5 independent of --framerate
```

---

## 6. Operator sequence (parent, after Cut B RBF)

```text
[ ] Land stack per LAND_CUT_B (define-parity rc=0 on final tip)
[ ] Exclusive FIT_GO Cut B QSF; keep provenance
[ ] Deploy RBF; record md5/sha
[ ] Confirm /dev/video0 free
[ ] measure_refresh_hz --frames 300 --warmup 150 --device /dev/video0
[ ] If VERDICT=MEASURED and 23.5≤hz≤24.5 → RATE_PASS (refresh)
[ ] If ~16.16 → RATE_FAIL_TRAP16; do not ship as 24 Hz
[ ] If NO_DATA/BUSY → fix lab; do not score PASS
[ ] Attach measure_refresh_hz.txt + RBF provenance to evidence
[ ] Only then consider content/publish/AV checks
```

---

## 7. Wave-3 verification record (w-clock, no device)

| Item | Result |
|------|--------|
| Ref | `origin/integ/720p-compose` @ `970889df` |
| Command | `git show origin/integ/720p-compose:fpga/Plex_MiSTer/Plex.sv \| rg CLK_VIDEO` |
| `CLK_VIDEO` under `PRESENT_CLK_PIX_PLL` | **`assign CLK_VIDEO = clk_pix_pll`** |
| Else branch | `assign CLK_VIDEO = clk_sys` |
| `.clk_pix` | `clk_pix_pll` under same flag |
| Device / fit this lane | **NONE** — checklist only |
| PASS invented? | **NO** |

---

## 8. Related

- `LAND_CUT_B.md` — land order; refresh line “geometry alone ≠ refresh PASS”
- `docs/PRESENT_CLK_PIX_PLL_ENABLE.md` — enable recipe, anti-16 Hz, M1–M7
- `tools/measure_refresh_hz.py` — PTS modal rate; busy≠0; empty=NO_DATA
- `scripts/hdmi_capture_idle.sh` — still-frame warm-up (visual), **not** rate SoT
- `Memory/lab/agents/w-clock.txt` — WAVE3 evidence
