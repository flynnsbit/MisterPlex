# Parent device commands — fabric frames_done hold histogram

Agent does **not** touch the device. Parent runs these while the OCR fixture
plays on the product 480p (or 720p) path with DDR present.

## Pre-register (before any numbers)

| Band | frac holds ≥4 | Meaning |
|------|---------------|---------|
| healthy | [0.00, 0.03] | pure async 2/3 + poll noise → HDMI ge4 is capture/tear bias |
| hdmi_match | [0.08, 0.13] | matches parent HDMI plateau ge4≈0.103 → **real device** |
| lean device | [0.05, 0.15] | device lean → w-geom RTL question |

Parent HDMI plateau (caller_supplied): `{1:43,2:661,3:429,4:123,5:7}` mean 2.517, frac_ge4=0.1029.

Counter: PLXD `frames_done` [63:48] @ phys `0x300FF128` (product YUV doorbell+0x128).
`bank_vsync_count` is **not** packed — holds use mono_ms / T_vsync (DEFAULT_ASSUMED 1000/60 unless measured).

## 1) Poll during playback (≥60 s, period ≤2 ms)

```bash
cd /home/flynnsbit/Projects/MisterPlex
OUT=/tmp/fabric_fd_hold.csv DURATION_S=90 PERIOD_MS=2 \
  ./scripts/poll_plxd_frames_done_hold.sh
# true rc captured directly:
true_rc=$?; echo "true rc=$true_rc"
```

Confirm core is running and fixture is playing before poll. If rows < 50, fix devmem2/path.

## 2) Score (host)

```bash
python3 tools/fabric_frames_done_hold_hist.py --csv /tmp/fabric_fd_hold.csv
true_rc=$?; echo "true rc=$true_rc"
# optional measured vsync period:
# python3 tools/fabric_frames_done_hold_hist.py --csv /tmp/fabric_fd_hold.csv --t-vsync-ms 16.667
```

## 3) Alternate: media log (if frames_done_mono_ms is logged)

```bash
python3 tools/fabric_frames_done_hold_hist.py --from-media-log /path/to/misterplexd.log
true_rc=$?; echo "true rc=$true_rc"
```

## 4) Host gate (no device)

```bash
python3 tools/fabric_frames_done_hold_hist.py --self-test
true_rc=$?; echo "true rc=$true_rc"   # expect 0
```

## Decision

- `FABRIC_HEALTHY_2_3` → no DDR hold fix; HDMI 4/5 plateaus are instrument/capture.
- `FABRIC_MATCHES_HDMI_GE4` / `FABRIC_DEVICE_LEAN_BAND` → real device; hand to w-geom.

## Glass reference (unchanged)

```bash
python3 tools/glass_template_skip.py /tmp/p60/png --templates /tmp/p60/T60.pkl \
  --pts /tmp/p60/pts.csv --source-fps 24 --capture-fps 60 --refresh-hz 60 --force-mode 720
true_rc=$?; echo "true rc=$true_rc"   # expect 2, genuine=1 v=5578
```

`tools/hdmi_motion_instrument.py` is **deprecated** for display-loss scoring.
