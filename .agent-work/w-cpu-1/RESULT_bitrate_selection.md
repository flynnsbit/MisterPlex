# RESULT — 480p bitrate selection (post SUSPEND smoke)

## 0. SUSPEND PRE_REG miss (published)

| | PRE_REG | Measured (parent) |
|---|---|---|
| baseline busy | ~187–190 /200 | **181.9** |
| delta | −40…−50 | **−76.1** (181.9→105.8) |
| Main | →T, reclaim partial | **0.0 %onecpu, state=T** |

**Why the model under-predicted:** I used the *historical* win (−45.7 from an older session) as the forecast instead of the *current* Main share. Correct model after SUSPEND=0 baseline:

```
predicted_busy_drop ≈ Main_%onecpu_at_baseline
```

Here Main was **76.2**; system busy dropped **76.1**. Accounting closes. Historical −45.7 was a different load shape (or older Main share), not a physics constant. Favourable miss; model fix = always baseline Main first, then predict reclaim ≈ that share (spinner fully STOP'd → 0).

---

## 1. Where `2000` comes from (quoted)

### Built-in ladder default
`host/libmisterplex/osd_menu.hpp`:
```cpp
constexpr int kPlex480pWeakBitrateKbps = 2000;
// contentResolutionFor480p() → weakBitrateKbps = kPlex480pWeakBitrateKbps
```
`plex_resolve.cpp` `plexTranscodeProfiles()` copies that into the `"480p"` row → PMS `maxVideoBitrate=`.

### Original ship (commit `216703b9`)
```text
{"480p", "640x480", 2500, 60, "baseline", 30}
// validate: if 480p-class && maxVideoBitrateKbps < 2000 → FAIL
```
So **2500 default + 2000 hard floor** as a *quality guard* when 480p landed — not an H.264 level/refFrames contract.

### Later comment (pre this change)
```text
// Use the 2000 kbps PMS/validator floor until W-FEED proves a higher
// bitrate safe; this path has only millisecond-scale decode margin.
```
W-FEED (`docs/evidence/p480/p720-bus-and-bitrate-margin.md`) measured full-stack margin at **~1412 kb/s** content — that is an *upper-safety* story about raising bitrate, **misused as a minimum floor**. Decoder contracts remain only: baseline, level≤3.0, geometry≤DDR max, bitrate>0.

### Parent path (this session)
```text
GREEDY GOODPUT = 144136 B/s = 1.153 Mbit/s   p95 = 1.292 Mbit/s
```
Default request **2000 kbit/s ≈ 1.6×** sustained path → starvation class when PMS approaches the request.

---

## 2. Principled selection (implemented)

**Not** a new hardcoded product default. Mechanism:

| Priority | Source | Behaviour |
|---|---|---|
| 1 | `WEAK_BITRATE` (explicit) | Absolute. Never auto-clamped. WARN if > `LINK_CAP_KBIT`. |
| 2 | `LINK_CAP_KBIT` > 0 | `request = min(tier_default, LINK_CAP_KBIT)` |
| 3 | tier default | 480p→2000, 240p→1000 (quality preference only) |

Hard validate **no longer** rejects low bitrate. Advisory WARN via `bitrate_below_recommended` when below old heuristic (2000/750).

**Fixture ladder consumer:** write the measured knee into conf:
```conf
LINK_CAP_KBIT=1150
```
Daemon logs every play:
```text
bitrate=… bitrate_source=min(tier,LINK_CAP_KBIT)|WEAK_BITRATE|tier_default
LINK_CAP_KBIT=… WEAK_BITRATE_explicit=… clamped=…
```

### Runtime vs config vs tier — honest answer

| Approach | Pros | Cons |
|---|---|---|
| **A. Config `LINK_CAP_KBIT` (shipped)** | Operator/fixture owns the number; no silent magic; A/B easy; safe default=unset keeps today’s 2000 request | Requires one conf write after measure; multi-network homes need re-set |
| **B. Runtime probe at play start** | Tracks path drift; zero conf | Extra latency; probe can be confounded by concurrent load; need hysteresis/cache; wrong probe → wrong quality forever that session |
| **C. Tier-derived only (lower 480p default in binary)** | Zero conf | **Exactly the anti-pattern parent forbade** — trades one arbitrary constant for another; punishes fast LAN |
| **D. Adaptive from `supply_ratio` mid-play** | Reacts to real starvation | Needs session restart or mid-play re-transcode (PMS pain); oscillation risk; still needs a floor/ceiling policy |

**Recommendation:** **A now** (LINK_CAP from fixture knee). Optional later: B as a *writer* into the same conf key (or a sticky file) after a trusted probe — not a second parallel policy. Do **not** ship C. D only after supply_ratio is on-device and a re-resolve path exists.

### Quality vs reliability tension (options for parent/user)

| Choice | Cost | Benefit |
|---|---|---|
| Leave default 2000, no LINK_CAP | Best PMS quality intent on fast LAN | Starves on ~1.15 Mbit path (current daily driver) |
| Set LINK_CAP≈1150 (or ladder knee) | Softer 480p picture when path is the limit | Real-time delivery; drops/supply recover |
| Stay 480p geom + lower WEAK_BITRATE | Same as cap but sticky absolute | Overrides tier forever until conf edit |
| Drop to 240p tier | Much lower quality/res | Proven healthy on this path @1000k |
| Fix the path (Wi‑Fi/ethernet) | Hardware/network work | Keep 2000 quality *and* reliability |

**No automatic pick in the binary.** Default remains 2000 with LINK_CAP unset so fast networks are unchanged; daily driver sets LINK_CAP after measure.

---

## 3. Artifact

| | |
|---|---|
| branch | `w-cpu-suspend-silicon-pin` |
| binary md5 | **`9710e7fc6138014f4d83f3a7cda67e3b`** |
| pin path | `artifacts/daemon-pins/misterplexd.9710e7fc` |
| still has | SUSPEND default OFF, `-nostats`, dual A/V gate |

### Host gates (`true rc=0`)
- `test_resolve` — advisory + LINK_CAP + WEAK_BITRATE matrix
- `test_play_file_av_dual` frames=48
- `test_play_file_delivery`
- `test_main_session_suspend`
- `test_supervisor_resume_main`

### Parent deploy smoke (after md5 match)

**Smoke C — SUSPEND=0, LINK_CAP unset (behavior parity):**
- PRE_REG: `bitrate=2000` `bitrate_source=tier_default` `clamped=0`
- frames>0, no totalBytes=0 EOF

**Smoke D — SUSPEND=0, `LINK_CAP_KBIT=1150` only change:**
- PRE_REG: log `bitrate=1150` `source=min(tier,LINK_CAP_KBIT)` `clamped=1`
- wire `maxVideoBitrate=1150` (grep URL or PMS session)
- rk=9: `audio_s/wall_s` → ~0.99 class (was collapse at 2000 on this path)
- PRE_REG MISS rule: if still starved, knee may be lower — re-measure fixture, do not invent

**Smoke E — `WEAK_BITRATE=900` + `LINK_CAP_KBIT=1150`:**
- PRE_REG: `bitrate=900` `source=WEAK_BITRATE` (operator wins)
