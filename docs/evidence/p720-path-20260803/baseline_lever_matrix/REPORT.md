# Baseline lever matrix — lab PMS (build host)

**Date:** 2026-08-03  
**PMS:** `127.0.0.1:32400` docker (build host — not MiSTer)  
**Subjects (falsifying):** `ratingKey=118` source High/CABAC; `ratingKey=119` source Main/B=2  
**Method:** force-xcode `directPlay=0&directStream=0`, sample `start.mp4`, `ffprobe` + annex-B PPS `entropy_coding_mode_flag`  
**Token:** mode-0600 file / `curl -K` only (never in git)

## Pre-registered predictions

All levers → **PIN_IGNORED** (High/Main still) on rk118/119.  
Parent prior: bare `videoProfile=` ignored (**hit**); Extra would force baseline (**miss**).

## Stable replication (authoritative) — 18/18 High

`replication.tsv`: 3 reps × {118,119} × {none, pin_both, q_only}

| rk | case | profile | has_b | entropy (PPS) | N |
|---|---|---|---|---|---|
| 118 | none / q_only / pin_both | **High** | 2 | cavlc | 9/9 |
| 119 | none / q_only / pin_both | **High** | 2 | cabac (7) / cavlc (2) | 9/9 |

**Baseline force hit rate: 0/18.**

## First-pass anomalies (not levers)

- `L6_no_pin_control` once reported Constrained Baseline on both rks — **not reproducible** in 18-run matrix. Flaky / session — published miss.
- HLS harness 400/404 — **UNSCORED**.

## Verdict

1. **No reliable request lever forces baseline** for High/Main sources on this PMS.  
2. Pin + Extra are **request-only**; bitstream is truth.  
3. Fabric-safe = DP of already-baseline sources + gate as **route selector**.  
4. Force-xcode High/Main → expect High+B. Refuse* must not kill playback.

## Gate disposition (landed)

| Gate | Route |
|---|---|
| Ok | `fabric_bitstream_eligible` |
| Refuse* | `arm_ffmpeg_fallback` (host FFmpeg continues) |

**Not chosen:** assume High+CABAC in fabric (CABAC bit-serial).  
**720p@30:** fabric owns present/DDR, not decode.

## q5 status

Values in daemon only (`lastPlxgQ5`). **DDR/`plxg_*` unwired both ends** until w-mem + `Plex.sv`.

## Artifacts

`replication.tsv`, `summary.tsv`, `runs/*`, `scripts/prove_baseline_levers.sh`
