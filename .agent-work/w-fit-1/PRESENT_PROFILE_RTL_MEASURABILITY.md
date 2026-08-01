# PRESENT_PROFILE vs held RTL — measurability (no fit)

**Quartus hold:** REINSTATED. No slot requested or started.  
**Branch:** `w-fit-ceiling-fd-min` @ tip.  
**Instrument:** parent `PRESENT_PROFILE=1`, 480p24, 300 frames, presented=300 drops=0.  
**Accounting:** wall sum 39.88 ms vs 41.67 ms period (96% closed) — trusted decomposition.

## Parent table (binding reality)

| Field | wall/frame | CPU/wall | Role |
|-------|----------:|---------:|------|
| read block (wait ffmpeg) | 10.355 ms | 0.130 | blocked on producer |
| **pacing wait (sleep)** | **16.684 ms** | **0.009** | **deliberate A/V pacer — 40% of period** |
| pixel | 3.505 ms | 0.415 | ARM pixel work |
| DDR accounted | 9.340 ms | — | prep_wait 4.05 + copy 5.28 (+ minor) |
| — doorbell steady-state | **0.002 ms** | — | **do not optimise** (first-frame 17–92 ms was SPI kick) |

**Pipeline is PACER-LIMITED at this tier.** Instant fabric decode would lengthen sleep, not raise fps.

## Held RTL inventory vs this table

| Held item | In shipping `8fdf440f` already? | Touches product pixel/DDR path? | Moves a PRESENT_PROFILE field? |
|-----------|--------------------------------|----------------------------------|--------------------------------|
| T7b 480 unique store rows | **YES** (shipped, glass-HIT) | scanout geometry | **No further** — already deployed |
| `907e5950` NBA swap_pending hold | **YES** (tip md5-match) | bank swap corner | **No** at steady 24p closed ledger |
| comb shift-add dequant (−32 DSP) | **YES** (DSP 44 on 8fdf) | only under `decode_stub` | **No** — stub `fs_wr` unconnected; not product decode |
| `frames_done_d2` / pending_ready hold | **YES** on tip | present mailbox | **No** measurable fps/pacing win while pacer-limited |
| **PRODUCT_NO_STUB** (scaffold, default OFF) | **NOT fitted** | removes dark stub subtree | **No row in this table** — but **M10K enabler** for w-osd-hires overlay (88→~356 free); pair in one fit |
| Future fabric scaler (w-geom, not held complete) | not held | would cut ARM scale | **Would** hit `pixel_*` and/or ffmpeg side of `read block` — **not ready** |

### Plain answer

**No RTL change I currently hold would change a number in that PRESENT_PROFILE table** in a product-visible way at 480p24.

- Scanout/throughput RTL already on silicon cannot beat a **16.7 ms deliberate sleep**.  
- Fabric decode / dequant / stub reclaim does not sit on the measured path (`fs_wr` unconnected; product = ARM YUV → DDR).  
- Doorbell steady-state is **2 µs** — out of scope for optimisation.  
- PRODUCT_NO_STUB’s win is **area reclaim** (exclusive subtree −9217 ALM / −268 M10K) for *future* cargo (scaler/direct-play front-end), **not** this instrument.

I will **not** request a fit to “prove” unmeasurable work.

## If a future change WOULD move the table — pre-register contract

Only request a fit when cargo has a registered field prediction. Examples (not held now):

| Future cargo | Predicted field(s) | Direction / magnitude (**estimate**) | Parent check |
|--------------|-------------------|--------------------------------------|--------------|
| Fabric scaler replaces ffmpeg scale→624×480 | `pixel_us_p`, possibly `read block` (less ffmpeg work) | pixel wall **down** by ~scale share of 3.5 ms; read block CPU/wall may fall — **unknown until design** | same PRESENT_PROFILE 300f |
| Direct-play high-bitrate (no PMS ladder) | outside this 24p table; new tier | not fps at 24p; bitrate/capability | separate instrument |
| PRODUCT_NO_STUB alone | **none** of the wall fields | **0.000 ms** on all rows | expect **flat** table (control) |

**PRODUCT_NO_STUB control prediction (if ever fitted alone):** every PRESENT_PROFILE field stays within noise of parent baseline (pacing ~16.7 ms, doorbell ~0.002 ms, drops=0). A move would be a **bug**, not a win.

## What PRODUCT_NO_STUB is still for (not this table)

- **Primary:** M10K enabler for **w-osd-hires** post-ascal overlay (user bug #2) — free blocks **88 → ~356**.
- Also: reclaim for fabric scaler/geometry M10K headroom.  
- Honest decode case remains **direct-play**, not 24p throughput (ERROR 15 / parent pacer result).  
- Rides **one** future exclusive fit **with** measurable scaler cargo — never alone on a void endpoint.

## Gates still in force (unchanged)

- Freeze sim must **FAIL** red-before-green on proposed RTL; compile-fail = **RED** (`PINNOTFOUND`/`%Error` → rc=2).  
- Do-not-ship: working **`c5382bee`** / **`8fdf440f`** not banned; barred freezes `{9eb1431a, ff2e3ca3, f0d3a385, 2890baac}` + `{8832824e, 75da8bb1, 4d6ee356, 4deaf6cc, dabdaeb0}`.  
- `true rc=$?` direct; no device from this lane.

## Endpoint lesson (recorded)

1 s dual-%CPU busy cannot discriminate serial vs pipelined at 24 fps — void. PRESENT_PROFILE wall decomposition can. Do not release Quartus on void endpoints.
