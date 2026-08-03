# w-path status

**Branch tip:** see `git log -1 --oneline` on `w-path-720p`.

## Product path (fit-critical)
- PMS **does** deliver genuine **960×540** (display=ffprobe coded, SAR 1:1, CB L31)
  on HD 16:9 when maxBR≥2000 — evidence `PMS_540_DELIVERED_GEOMETRY.md`.
- SPS MB **544** + crop 4 → ARM publishes **540 / 777600 B** (not 783360).
- Deploy pair: `PARENT_DEPLOY_PAIR_540P.md` — `DECODE=960x540` + `OSD_CONTROL=off`.
- **Blocker for PLAYING:** `ddrFrameGeometryForFpgaPresent` still 480p canvas;
  w-mem Option-C predicate must accept 960-wide banks.

## Upgrade path (not fit-critical)
- WC-first true-720 serial; kernel dmaengine second; raw PL330 stopped.
