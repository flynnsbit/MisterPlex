# Baseline profile pin — measured (host PMS, 2026-08-03)

## Pre-registered question
Does PMS honour `videoProfile=baseline` + Extra match/isRequired, or is it advisory like videoResolution?

## Library source distribution (live `/library/sections/*/all`)
- N=142
- Source tagged constrained baseline: **140/142 (98.6%)**
- Source High: 1 (rk118)
- Source Main: 1 (rk119)

## force-xcode (product path: directPlay=0,directStream=0, videoProfile=baseline, daemon-class Extra)
- Samples with bitstream: **14**
- Fabric-safe (baseline + has_b_frames=0): **0/14 (0.0%)**
- **Every** successful sample: ffprobe `profile=High` or `Main`, `has_b_frames=2`
- SPS on rk62 force-xcode sample: **profile_idc=100 (100=High)**, level_idc=31
- Decision XML **misreports**: Media@videoProfile="constrained baseline" while bitstream is High
- Stream@decision="transcode" but Stream@location="direct" (remux/transcode path still emits High)

### force-xcode rows
- 624x480 rk=62 → High has_b=2 bytes=31432472 safe=0
- 624x480 rk=131 → High has_b=2 bytes=15366556 safe=0
- 624x480 rk=46 → High has_b=2 bytes=68409064 safe=0
- 720x480 rk=79 → High has_b=2 bytes=2318980 safe=0
- 720x480 rk=138 → High has_b=2 bytes=57213852 safe=0
- 720x480 rk=32 → High has_b=2 bytes=18764468 safe=0
- 624x352 rk=9 → High has_b=2 bytes=41280664 safe=0
- 624x352 rk=15 → High has_b=2 bytes=4606000 safe=0
- 624x352 rk=74 → High has_b=2 bytes=2565072 safe=0
- 320x240 rk=54 → High has_b=2 bytes=14801992 safe=0
- 320x240 rk=5 → High has_b=2 bytes=718912 safe=0
- 320x240 rk=58 → High has_b=2 bytes=14689944 safe=0
- 1280x720 rk=7 → Main has_b=2 bytes=735644 safe=0
- high_src_624x480 rk=118 → High has_b=2 bytes=29003512 safe=0

## part-direct (original Part file — what Direct Play would feed)
- Samples: **14**; fabric-safe **13/14 (92.9%)**
- 624x480 rk=62 src=624x480 meta=constrained baseline → Constrained Baseline B=0 wh=624x480 safe=1
- 624x480 rk=131 src=624x480 meta=constrained baseline → Constrained Baseline B=0 wh=624x480 safe=1
- 624x480 rk=46 src=624x480 meta=constrained baseline → Constrained Baseline B=0 wh=624x480 safe=1
- 720x480 rk=79 src=720x480 meta=constrained baseline → Constrained Baseline B=0 wh=720x480 safe=1
- 720x480 rk=138 src=720x480 meta=constrained baseline → Constrained Baseline B=0 wh=720x480 safe=1
- 720x480 rk=32 src=720x480 meta=constrained baseline → Constrained Baseline B=0 wh=720x480 safe=1
- 624x352 rk=9 src=624x352 meta=constrained baseline → Constrained Baseline B=0 wh=624x352 safe=1
- 624x352 rk=15 src=624x352 meta=constrained baseline → Constrained Baseline B=0 wh=624x352 safe=1
- 624x352 rk=74 src=624x352 meta=constrained baseline → Constrained Baseline B=0 wh=624x352 safe=1
- 320x240 rk=54 src=320x240 meta=constrained baseline → Constrained Baseline B=0 wh=320x240 safe=1
- 320x240 rk=5 src=320x240 meta=constrained baseline → Constrained Baseline B=0 wh=320x240 safe=1
- 320x240 rk=58 src=320x240 meta=constrained baseline → Constrained Baseline B=0 wh=320x240 safe=1
- 1280x720 rk=7 src=1280x720 meta=constrained baseline → Constrained Baseline B=0 wh=1280x720 safe=1
- high_src_624x480 rk=118 src=624x480 meta=high → High B=0 wh=624x480 safe=0

## Hit rates that change architecture
| Path | Fabric-safe rate | Notes |
|------|----------------:|-------|
| Library **source** metadata baseline | **98.6%** (140/142) | Already CAVLC-class tags |
| **Part direct** measured | **92.9%** (13/14) | Original file via `/library/parts/...` |
| **Universal force-xcode + baseline pin** | **0.0%** (0/14) | Pin **not** honoured |

## Verdict (evidence-backed)

1. **`videoProfile=baseline` is NOT a hard pin on this PMS.** Universal transcode
   with daemon Extra + query pin delivered **High/Main + B-frames** in **0%** of
   force-xcode samples. Same defect class as videoResolution ceiling: request is
   advisory; decision XML can claim constrained baseline while SPS is High.
2. **Forcing a transcode is actively harmful** for the 98.6% already-baseline library:
   source Constrained Baseline (no B) → xcode High (B=2). The pin does not stop it.
3. **Fabric-safe hit rate is the Direct Play / Part path on already-baseline assets**,
   not the universal pin. Measured Part-direct safe ≈ 93% of sampled classes
   (High/Main sources remain unsafe until a *real* baseline transcoder exists).
4. **No reliable “force baseline xcode” found** in this pass. Low-bitrate / scale /
   level-strict variants returned empty 89-byte bodies under load; when xcode did
   run, profile was High. Do not plan fabric decode on the pin alone.

## What forces a real transcode?
- `directPlay=0&directStream=0` **does** enter conversion (decision 1001 /
  "Conversion OK") and can change geometry (624x352→624x350; 1280x720→960x540).
- It does **not** force baseline/CAVLC/no-B. Profile pin is ignored.
- Direct Play of original requires Part URL (universal prefer-direct returned
  89-byte empty bodies here — use `/library/parts/.../file` or daemon Part path).

## Implications for fabric H.264
- **Do not** treat `kPlexH264ProfilePin` as evidence the wire is Baseline.
- Gate must be **bitstream** (`h264_fabric_stream_gate` on SPS/PPS), not decision XML.
- Prefer **Direct Play** of baseline sources; refuse High/Main or fall back to ARM.
- Building fabric for Baseline-only is still right for the **library majority via DP**,
  but the **request pin does not create** that majority — the files already are.

Artifacts: `runs/results.tsv`, `part_direct/`, `picks.json`, SPS profile_idc=100 on rk62 xcode.
