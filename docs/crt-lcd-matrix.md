# CRT / LCD display matrix checklist (Phase 5)

Lab checklist for MiSTerPlex present paths on **15 kHz CRTs** and **HDMI LCDs**. Status reflects the monorepo as of Phase 5 foundation — not a full golden visual suite.

**Practical lab rows (modes / force_bars / NTSC·PAL / pass criteria, LAB vs CRT):**  
→ **[crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md)** — P5-CRT **PARTIAL**  
→ Tick matrix marks **LAB** vs **physical CRT** separately; **no CRT PASS without hardware**  
→ Lab RBF **`dabdaeb0`**: FBAR reconfirm **PASS** (H-deploy-rcsum1); soak/DDR/cadence last measured **PASS** on prior `820484a6`; WIDE + res_csum hard **FAIL** (see lab checklist)  
→ Session sheet: [captures/menu/CRT_LCD_LAB.md](../captures/menu/CRT_LCD_LAB.md)

Related: [match-source-hz.md](match-source-hz.md), [architecture.md](architecture.md), [release.md](release.md), [captures/menu/CHECKLIST.md](../captures/menu/CHECKLIST.md).

## Output-mode sweep with `ascal` scaler (C1, 2026-07-26)

Purpose: answer whether raising MiSTer's **output** mode costs MiSTerPlex decode/present headroom while the
content remains the existing 320×240 weak-ladder stream. This is distinct from native high-resolution content:
the Plex core still presents 320×240 and MiSTer's `ascal` scaler upsamples it using HPS DDR3. The lab ini stayed
LCD-safe: `vga_scaler=1`, `direct_video=0`, `vsync_adjust=0`; modes were switched live through
`/dev/MiSTer_cmd` and the device was restored to `video_mode=5`.

MiSTer preset numbering from `/media/fat/MiSTer.ini`:

| `video_mode` | Preset |
|---:|---|
| 0 | 1280×720@60 |
| 1 | 1024×768@60 |
| 2 | 720×480@60 |
| 3 | 720×576@50 |
| 4 | 1280×1024@60 |
| 5 | 800×600@60 |
| 6 | 640×480@60 |
| 7 | 1280×720@50 |
| 8 | 1920×1080@60 |
| 9 | 1920×1080@50 |
| 10 | 1366×768@60 |
| 11 | 1024×600@60 |
| 12 | 1920×1440@60 |
| 13 | 2048×1536@60 |

Custom modelines use:

```ini
video_mode=hact,hfp,hs,hbp,vact,vfp,vs,vbp,Fpix_in_KHz
; example from the live ini:
; video_mode=1280,110,40,220,720,5,5,20,74250
; CVT/RB helper format is also accepted, e.g. video_mode=1920,1440,60,cvtrb,p13
```

### Lab method

- Media: PMS item `/library/metadata/3` ("The Garden of Delights"), resolved through the device's
  `misterplex.conf` credentials, transcoded to weak 320×240 (`decode=320x240`, `fps=25/1`). No tokens were
  written to repo files.
- Hold: 120 s per mode, plus spot retests for anomalous rows.
- HDMI sync: USB grabber `/dev/video4`, `yuyv422`, 60-frame warm-up, two captures per mode. A pass means the
  grabber returned frames and the two SHA/mean stats changed, avoiding the known stale-capture trap.
- A/V signal: `media: frames=... av_drift_ms=... drops=...` in `misterplexd.log`.
- CPU: `top -b -n2 -d2` during playback.
- Evidence generated in the local lab worktree: `captures/c1/output-mode-sweep-pms.tsv` and
  `captures/c1/output-mode-anomaly-retest.tsv`. (`captures/` is gitignored, so the TSVs are not in the repo.)

> **Method caveat.** This sweep switched modes live via `/dev/MiSTer_cmd`, which leaves `MiSTer.ini`
> untouched. The **supported** way to change output modes is to edit `[Plex] video_mode` in
> `/media/fat/MiSTer.ini` and soft-reboot — that is what `scripts/sweep_plex_video_modes.sh`
> does, including a guaranteed restore of the original ini. Prefer that script for any repeat or
> extension of this sweep; the numbers below stand, but reproduce them through the ini path.

### Results

VGA note: the physical VGA display in this lab is specified only up to 800×600@60. With `vga_scaler=1`, VGA
follows the same scaler mode as HDMI; therefore only 640×480@60 and 800×600@60 are inside the known VGA envelope.
Higher rows were not marked VGA PASS without an instrumented VGA capture/eyes-on confirmation.

| Mode | HDMI sync | VGA expectation | 120 s playback result | CPU during playback | Notes |
|---:|---|---|---|---|---|
| 5 — 800×600@60 | PASS | PASS / baseline envelope | drops 0, drift −32…−21 ms | 0% idle | Current LCD/VGA-safe default. |
| 1 — 1024×768@60 | PASS | expected out-of-range | drops 1, drift −40…−20 ms | 0% idle | Clean HDMI; not for the user's VGA panel. |
| 0 — 1280×720@60 | PASS | expected out-of-range | drops 0, drift −40…−20 ms | 0% idle | Clean HDMI 720p60. |
| 8 — 1920×1080@60 | PASS | expected out-of-range | drops 0, drift −38…−25 ms | 0% idle | Clean HDMI 1080p60. |
| 6 — 640×480@60 | PASS | PASS / within envelope | retest drops 2, drift −40…−20 ms | 0% idle | Safe fallback; first run had a transient 25-drop burst. |
| 2 — 720×480@60 | PASS | expected out-of-range | drops 1, drift −40…−21 ms | 0% idle | HDMI sync OK. |
| 3 — 720×576@50 | PASS | expected out-of-range | drops 0, drift −40…−21 ms | 0% idle | HDMI sync OK; PAL-friendly. |
| 7 — 1280×720@50 | PASS | expected out-of-range | drops 0, drift −35…−24 ms | 0% idle | Clean HDMI 720p50. |
| 4 — 1280×1024@60 | INCONCLUSIVE | expected out-of-range | retest drops 1, drift −40…−20 ms | 0% idle | Playback OK, but HDMI capture failed to relock on retest; do not expose by default. |
| 10 — 1366×768@60 | PASS | expected out-of-range | retest drops 1, drift −40…+40 ms | 0% idle | HDMI sync OK, but less universal than 720p/1080p. |
| 11 — 1024×600@60 | PASS | expected out-of-range | drops 2, drift −40…−20 ms | 0% idle | HDMI sync OK; niche panel mode. |
| 9 — 1920×1080@50 | PASS | expected out-of-range | drops 1, drift −40…−20 ms | 0% idle | Clean HDMI 1080p50. |
| 12 — 1920×1440@60 | PASS | expected out-of-range | retest drops 2, drift −40…−20 ms | 0% idle | Above the requested 1080p ceiling; not a default user-facing mode. |
| 13 — 2048×1536@60 | PASS | expected out-of-range | drops 3, drift −40…−20 ms | 0% idle | Above the requested 1080p ceiling; not a default user-facing mode. |

### Recommendation

Expose **HDMI 800×600@60, 1024×768@60, 1280×720@60/50, and 1920×1080@60/50**. Keep
**800×600@60** as the VGA/LCD-safe default and offer **640×480@60** as a conservative VGA fallback. Do not spend
RBF/RTL effort on native 720p/1080p scanout for the current 320×240 path: the sweep shows output-mode changes do
not materially affect ARM load or A/V lock; decode remains the bottleneck and is already CPU-saturated at
320×240.

## Display strategies

| Strategy | When | Status |
|----------|------|--------|
| Fixed display Hz + FPGA cadence | Default for both CRT and LCD | **Ship** — OSD **Content FPS** + `present_cadence` |
| Match source Hz (modeline ≈ content) | Multi-rate CRT or VRR-ish LCD | **TODO** — conf keys logged only; no switchres |
| ARM fb0 + ascal | Phase 2 cast without Plex core | **Ship** — continuous RGB24 → `/dev/fb0` |

## Hardware matrix

| Output | Typical path | Present path | Notes |
|--------|--------------|--------------|-------|
| **HDMI LCD** 60 Hz | Direct DE10 HDMI | `PRESENT=fb0` or Plex core frame store | Easiest lab path; use Content FPS 24 for film cadence |
| **HDMI LCD** 50 Hz | DE10 + TV Mode PAL | Same | Set TV Mode family in OSD when using Plex.rbf |
| **VGA → 15 kHz CRT** | Analog via MiSTer VGA/DAC | fb0/ascal **or** Plex.rbf | Prefer 320×240-class modelines; long VBlank for 15 kHz |
| **VGA → 31 kHz / PC CRT** | Higher line rate | Same | Less picky; 480p-class possible if ARM keeps up |
| **Y/C / component** | Board-dependent | Same as VGA family | Not separately tested in this suite |

## Content FPS vs content rate (cadence)

With **fixed 60 Hz** display (common LCD / NTSC CRT):

| Content | OSD Content FPS | Expected unique advance | Checklist |
|---------|-----------------|-------------------------|-----------|
| Film ~24p | **24** | 3:2 density on 60 Hz | [x] unit cadence **PASS**; live motion **PENDING** eyes |
| Video ~30p | **30** | 2:2 | [x] unit + OSD bits **PASS**; live **PENDING** |
| Progressive 60 | **60** | 1:1 | [x] unit + OSD bits **PASS** |
| Slow debug | **12** | sparse | [x] OSD bits **PASS**; stepped motion easy on lab |

Math (unit-tested): `content_index = floor(display_index * content_fps / display_hz)` — see `host/libmisterplex/cadence.hpp`.

## Modeline / match-source-Hz status

| Item | Status | Action for lab |
|------|--------|----------------|
| OSD Content FPS 12/24/30/60 | **done** (`Plex.sv`) | Set per title type |
| Conf `MATCH_SOURCE_HZ=off` | **parsed/logged** | Leave off |
| Conf `SOURCE_FPS=auto` | **parsed/logged** | OSD wins |
| HPS modeline switch from misterplexd | **TODO** | Use MiSTer video menu / ini for CRT |
| Ship `assets/modelines.dat` | **TODO** | Copy from mistercast-linux when wiring |
| Auto Content FPS from PMS `videoFrameRate` | **TODO** | Manual OSD today |

### 15 kHz CRT modeline families (target when switchres lands)

Borrow names/rates from mistercast-linux `assets/modelines.dat` when implementing:

| Family | Approx refresh | Use |
|--------|----------------|-----|
| NTSC 60 | ~60 Hz | Default safe CRT |
| Film 24 | ~24 Hz | True 24p without 3:2 (match-Hz on) |
| NTSC 30 | ~30 Hz | 30p native |
| PAL 50 | ~50 Hz | PAL sets |

Film/30 modes need longer vertical blanking so horizontal rate stays near **15 kHz**. Some CRTs blank at 24 Hz — if so, force match-Hz **off** and use Content FPS **24** at 60 Hz.

## PRESENT / STREAM × display checklist

| Conf | HDMI LCD | 15 kHz CRT | What to verify |
|------|----------|------------|----------------|
| `PRESENT=fb0` `STREAM=0` | [x] **PASS** (Phase 2 cast / soak family) | [ ] **PENDING** (no CRT) | Phase 2 cast golden |
| `PRESENT=both` `STREAM=0` | [x] **PASS** / exercised | [ ] **PENDING** | No regression vs fb0-only |
| `PRESENT=both` `STREAM=1` | [x] **PASS** soak wifi (D-soak4 on `820484a6` ok=6) | [ ] **PENDING** | Log: `STREAM=1 host I-slice recon` |
| `PRESENT=fpga` `STREAM=1` | [~] PARTIAL (frame store / F1; DDR B-ddr5 PASS) | [ ] **PENDING** | Needs Plex.rbf + Video source = Frame store |

## Audio checklist (all displays)

| Check | Pass criteria |
|-------|----------------|
| Single FFmpeg | `tests/hw/test_single_process.sh` — one demux for A/V |
| MrAudio | Tone/PCM on analog/HDMI audio path |
| Pause/resume | A/V both freeze and continue (`test_media_fb.sh`) |
| No 60 fps forced unique RGB | Lip-sync holds at weak ladder rates |

## Lab procedure (quick)

1. Confirm conf: `/media/fat/misterplex/misterplex.conf` (`PRESENT`, `STREAM`, `DECODE`).
2. Deploy: `./scripts/deploy_misterplexd.sh`.
3. Display under test: HDMI **or** CRT via VGA; note TV Mode / scaler.
4. Phase 2 smoke: `./tests/hw/test_media_fb.sh` + play known PMS episode.
5. If Plex.rbf: set **Content FPS** for title type; optional **Video source = Frame store** for FPGA path.
6. Soak: `SOAK_HOLD_S=8 SOAK_ROUNDS=1 ./tests/hw/test_soak.sh` (auto-uses MiSTer conf + PMS titles when token present).
7. Record: output type, PRESENT/STREAM, Content FPS, pass/fail, notes (blanking, tear, audio drop).

## Wi-Fi vs Ethernet matrix

Network path affects PMS resolve + weak-ladder fetch latency, not the present engine itself.
Lab often runs MiSTer on **wlan0** when `eth0` has no carrier (cable unplugged).

| Path | How to force | Measure | Expect |
|------|--------------|---------|--------|
| **Ethernet** | Cable in; prefer `eth0` default route | `SOAK_NET_LABEL=eth SOAK_HOLD_S=12 SOAK_ROUNDS=3 ./tests/hw/test_soak.sh` | Lower jitter; stable weak ladder |
| **Wi-Fi** | Unplug eth or lower eth metric | `SOAK_NET_LABEL=wifi …` (same soak) | OK for cast UX; watch mid-hold resource loss if AP drops |
| **Compare** | Same `SOAK_KEYS` / rounds / hold on both paths | Soak summary lines + `net snapshot:` logs | Document deltas in sign-off table |

### Script hooks

- `tests/hw/test_soak.sh` logs `net snapshot:` (default iface, IPv4, wireless quality when `wlan*`) when `SOAK_LOG_NET=1` (default).
- Set `SOAK_NET_LABEL=wifi|eth` so summary rows are greppable: `test_soak: OK … wifi`.
- `SOAK_LOG_NET=0` skips the SSH probe (useful on CI without keys).

### Operator checklist (when both links available)

1. Note `ip route` default dev on MiSTer.
2. Run soak with label for that path; record ok/fail + elapsed.
3. Switch default (plug/unplug eth, or `ip route replace default via … dev eth0`).
4. Re-run identical `SOAK_KEYS` / `SOAK_ROUNDS` / `SOAK_HOLD_S`.
5. Fill sign-off: path, label, result, notes (AP band, RSSI, cable speed).

**Lab 2026-07-24:** `eth0` NO-CARRIER; soak **PASS** on **wlan0** (5 GHz, ~86/100 quality):
`SOAK_HOLD_S=12 SOAK_ROUNDS=5 SOAK_PROGRESS=1 SOAK_NET_LABEL=wifi` → 10 plays / 0 fails / daemon stayed up
(`PRESENT=both` `STREAM=1`). Ethernet comparison deferred until cable present.

## Known display limits

- **P3-WIDE** LAB proxy **FAIL** on `820484a6` (~60.5% content320/DE529 pillar; Fix-1 closed). True CRT/VGA geometry still untested.
- **res_csum** hard gate **FAIL** on lab `dabdaeb0` (H-rcsum-gate; soft-skip ≠ PASS; decode residual; orthogonal to CRT matrix).
- No automated frame-capture golden vs CRT.
- Match-source-Hz does **not** change PLL/modeline yet.
- High `DECODE` (e.g. 720p) may drop frames on dual-A9 before FPGA decode lands.
- STREAM recon is I-frame oriented; P-frames still rely on FFmpeg for fb0 continuity when `PRESENT=both`.
- Concurrent F1/F2/F3 SPI without process mutex historically killed misterplexd under long soak (fixed: mutex + no `system()` in MainPause).

## Sign-off table (fill per session)

| Date | Output | Net | PRESENT | STREAM | Content FPS | Media | Result | Notes |
|------|--------|-----|---------|--------|-------------|-------|--------|-------|
| 2026-07-24 | HDMI 60 | wifi wlan0 | both | 1 | n/a | test.mp4 + lib/3 | PASS | 3×2 + 5×2 soak after SPI fix; eth N/C |
| 2026-07-24 | HDMI 60 | wifi | both | 1 | n/a | soak local/testsrc | PASS | post-RBF `6db3a4d8` SOAK ok=6 fail=0 (agent-D) |
| 2026-07-24 | HDMI 60 | wifi | n/a (Plex OSD) | n/a | 12/24/30/60 | patterns + FBAR | PASS | menu matrix; **H-gate-fix1** `test_fbar_fast` EXIT=0 on **`820484a6`** (grid_off=7.0 force=82.9 bars=94.4) |
| 2026-07-24 | HDMI 60 | wifi | both | 1 | n/a | soak local/lib | PASS | **D-soak4** on **`820484a6`** SOAK ok=6 fail=0 (wifi; no load_core) |
| 2026-07-24 | HDMI 60 | n/a | n/a (DDR F1) | n/a | n/a | push_frame --ddr ×5 | PASS | **B-ddr5** mean≈18.0 ms has_frame=1 on `820484a6` |
| 2026-07-24 | HDMI 60 | n/a | n/a | n/a | n/a | cadence unit | PASS | CRT2/CRT3: `test_cadence` / unit OK |
| 2026-07-24 | HDMI 60 | n/a | n/a (Plex OSD) | n/a | n/a | WIDE eyes-on force bars | **FAIL** | **W-wide4/5/6** ~60.5% pillar on `820484a6` (Fix-1 dead); not CRT PASS |
| 2026-07-24 | HDMI 60 | n/a | n/a | n/a | n/a | residual hard res_csum | **FAIL** | lab `dabdaeb0` raw[13] unstable ≠0x14 (res_dc=-24 OK; H-rcsum-gate); prior also FAIL on `820484a6` |
| | HDMI 60 | eth | fb0 | 0 | n/a | local test.mp4 | | eth N/C — deferred |
| | HDMI 60 | wifi | both | 1 | 24 | library ep | | live 3:2 eyes-on optional |
| | CRT 15 kHz | | fb0 | 0 | n/a | library ep | **PENDING** | **no physical CRT in lab — do not mark PASS** |
| | CRT 15 kHz | | fpga | 1 | 24 | annex-B / weak | **PENDING** | **no physical CRT in lab — do not mark PASS** |
