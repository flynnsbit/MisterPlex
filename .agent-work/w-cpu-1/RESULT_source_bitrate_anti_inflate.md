# RESULT — 2000 floor RCA + source-relative anti-inflate

**Lane:** w-cpu  
**Branch:** `w-cpu-suspend-silicon-pin`  
**Binary md5:** `099635f781aa7bdf81492bb5c47a4ef2`  
**Status:** READY FOR PARENT MULTI-RUN MEASURE (not single-shot A/B)  
**Live device today:** still `ea643e99` until parent deploys this tip.

---

## 1. RCA of `2000` (quoted origin — unjustified as a floor)

| Layer | Live `ea643e99` / pin `aa80df0f` | This branch tip |
|---|---|---|
| Hard validate | `if (maxVideoBitrateKbps < 2000) fail("480p profile bitrate is too low")` | **Retired** (`02db04d5`): positive-only |
| Default **request** | `kPlex480pWeakBitrateKbps = 2000` | Still 2000 as tier *default*, then **source-clamped** |
| On wire | `maxVideoBitrate=2000` always for 480p | `min(tier, source_video_kbps)` when metadata known |

**Git origin (quoted):**
- `216703b94` *feat(plex): add 480p transcode profile* — “guarded **640x480/2500k** … validate … **floor of 2000**”. Quality guard at landing, not a measured decode contract.
- Later comment (osd_menu / W-FEED): “ARM margin until higher proven” / W-FEED ~1412 kb/s was an **upper-safety** story about *raising* bitrate — **misused as a minimum floor**.
- No commit ties 2000 to a measured ARM decode knee or H.264 level table.

**Finding:** the hard floor and the default request that still hits the wire as 2000 are **unjustified as decoder contracts**. Parent encoder evidence closes the defect: `maxVideoBitrate=2000` → PMS `-maxrate:0 1527k` on a **397k** video stream with **identity** `scale=624:480`.

---

## 2. Does removing/lowering enable `videoDecision=directplay`?

### **No — bitrate alone cannot.** Independent blockers (quoted source):

1. **Hardcoded force-transcode on the universal URL**  
   `plex_resolve.cpp` `buildUniversalTranscodeUrl`:
   ```
   &directPlay=0&directStream=0
   ```
   Same on `ensureUniversalDecision`.

2. **Cast path always takes universal**  
   `main.cpp`: `weakAlways=true` always; `preferDirectH264=streamEnabled` and **STREAM defaults false** → product cast never prefers Part.

3. **Server profile forbids broad direct play**  
   `assets/plex-profiles/MiSTerPlex.xml`:
   ```xml
   <!-- Intentionally no broad DirectPlayProfiles: MiSTerPlex should use the
        constrained transcode target unless/until the hardware decoder supports
        the source codec/profile directly. -->
   ```
   Plus `CodecProfiles` require **baseline**, **level ≤ 30**, **refFrames ≤ 1**.

4. **Acceptance ladder (validateWeakLadder)** still requires baseline + level≤3.0 for the *ladder we advertise*, independent of bitrate.

**rk36 h264+aac 624×480:** codec/container *may* be software-decodable, but with (1)+(2)+(3) PMS will still report `videoDecision=transcode` after a pure bitrate change.

**What bitrate fix *does* change:** the **cost of that forced re-encode** (`-maxrate`, delivered bits, ARM decode load) — parent’s named defect.

**Optional follow-up (not in this binary):** STREAM=0 “soft direct Part” when source is h264 and dims ≤ coded bank (ffmpeg software path tolerates High/CABAC). That is a separate product decision from anti-inflate.

---

## 3. Change shipped (principled — no new magic number)

```text
requested_maxVideoBitrate =
  WEAK_BITRATE                    if operator-explicit
  else min(tier_default,
           LINK_CAP_KBIT?,        if set
           source_video_kbps?)    if metadata known
```

- **source_video_kbps** = video `Stream@bitrate` (kbps), else `Media@bitrate`.
- **Anti-inflate only:** never *raises* above tier; if source is 5000k and tier 2000 → still 2000.
- **Operator override:** explicit `WEAK_BITRATE` is not source-clamped.
- Tier default 2000 remains the quality *ceiling preference* when source is unknown or larger.

**Code:** `sourceRelativeMaxVideoBitrateKbps`, `parseSourceVideoBitrateKbps`, resolve URL uses clamped `weakUse`, log line:
```
misterplexd: bitrate_final requested_max=… source_video_kbps=… clamped_to_source=…
```

**Host gates:** `test_resolve: OK true rc=0` (includes rk36-shaped meta 397k → 397).  
**ARM:** `make arm-plexd true rc=0` md5 `099635f7…`

---

## 4. PRE-REGISTRATION (parent measures all four; multi-run)

Do **not** single-run A/B (event rate ~25%). N≥8 casts same asset, or within-run + session class histogram.

| Observable | Baseline live `ea643e99` (rk36-class) | PRE_REG after tip |
|---|---|---|
| PMS argv `-maxrate:0` | ~1527k (parent-measured at request 2000) | **≈ 0.7× source_video_kbps** band, e.g. source 397 → maxrate **≲ 500k** (not ~1500k). Exact ratio is PMS’s; direction is large down. |
| `videoDecision` | `transcode` | **Still `transcode`** (directPlay=0 + MiSTerPlex.xml). **MISS if directplay appears without other changes.** |
| Delivered goodput / session bits | inflated vs library 397k | **Closer to source** (mean kb/s down vs baseline on healthy runs) |
| ARM decode load (ffmpeg %onecpu, same method) | parent ~70 on 480p | **Lower on average** across N runs; not every run (intermittent). Expect **−10…−30 %onecpu** band on ffmpeg when maxrate collapses — publish miss if flat. |
| Daemon log | `bitrate=2000` | `bitrate_final … clamped_to_source=1 source_video_kbps=397 requested_max=397` (numbers from meta) |
| Drop intermittency | ~25% degraded | **Lower event rate** hypothesized, not guaranteed; score with multi-run power, not one cast. |

**High-bitrate source (e.g. 2617k library):** `requested_max` stays **min(2000, source)=2000** — no regression of the “floor was protecting quality on fat sources” case; tier still caps.

**Explicit WEAK_BITRATE=2000 on 397k source:** operator wins → still 2000 (document intentional escape hatch).

---

## 5. Parent deploy / capture commands (device is yours)

1. Stage binary md5 `099635f781aa7bdf81492bb5c47a4ef2`; keep `ea643e99` restore.  
2. Conf: leave `WEAK_BITRATE` unset; `SUSPEND_MAIN_DURING_PLAY` as you prefer; optional `PRESENT_PROFILE=1` for concurrent window RCA.  
3. N≥8 casts rk36-class; each cast capture:
   - daemon `bitrate_final` line  
   - PMS session `videoDecision` + transcoder argv `-maxrate`  
   - end `media: frames=` (supply, drops, vfps/pfps)  
   - optional ffmpeg %onecpu window method  
4. Restore conf/daemon to daily-driver state.

---

## 6. Explicit non-claims

- Does **not** enable directplay by itself.  
- Does **not** replace present_window RCA for residual device stalls after maxrate is honest.  
- Does **not** auto-oscillate on Wi‑Fi RTT (static per-title from metadata, not RTT loop).
