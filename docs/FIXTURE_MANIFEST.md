# Local PMS fixture manifest (section 2)

**PMS:** `http://192.168.1.24:32400` · section **2** (“MiSTerPlex Tests”)  
**Host media:** `~/plex/media/movies/` (docker `plex` mounts as `/data/movies`)  
**Ignore:** `192.168.1.122` (SHIELD), remote PMS  
**Measured:** host `ffprobe` + body-luma sampling · workdir `.agent-work/w-asset480/`  
**Token:** `$TOK` only — never commit  

All rates below are **file-measured** rationals (`r_frame_rate`), not PMS tags.

---

## How to read the flags

| flag | meaning |
|------|---------|
| **visual_verdict** | `OK` = body has real/varying detail (md5 of successive frames can differ for motion). `HAZARD` = body is mostly black (`frac_body_Y<10` ≈ 1.0 on mid-clip samples) — **byte-identical black frames are normal**; never score freeze from md5 alone. |
| **bank_fit** | `favourable` = coded **624×480** (exact DDR bank; easiest 480p path). `adversarial` = any other coded size (forces ARM scale/pad/crop / `DDR_YUV_FORCE_SCALE`). `n/a` = not a 480p-path probe. |
| **glass_id** | Burned-in frame counter / Grey bars (`G n=DDDDDD c=C`) per `docs/glass_frame_id_contract.md`. |
| **av_marks** | Periodic flash + beep (or AudioID FSK) for lipsync. |

**Trap 1 (on record):** low-mean / black-body fixtures → false “freeze” from identical md5s.  
**Trap 2 (on record):** passing on **624×480** does not generalise; use adversarial sizes for FORCE_SCALE.

---

## Master table (indexed ratingKeys)

| rk | title (short) | coded WxH | rate | dur_s | profile | B | audio | body_Y† | black_frac‡ | visual | bank_fit | glass_id | av_marks | FOR |
|----|---------------|-----------|------|------:|---------|---|-------|--------:|------------:|--------|----------|----------|----------|-----|
| 1 | Soak 240p 23976fps | 320×240 | **24000/1001** | 360 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | n/a (240p) | no* | blip | Long 240p soak; **only** NTSC-film rate in library |
| 2 | Test 1080p | 1920×1080 | 24/1 | 30 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | adversarial | counter* | blip | Short ladder top; geometry only |
| 3 | Test 240p | 320×240 | 24/1 | 30 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | n/a | counter* | blip | Short 240p @24 |
| 4 | Test 240p 30fps | 320×240 | **30/1** | 30 | CB | 0 | aac/48k | ~1 | 1.00 | **HAZARD** | n/a | counter* | blip | Short 240p @30 — **geometry confounded vs 480p rate tests** |
| 5 | Test 240p 60fps | 320×240 | **60/1** | 30 | CB | 0 | aac/48k | ~1 | 1.00 | **HAZARD** | n/a | counter* | blip | Short 240p @60 — same confound |
| 6 | Test 480p | 624×480 | 24/1 | 30 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **favourable** | counter* | blip | Short bank 480p; **EOF races soaks** |
| 7 | Test 720p | 1280×720 | 24/1 | 30 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | adversarial | counter* | blip | Short 720p ladder |
| 8 | Soak 480p 24fps | 624×480 | 24/1 | 360 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **favourable** | counter* | blip | Medium bank soak (synthetic black) |
| 9 | Real BBB 624×352 | 624×352 | 24/1 | 360 | CB | 0 | aac/48k | ~123 | 0.00 | OK | **adversarial** | no | no | Real content; awkward height |
| 10 | Real BBB 720×480 | 720×480 | 24/1 | 596.5 | CB | 0 | aac/48k | ~123 | 0.00 | OK | **adversarial** | no | no | Full-length BBB @720×480 |
| 11 | Soak 480p RAMP | 624×480 | 24/1 | 360 | CB | 0 | aac/48k | ~0†† | 1.00 | **HAZARD** | **favourable** | yes? | ? | Synthetic ramp soak |
| 12 | Glass Ledger 480p | 624×480 | 24/1 | 360 | CB | 0 | aac/48k | ~2 | 1.00 | **HAZARD** | **favourable** | **yes** | beep | Glass ID early variant |
| 13 | Glass OCRProof 480p | 624×480 | 24/1 | 600 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **favourable** | **yes** | beep@1s | Primary glass drop/ID @ bank |
| 14 | Glass OCRProof 240p | 320×240 | 24/1 | 600 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | n/a | **yes** | beep | Glass ID @240p |
| 15 | OCRProof 624×352 | 624×352 | 24/1 | 180 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **adversarial** | **yes** | beep | Glass ID + FORCE_SCALE height |
| 16 | OCRProof 640×480 | 640×480 | 24/1 | 180 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **adversarial** | **yes** | beep | `PresentedMistake` width class |
| 17 | OCRProof 720×480 | 720×480 | 24/1 | 180 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **adversarial** | **yes** | beep | DVD-width adversarial |
| 18 | Real BBB GlassID 624×352 | 624×352 | 24/1 | 360 | CB | 0 | aac/48k | ~122 | 0.00 | OK | **adversarial** | **yes** | no | Real + glass ID |
| 19 | Real BBB GlassID 720×480 | 720×480 | 24/1 | 596.5 | CB | 0 | aac/48k | ~121 | 0.00 | OK | **adversarial** | **yes** | no | Real + glass ID long |
| 20 | AVSync Glass 480p | 624×480 | 24/1 | 600 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **favourable** | **yes** | flash+beep **0 ms** @2s | Lipsync offset 0 |
| 21 | AVSync Glass +100ms | 624×480 | 24/1 | 600 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **favourable** | **yes** | flash+beep **+100 ms** | Instrument RED |
| 22 | AudioID Glass 1800s | 624×480 | 24/1 | 1800 | CB | 0 | aac/48k | ~117 | 0.00 | mixed§ | **favourable** | **yes** | FSK AudioID @2s | Long A/V + audio checksum soak |
| 23 | AudioID Glass 60s | 624×480 | 24/1 | 60 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **favourable** | **yes** | FSK @2s offset 0 | Quick AudioID |
| 24 | AudioID +100ms 60s | 624×480 | 24/1 | 60 | CB | 0 | aac/48k | ~0 | 1.00 | **HAZARD** | **favourable** | **yes** | FSK +100 ms | AudioID instrument RED |
| 25 | Disc Nyquist 240p | 320×240 | 24/1 | 30 | CB | 0 | aac/48k | ~125 | 0.00 | OK-pattern | n/a | no | no | **Do not cast for 240-vs-480** (void) |
| 26 | Disc Nyquist 480p | 624×480 | 24/1 | 30 | CB | 0 | aac/48k | ~125 | 0.00 | OK-pattern | **favourable** | no | no | **Do not cast for tier** (void) |
| 27 | Bank480 FullBleed VRes AV | 624×480 | 24/1 | 1200 | CB | 0 | aac/48k | ~234 | 0.00 | OK | **favourable** | overlay | flash+beep @2s | **V-res instrument** + A/V; SAR 1:1 DAR 13:10 full-bleed |
| 28 | Real BBB GlassAV 1440×1080 | 1440×1080 | 24/1 | 90 | CB | 0 | aac/48k | ~119 | 0.00 | OK | **adversarial** | **yes** | flash+beep | Real + ID + A/V hi-res |
| 29 | Real BBB GlassAV 624×352 | 624×352 | 24/1 | 90 | CB | 0 | aac/48k | ~125 | 0.00 | OK | **adversarial** | **yes** | flash+beep | Real FORCE_SCALE probe |
| 30 | Real BBB GlassAV 624×480 | 624×480 | 24/1 | 1200 | CB | 0 | aac/48k | ~228 | 0.00 | OK | **favourable** | **yes** | flash+beep | Real long soak **at bank** |
| 31 | Real BBB GlassAV 640×480 | 640×480 | 24/1 | 90 | CB | 0 | aac/48k | ~126 | 0.00 | OK | **adversarial** | **yes** | flash+beep | Real 640 width |
| 32 | Real BBB GlassAV 720×480 | 720×480 | 24/1 | 90 | CB | 0 | aac/48k | ~126 | 0.00 | OK | **adversarial** | **yes** | flash+beep | Real DVD width |

**Notes**

- † `body_Y` = mean luma of body rows below ID band (~88px), multi-sample.  
- ‡ `black_frac` = fraction of mid-clip samples with body mean Y < 10.  
- \* Early trekmatch/blip overlays — not the OCRProof `G n=… c=C` contract; still a burned-in counter.  
- †† RAMP body samples hit black between ramps in sparse sampling — treat as HAZARD for md5 freeze.  
- § rk22 body is mid-grey field (not pure black); still synthetic — prefer BBB for “real decode stress”.  
- **CB** = Constrained Baseline · **B** = `has_b_frames`.

---

## On disk, not yet indexed (parent: scan §2)

| media filename | coded | rate | dur | profile | purpose |
|----------------|-------|------|-----|---------|---------|
| `MiSTerPlex Glass OCRProof 624x480 30fps 120s (2026).mp4` | 624×480 | **30/1** | 120 | CB b=0 aac/48k | **NEW** bank-native 30 fps present path (closes rk4 confound) |
| `MiSTerPlex Glass OCRProof 624x480 60fps 120s (2026).mp4` | 624×480 | **60/1** | 120 | CB b=0 aac/48k | **NEW** bank-native 60 fps present path (closes rk5 confound) |
| `MiSTerPlex Rowcount Vernier 624x480 24fps 120s (2026).mp4` | 624×480 | 24/1 | 120 | CB b=0 aac/48k | 475-vs-480 pad/fiducial instrument |

```bash
curl -sS "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
# then: .../library/sections/2/all?X-Plex-Token=$TOK  → new ratingKeys
```

### NEW 30/60 — measured (true rc=0)

```
# 30 fps
width=624 height=480 r_frame_rate=30/1 avg=30/1 nb_frames=3600 duration=120
profile=Constrained Baseline has_b_frames=0  aac 48000

# 60 fps
width=624 height=480 r_frame_rate=60/1 avg=60/1 nb_frames=7200 duration=120
profile=Constrained Baseline has_b_frames=0  aac 48000
```

Generator (reproducible):

```bash
python3 scripts/gen_glass_ledger_fixture.py \
  --out assets/avsync/glass_ocrproof_624x480_30_120s.mp4 \
  --duration 120 --fps-num 30 --fps-den 1 --width 624 --height 480 --vbitrate 2500k

python3 scripts/gen_glass_ledger_fixture.py \
  --out assets/avsync/glass_ocrproof_624x480_60_120s.mp4 \
  --duration 120 --fps-num 60 --fps-den 1 --width 624 --height 480 --vbitrate 3500k
```

Glass ID: `G n=DDDDDD c=C` + Grey bars (same as rk13). Body is synthetic black+1 Hz flash → **visual HAZARD** (use for rate/ID, not freeze-md5).

---

## Pick-list (what to cast for what)

| goal | use | avoid |
|------|-----|--------|
| 480p long soak + real decode | **rk30** (or rk27 V-res) | rk6 (30s), black soaks rk8/11 |
| V-res / 240-row ceiling | **rk27** | rk25/26 (void for tier) |
| Lipsync 0 / +100 | **rk20/21** or **rk23/24** | — |
| Long A/V drift | **rk22** (trim ±30s) | untrimmed |
| Glass frame drops (OCR) | **rk13** (bank) or **15–17** (adversarial) | md5-only on black body |
| FORCE_SCALE / non-bank | **rk29/31/32/15–17/18/19/28** | rk6/13/30 alone as “480p works” |
| 24 vs 30 vs 60 @ **same** bank geom | **rk13 (24)** + **NEW 30/60** after scan | rk3 vs rk4 (geometry confound) |
| 475 vs 480 ARM pad | **Rowcount Vernier** (scan) | FFT pitch on rk27 |
| Freeze / motion on glass | **BBB** rk18–19, 28–32, 9–10 | any HAZARD row |

---

## Who produced what (this lane / w-asset480)

| rk / asset | producer |
|------------|----------|
| **8**, 11–17, 20–27, **28–32**, GlassID **18–19**, rowcount file, **NEW 30/60** | w-asset480 / glass+avsync fixture lane |
| 1–7 | earlier ladder / trekmatch generators |
| 9–10 | BBB rewrap (archive.org source) |

---


## Delivery-geometry matrix (FORCE_SCALE / observed PMS sizes)

Canonical: [`docs/DELIVERY_GEOMETRY_MATRIX.md`](DELIVERY_GEOMETRY_MATRIX.md) · probe JSON
`docs/delivery_geometry_matrix_probe.json`.

| coded | rates | bank_fit | why |
|-------|-------|----------|-----|
| **624×350** | 24/1, 30/1 | adversarial | **Observed live delivery** (RK6 cast → measured 624×350) |
| **426×240** | 24/1, 30/1 | adversarial | **Observed live delivery** |
| **624×480** | 24/1, 30/1 | favourable | Bank-exact control |
| **640×480** | 24/1, 30/1 | adversarial | Stride / PresentedMistake width |
| **720×480** | 24/1, 30/1 | adversarial | NTSC DV width |
| **624×352** | 24/1, 30/1 | adversarial | +2 rows vs 350; I420 chroma discriminator |

Media: `~/plex/media/movies/MiSTerPlex DeliveryGeom *` — **scan §2 for ratingKeys**.
Generator: `scripts/gen_delivery_geometry_matrix.py --duration 90 --copy-media`.
All 12 cells measured CB / b=0 / aac/48k / glass ID (spec_fail=0).

## Git media hazard (no history rewrite)

**Measured** tracked blobs under `assets/` (not LFS):

| path | size |
|------|-----:|
| `assets/avsync/sync_audio_id_glass_480p24_1800s.mp4` | **103.1 MB** |
| `assets/avsync/sync_glass_av_480p24_600s.mp4` | 28.1 MB |
| `assets/avsync/sync_glass_av_480p24_600s_audioPlus100ms.mp4` | 28.1 MB |
| `assets/avsync/sync_2397fps_blip.mp4` | 6.5 MB |
| other blip/nyquist mp4s | <4 MB each |
| **Sum mediaish under assets/** | **~179 MB** |

Working tree `assets/avsync/*.mp4` on disk is larger (~792 MB) including **untracked** BBB/fullbleed/rowcount/30–60 builds.

### Proposal (forward only — do **not** purge history)

1. **Generate-on-demand:** commit generators + `.meta.json` only; write MP4s to `~/plex/media/movies/` and optionally untracked `assets/avsync/`.  
2. **`.gitignore`:** `assets/avsync/*.mp4` except a small allowlist of short blips (&lt;2 MB) if still desired in-tree.  
3. **Git LFS** for any new MP4 that must be shared: `*.mp4 filter=lfs` under `assets/avsync/` — migrate **new** files only.  
4. Keep **103 MB AudioID 1800s** in history as-is until an authorised LFS migration.

---

## Evidence paths

| artifact | path |
|----------|------|
| PMS XML snapshot | `.agent-work/w-asset480/pms_all.xml` |
| ffprobe dump | `.agent-work/w-asset480/probe_all.json` |
| body / black fraction | `.agent-work/w-asset480/body_luma.json`, `black_frac.json` |
| 475 power | `docs/rowcount_475_vs_480_power.md` |
| V-res instrument ceiling | `docs/bank480_instrument_ceiling.md` |
| Playbook | `docs/PLAYBOOK_LOCAL_PMS_FIXTURES.md` |
