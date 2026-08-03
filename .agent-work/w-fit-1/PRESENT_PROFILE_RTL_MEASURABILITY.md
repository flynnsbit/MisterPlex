# PRESENT_PROFILE vs held RTL — measurability (no fit)

**Quartus hold:** ON. No slot requested or started.  
**Branch:** `w-fit-ceiling-fd-min` @ tip.  
**Instrument history:** parent `PRESENT_PROFILE=1`, 480p24, 300 frames (presented=300 drops=0).  
**Accounting note:** wall sum ~39.88 ms vs 41.67 ms period closed well — rows are real wall, but **do not treat `read_block` vs `pacing_wait` as independent supply evidence** (see struck argument below).

## STRIKE — "pacer-limited / 16.7 ms sleep" (void)

**Withdrawn as a justification for any RTL or fit decision.**

Parent + rd-review: `pacing_wait_us` is `2 ms × Hold iterations`, and Hold exits when the frame is due on the A/V clock. **`read()` runs before that loop**, so every ms blocked in `read` advances the clock and removes Hold iterations. Therefore **`read_block + pacing_wait` is conserved by construction**; the split is loop-phase noise, not supply headroom. S-A/S-B thresholds on that split are a **void endpoint pair** (same class as 1 s dual-%CPU busy for serial vs pipeline).

Do **not** argue "instant fabric decode would only lengthen sleep" from the 16.7 ms row.

## Binding measurement (replacement) — ARM 480p24 decode headroom

Parent staged a **624×480 H.264 Constrained Baseline 24 fps 60 s** asset and ran the **product ffmpeg** flat-out with product scale flags, no product daemon competing:

```
-vf scale=624:480:flags=fast_bilinear -pix_fmt yuv420p -f null -
frame= 1440  fps=230  speed=9.57x
```

Pipe: `F_GETPIPE_SZ` **req=actual=2097152** (`set_ok=1`), **~4.67 frames** — pipe-too-small eliminated.

**Conclusion at this tier:** ARM **decodes + scales** the exact product geometry at **9.57× real time**.  
⇒ **Moving H.264 decode into fabric cannot improve throughput at 480p24.** Not "probably not" — replacing a component with ~9.6× spare capacity has no user-visible fps win.  
Held RTL that only touches dark stub / dequant / doorbell remains **unmeasurable on throughput** for the same reason, now on a **measured** base rather than a void pacer story.

**Still not covered by this result:** 720p/1080p (frame-store contract currently rejects 1280×720; cost ≠ linear with pixels). Throughput case for fabric decode, if any, must be made **after** extending the store and measuring those tiers. Honest non-throughput cases: **direct-play** (kill PMS transcode / high-bitrate) and user offload direction.

## Held RTL inventory vs product-visible throughput

| Held item | In shipping `8fdf440f` already? | Touches product pixel/DDR path? | Moves 480p24 throughput? |
|-----------|--------------------------------|----------------------------------|---------------------------|
| T7b 480 unique store rows | **YES** (shipped, glass-HIT) | scanout geometry | **No further** — already deployed |
| `907e5950` NBA swap_pending hold | **YES** (tip md5-match) | bank swap corner | **No** — corner correctness, not fps |
| comb shift-add dequant (−32 DSP) | **YES** (DSP 44 on 8fdf) | only under `decode_stub` | **No** — stub `fs_wr` unconnected; not product decode |
| `frames_done_d2` / pending_ready hold | **YES** on tip | present mailbox | **No** — ARM already has 9.57× spare on decode+scale |
| **PRODUCT_NO_STUB** (scaffold, default OFF) | **NOT fitted** | removes dark stub subtree | **No throughput field** — **M10K enabler** for w-osd-hires (88→~356 free); pair in one fit |
| Future fabric scaler / OSD plane | not held complete | overlay / scale path | OSD win is **pixels**, not this table; scaler might cut ARM work — separate cargo |

### Plain answer

**No RTL change I currently hold would improve 480p24 throughput** in a product-visible way.

- Product path is ARM YUV → DDR doorbell; stub write port unconnected under `DDR_FRAME_STORE`.  
- ARM decode+scale at this tier has **9.57×** measured headroom.  
- Doorbell steady-state remains ~**2 µs** (first-frame SPI kick was one-shot) — do not optimise.  
- PRODUCT_NO_STUB’s win is **M10K for the post-ascal overlay plane** (user bug #2), not ms on any present profile row.

I will **not** request a fit to “prove” unmeasurable throughput work.

## If a future change WOULD move something — pre-register contract

| Future cargo | Predicted field / score | Direction | Parent check |
|--------------|-------------------------|-----------|--------------|
| Fabric scaler replaces ffmpeg scale→624×480 | ARM CPU / ffmpeg share; maybe present `pixel_*` | CPU down — **unknown magnitude until design** | profile + top |
| Direct-play high-bitrate / 720p+ store | **outside** 480p24 headroom result | capability, not 24p fps | new tier instrument |
| PRODUCT_NO_STUB alone | present wall fields | **0.000 ms** / flat | control: any move = **bug** |
| PRODUCT_NO_STUB + w-osd-hires | **viewed 1080p overlay pixels** | readable chrome @ output res | parent HDMI capture only |

**Combined-fit control:** present ledger stays **flat** (movement = bug). Win scored on **overlay pixels**, not ms.

## What PRODUCT_NO_STUB is for (not throughput)

- **Primary:** M10K enabler for **w-osd-hires** post-ascal overlay (user bug #2) — free blocks **88 → ~356**.  
- Also: headroom for fabric scale/geometry if that cargo is ready.  
- Honest decode case remains **direct-play / higher tiers**, not 480p24 throughput.  
- Rides **one** exclusive fit **with** the OSD plane — never alone.

## Gates still in force

- Freeze sim must **FAIL** red-before-green on proposed RTL; compile-fail = **RED** (`PINNOTFOUND`/`%Error` → rc=2).  
- Do-not-ship freezes `{9eb1431a, ff2e3ca3, f0d3a385, 2890baac}` + banned `{8832824e, 75da8bb1, 4d6ee356, 4deaf6cc, dabdaeb0}`. Working: **`8fdf440f`**, **`c5382bee`** (untouched).  
- `true rc=$?` direct; no device from this lane.

## Endpoint lesson (recorded)

1. 1 s dual-%CPU busy cannot discriminate serial vs pipelined at 24 fps — void.  
2. `read_block` vs `pacing_wait` split is conserved / phase-dependent — void for supply.  
3. Prefer **flat-out ffmpeg speed=** on the exact tier, or a closed ledger that does not depend on Hold-loop phase.  
4. Do not release Quartus on void endpoints.
