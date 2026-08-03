# Fabric DP + bitstream gate (w-path)

## Pre-registered predictions
| ID | Prediction | Result |
|----|------------|--------|
| P1 | rk=36 DP decision → directplay | **HIT** decision=directplay videoProfile=CB (XML) |
| P2 | rk=36 Part bytes → CB, B=0 | **HIT** Constrained Baseline has_b_frames=0 624x480 level=30 |
| P3 | rk=2 xcode 1280x720 bytes → Main B=2 | **MISS** this host PMS delivered **CB has_b_frames=0** 1280x720 (decision XML also CB). Parent miss#15 still holds as policy: **any xcode → ARM**; metadata still untrusted. |
| P4 | thin identity → 400 empty | **HIT** (true thin, no curlrc headers): HTTP 400 body starts `<html>…Bad Request`. False thin via `/tmp/pms.curlrc` is **not** thin — curlrc already carries full identity. |

## Code
- `confirmFabricFromDeliveryAndBitstream` / `confirmFabricFromSpsPpsNals` — positive `ok_baseline_cavlc_confirmed`
- STREAM: F3 skipped if `pms_transcoded=1`; else hold VCL until SPS+PPS gate; log `FABRIC_GATE`
- Resolve SD: decision URL `directPlay=1` + full identity; require `decision=directplay` before Part
- Tests: gate confirm + decision parse NEG/POS

## Invariant (unchanged)
Direct play + byte-confirmed Baseline/CAVLC/no-B → fabric eligible.
**Any transcode → ArmFfmpegFallback** (even if this PMS emits CB on xcode today).

## Coordinate
- w-mem: q5 already wired host→writePlxgQ5 +0x828; bit34 RESERVED
- w-scaler: fabric upscale of DP native SD → 720 glass (Route B)
- w-nostub: 1080p CB DP cost open
