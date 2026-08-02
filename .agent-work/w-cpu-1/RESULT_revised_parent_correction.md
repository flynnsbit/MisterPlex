# RESULT — parent correction (bitrate premise falsified)

## 0. Misses / corrections (lane standard)

| Claim I was working from | Status |
|---|---|
| 2000 kbit request over ~1150 path ⇒ systematic 480p drops | **FALSIFIED by parent CBR ladder** (rk30 2617k supply_iv≈0.999 most runs) |
| Bitrate-selection ship as product fix for user drops | **NOT JUSTIFIED** — stop |
| "1200k discriminating knee" / "1800k ~0.72" | Parent **MISS** (published); lane must not re-assert |

## 1. Bitrate-constant work — parked, unmerged

Branch only: `w-cpu-suspend-silicon-pin` (not on `main`).

| commit | content | merge? |
|---|---|---|
| `02db04d5` | advisory floor + LINK_CAP_KBIT | **unmerged** — keep; not a demonstrated-defect fix |
| `19d36a98` | stderr diagnostics + link_cap p10 helper | **unmerged**; stderr part still valid |
| `aa80df0f` | SUSPEND_MAIN (live as `ea643e99`) | deployed separately |

**Do not ship LINK_CAP / floor changes to “fix drops” on this evidence.** Helpers may remain as optional operator tooling when a *reproducible* path limit is later shown. Default product path: no bitrate policy change.

## 2. Primary: ce727a43 zero-frame RCA

### Proven (quoted code + device log)

Device (ce727a43) had tip-format lines:
```
MEASURED_DELIVERY delivered_geom=624x350 … delivery_verified=1
audio pump end bytes=253952
short read got=0/449280 totalBytes=0 eof=1
frames=0
```

Tip `ffmpegStderrPump` (029470fd) after geometry parse:
```cpp
const auto g = parseFfmpegGeometryLine(line);
if (!g.ok)
    continue;  // discards Error/Invalid/Nothing-was-written
```

So: banners OK ⇒ stderr pipe alive; video stdout EOF with 0 bytes; **any fatal after banners was swallowable**. Parent hypothesis on silence: **CONFIRMED as a real defect class**.

### Not proven (Rule 0)

Root *cause* of zero video bytes on that binary: **unknown** without the missing ffmpeg line. Host A/B cleared `-stats` alone. Tip also adds raw pipe F_SETPIPE_SZ, adelay form, present-loop — **candidates, not findings**.

### Fix retained (stderr only justification)

Silicon-pin pump now logs Diagnostic lines (`ffmpeg_stderr.hpp` + `test_ffmpeg_stderr`).  
That fix stands independent of bitrate story.

### Parent check that would finish RCA

Redeploy any tip-class binary **only in lab** with stderr fix, or capture ffmpeg.err to file, one cast:
- PRE_REG: if video dies, log contains `ERROR media: ffmpeg …` or file has Error line
- That line is the cause; until then do not assert adelay/pipe/stats

## 3. Design: no link margin (not a bitrate constant)

Parent data (hypothesis, not finding): high-complexity 480p can run **healthy tight** (goodput ≈ capacity, supply_iv≈1) with intermittent drop bursts on perturbation — matches user “seems like frames dropped”.

**Daemon policy (design):**

| Class | Meaning | Daemon does |
|---|---|---|
| NO-DATA | missing supply_iv | log nothing as 0.0 |
| HEALTHY_HEADROOM | realtime, not tight | none |
| HEALTHY_TIGHT | realtime, goodput≥0.9×capacity | observe_only log |
| INTERMITTENT_STRESS | realtime + tight + drop_delta>0 | info log; **no auto bitrate**; optional SUSPEND_MAIN (CPU), path fix |
| SUSTAINED_STARVE | supply_iv < 0.90 | warn; **no auto bitrate**; operator tier/path |

Anti-oscillation: `noMarginStreakReady` need≥3 identical windows before any *sticky* operator hint; never chase single WiFi blips (RTT 2.9–227 ms).

Implemented as pure host library `no_margin.hpp` + `test_no_margin` — **not wired to rewrite PMS requests**.

Discriminator parent still needs for link vs transcoder: PMS `complete`/`speed`/`throttled` with a correct grep (not POSIX-invalid `\d`). Lane does not invent that result.

## 4. Standing corrections absorbed

- 480p is not ARM-CPU-blocked at 2–4× vs 240p (+6.2 %onecpu measured)
- Prefer direct-play evidence; PMS on workstation contaminates transcoder load
- Scaler dominates ffmpeg bill more than decode — do not use CPU relief to justify fabric decode for this drop story
