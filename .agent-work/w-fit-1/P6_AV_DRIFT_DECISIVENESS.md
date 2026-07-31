# P6 — Is `AV_PRESENT_LEAD_MS=20` decisive?

**Source:** `host/libmisterplex/av_clock.hpp` `avDecide` (lead/drop deadband).

```text
// Hold when:  driftMs + leadMs < 0   ⇒  drift < -leadMs
// Present when: driftMs >= -leadMs  (and not Drop)
// Drop when: driftMs > dropMs
```

Steady-state **Present** samples therefore live in **`[-leadMs, dropMs]` by construction**.
With default `leadMs=40`, observed **−21…−38 ms never positive** is exactly the Hold→Present
edge band — **not independent proof of A/V accuracy**. Quoting that band as sync evidence
is circular until the metric is shown to track (or not track) a changed deadband.

## Is lead=20 alone decisive?

| Outcome after confirmed lead=20 | What it proves | What it does NOT prove |
|---|---|---|
| Reported drift band moves to ~[−20, 0] (and `lead_ms=20` appears in logs) | Metric is a **setpoint readout** of the deadband; stop citing as sync evidence | Nothing about true A/V phase |
| Band **does not** move while logs still show `lead_ms=40` | Conf did not apply — **test invalid** | — |
| Band does not move **and** logs show `lead_ms=20` / `hold_edge_ms=-20` | **Not** proof of an accurate clock | Still consistent with: another clamp, sampling only Present decisions inside a different path, stale binary, or a second writer of the drift field |

**Verdict: lead=20 alone is PARTIALLY decisive.**

- **Tracks setpoint → decisive “readout”** (clear win for the falsifier).
- **Does not track with confirmed conf → inconclusive** — cannot distinguish
  “real clock” vs “clamped some other way”. **Do not run a single-shot lead=20
  and treat non-move as vindication of the metric.**

## Decisive recipe (parent runs on device)

### Pre-registration (before any change)

| Lead conf | Expect `lead_ms=` in 1 Hz line | Expect `hold_edge_ms=` | Expect steady Present drift band |
|---:|---:|---:|---|
| 40 (control) | 40 | −40 | mostly in [−40, 0], bias negative |
| 20 (A) | 20 | −20 | band **moves** to ~[−20, 0] if readout |
| 10 (B, optional) | 10 | −10 | band moves again ~[−10, 0] |

If metric is **real** (not deadband-limited): band **does not** follow lead across **two**
confirmed lead changes **and** a third cross-check (below).

### Exact conf / measurement

1. **Control (lead=40):** soak ≥60 s playing known 24 fps source. Capture 1 Hz lines:
   `drift_ms=`, `lead_ms=`, `hold_edge_ms=`, `vfps=`, `pfps=`, residual if present.
2. **Set** in conf next to the live daemon (same path the process reads):
   ```text
   AV_PRESENT_LEAD_MS=20
   ```
   Restart daemon (or full pair). Confirm boot/log shows conf applied.
3. **A:** same title, ≥60 s. Require `lead_ms=20` and `hold_edge_ms=-20` on the line
   **before** interpreting drift. Histogram `drift_ms` (or min/max/median of Present samples).
4. **Optional B:** `AV_PRESENT_LEAD_MS=10`, repeat. Two-step tracking kills “lucky noise”.
5. **Restore** `AV_PRESENT_LEAD_MS=40`.
6. **If A/B do not move with confirmed lead:** add temporary raw log
   `raw_drift_ms = clockMs - frameMs` **before** `avDecide` (code change) and compare
   raw vs decided drift — that is the only silicon-cheap way to separate clamp-elsewhere
   from true phase. Until that exists, non-move remains **UNSCORED**, not PASS.

### Host unit already encodes the edge (no device)

```text
avDecide(-38, lead=40) → Present
avDecide(-38, lead=20) → Hold
```

(`tests/unit/test_frame_ledger.cpp` deadband cases.)

### vfps / pfps usability

- **Before:** cumulative `presentCount/elapsed` from session start + `.substr(0,4)` →
  “23.6→23.9” is an averaging artifact; 23.90 vs 23.99 indistinguishable.
- **After (this branch):** 1 Hz line prints **windowed** `vfps=`/`pfps=` (`dframes/dwall`
  since last line) plus `vfps_avg=`/`pfps_avg=` cumulative, via `formatFps3` (%.3f).
- **Usable for soak health:** windowed rates only. Cumulative avg is trend context, not
  “improving health”.
