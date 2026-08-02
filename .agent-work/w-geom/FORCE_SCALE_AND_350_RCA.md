# FORCE_SCALE + measured 624×350 RCA (w-geom)

**Branch:** `w-geom-lane` · tip after this note’s commit (see git log).  
**Scope:** source + host gates only. No device.

## Parent silicon (quoted)

RK6 cast, `DDR_YUV_FORCE_SCALE=1`, daemon `ea643e99`, RBF `8fdf440f`:

```
GEOM … delivery_verified=0 … yuv_ddr_force_scale=1 … library_media=624x480
media: … decode=624x480 measured=624x350 desync_risk=0
VERDICT=PASS supply_ratio=0.9994
```

Three sources: request 624×480, library 624×480, **measured 624×350**. Only measured is a stream fact.

## 1) Where does 350 come from?

| Source | Value | Class |
|--------|-------|--------|
| PMS request `videoResolution` / DECODE | 624×480 | claim (our ladder) |
| `library_media` | 624×480 | claim (scanner metadata) |
| ffmpeg Input banner `measured=` | 624×350 | **measurement** |

**Derivation (labelled, not PMS-XML proven):**  
`624 × 9/16 = 351` → even-floor **350** is the classic PMS square-pixel 16:9 height for a 624-wide ladder rung. Parent asset metadata may still say 480; the transcoder can emit a different coded height.

**Not established without parent check:** SAR/DAR on the Part, decisioning XML `videoDecision` height.  
**Parent check (device owner):**

```bash
# After cast, while session live — dump Media/Part attributes + decision height
curl -sS "http://$PMS:32400/library/metadata/6?X-Plex-Token=$TOKEN" | \
  rg -n 'width=|height=|aspectRatio=|pixelAspectRatio|videoResolution'
# Transcode session (if transcoded=1)
curl -sS "http://$PMS:32400/transcode/sessions?X-Plex-Token=$TOKEN" | \
  rg -n 'width=|height=|videoDecision|transcodeHw'
```

**Pre-register:** if Part height=480 and session height=350 → PMS ladder/DAR path. If Part height=350 → library claim was wrong, not transcoder.

## 2) B1 arithmetic: 350 does **not** predict N=2 TREK24

| Producer | S = W×H×1.5 | vs R=449280 | N≈R/S |
|----------|-------------|-------------|--------|
| 624×350 | **327600** | S < R (correct sign for identity phase-walk) | **1.371** (non-integer) |
| 624×240 | **224640** | S < R | **2.000** exactly |
| 640×480 | **460800** | S > R (wrong sign for packing two counters) | 0.975 |

**Plain statement:**  
- Delivered **624×350** has the right **sign** (S<R) for the identity desync *class*, but **R/S is not an integer**, so it does **not** predict two full legible `TREK24 n=312` copies in one reader raster.  
- Archived **N=2** still discriminates **S≈224640 = 624×240**, not 350.  
- Unit gate: `test_yuv420p_chroma_480p` pins `producerBytesFromCounterCopies(449280,2)==224640` and `!=327600`.

If identity_skip were 1 with 350-byte frames, phase walk would still corrupt, but the **visible counter geometry would not match N=2**. With product FORCE_SCALE, identity_skip=0 and OUTPUT stays 449280 → `desync_risk=0` while DELIVERY_MISMATCH is loud.

## 3) Should `DDR_YUV_FORCE_SCALE` default to 1?

**YES — and tip already does.**

```cpp
// main.cpp — product default
bool ddrYuvForceScale = true; // product always ON unless LAB escape
```

Conf `DDR_YUV_FORCE_SCALE=0` is **ignored** unless `DDR_YUV_FORCE_SCALE_LAB=1`.  
Parent’s “currently opt-in” brief is **stale for tip**. No further default flip required; wiring gate in `test_b2_b5_source_wiring.sh` asserts the default.

**Why load-bearing (evidence):** measured≠bank on a stock asset with library claim 624×480. Without Always/scale_pad, identity would feed S≠R into the DDR reader.

## 4) `delivery_verified` meaning (this commit)

| When | `delivery_verified` | Notes |
|------|---------------------|--------|
| Play-time GEOM | **0** | basis = `transcode_request` / `library_media` (claims) — correct |
| After ffmpeg Input banner | **1** | B4: basis=`measured` only |
| measured ≠ coded bank | still **1** + **`ERROR DELIVERY_MISMATCH`** | verified = “we measured”; match = `decode_target_match` |

Pump now compares measured to **DDR coded bank** (`rawW×rawH`), not DECODE tier alone, and logs `coded_bank=` / `decode_tier=` / `force_scale_protects=`.

## 5) B5

Already in **arm** teardown (`rawPipeByteAligned` / `rawPipeDesynced` / `PIPE_DESYNC=1`). Parent “unit-only” brief remains stale. No re-implement.

## Parent device commands (agent does not run)

```bash
# After deploy tip daemon — one RK6 cast, line-mark log first
rg -n 'MEASURED_DELIVERY|DELIVERY_MISMATCH|GEOM |desync_risk|force_scale' \
  /media/fat/misterplex/misterplexd.log | tail -40
```

**Pass shape:**  
`MEASURED_DELIVERY … measured …624x350… delivery_verified=1 decode_target_match=0`  
`ERROR … DELIVERY_MISMATCH … coded_bank=624x480 … force_scale_protects=1`  
`desync_risk=0` with product FORCE_SCALE.

## Host gates (agent)

```text
make "$PWD/build/test_yuv420p_chroma_480p" && ./build/test_yuv420p_chroma_480p ; echo true_rc=$?
bash tests/unit/test_b2_b5_source_wiring.sh ; echo true_rc=$?
# host misterplexd build
```
