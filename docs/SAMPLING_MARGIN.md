# Sampling margin convention (repo-wide)

**Status:** binding for every measurement gate and instrument.  
**Origin:** parent ERROR 18 / ERROR 19 (2026-08-01) — results published from captures with zero or negative sampling margin, then withdrawn.

## Rule

Any gate that claims a **pass** or **fail** about display/audio timing, frame skips, freezes, or lip-sync **must**:

1. **Declare** its sampling margin in the report:
   - `min_hold_ms` — shortest time the phenomenon under test is guaranteed visible
   - `max_sample_interval_ms` — largest gap between samples (prefer **measured PTS**, never `di/capture_fps` alone)
   - `margin_ms = min_hold_ms - max_sample_interval_ms`
   - provenance tags: `measured` / `caller_supplied` / `DEFAULT_ASSUMED` on every rate used

2. **Refuse to score** when margin is inadequate:
   - If `max_sample_interval_ms >= min_hold_ms` (zero or negative margin) →  
     **`verdict=UNSCORED`** and **`rc=77`** (SKIP-NOT-PASS).  
   - **Never PASS. Never FAIL** on skip/freeze/loss counts when margin is inadequate.

3. **RTL floor for DDR present path** (product silicon):  
   `ddr_frame_store` applies bank swap on `vsync_pulse` when `swap_pending && pending_ready`  
   (`fpga/Plex_MiSTer/rtl/ddr_frame_store.sv` swap block).  
   Minimum on-glass hold of a presented bank is **one refresh**:  
   `min_hold_ms = 1000 / refresh_hz`  
   (e.g. 16.667 ms at 60 Hz).  
   **Not** `2 * refresh` and **not** `floor(refresh/src)` 3:2 — that assumption caused ERROR 18/19.

## What went wrong

| Error | Capture | Hold | Margin | Bad report |
|-------|---------|------|--------|------------|
| ERROR 18 | 30 fps (~33.3 ms) | 33.3 ms display hold | **0** | "22 skips / 1.54%" — withdrawn |
| ERROR 19 | 60 fps (~16.67 ms) | **16.67 ms** (1 vsync) | **≤0** | "1 skip / 0.070%" — withdrawn |

## Reference implementation

`tools/glass_template_skip.py` (F4):

- Builds `sampling_margin` from PTS intervals + `min_hold_ms = 1000/refresh_hz`
- `refuse_skip_verdict` → `rc=77` `UNSCORED` when margin bad
- Distinct rcs: `SKIP_FAIL=2` vs `INSTRUMENT_OR_FIXTURE_FAIL=3` (never share)

Self-check:

```bash
python3 tools/glass_template_skip.py --self-test; echo "true rc=$?"
# expect PASS ERROR18/ERROR19 refuse rc=77 and PASS D2 distinct rc
```

## Applying to other instruments

When adding or editing a measurement tool under `tools/` or `tests/hw/`:

- [ ] Document `min_hold_ms` source (RTL cite or physics)
- [ ] Prefer PTS/`measured` intervals over index/`capture_fps` arithmetic
- [ ] Emit `sampling_margin` object in JSON/text report
- [ ] Map inadequate margin → `UNSCORED`/`rc=77`, never pass/fail
- [ ] Tag every rate `*_src=measured|caller_supplied|DEFAULT_ASSUMED`

`rc=77` / `UNSCORED` is **never** a pass in aggregate reporting  
(`scripts/run_with_skip_summary.py`).
