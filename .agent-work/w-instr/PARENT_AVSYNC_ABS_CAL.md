# Parent card — absolute offset honesty + calibration + wander floor + A/B sigma

**Tool:** `tools/avsync_measure_hdmi.py`  
**Branch:** `w-avsync-hdmi-measure`  
**Agent does not touch the device.**

## (1) Severity when `calibration=NONE`

| Situation | Old (wrong) | New |
|-----------|-------------|-----|
| abs median > tol, no cal | `OFFSET_FAIL rc=2` (looks like device lipsync defect) | **Never** `OFFSET_FAIL` |
| abs median > tol, no cal, slope/wander OK | same | `VERDICT=ABS_OFFSET_UNSCOREABLE rc=77` — **not a PASS** |
| abs median > tol, no cal, wander/drift real | buried under OFFSET_FAIL | **WANDER_FAIL rc=5** / **DRIFT_FAIL rc=4** first (attributable) |
| abs median > tol, **trusted** known-zero cal | OFFSET_FAIL | still `OFFSET_FAIL rc=2` |

Reason string states explicitly: do **not** widen `--tol-ms` to silence this.

## (2) Calibration — what is physically possible

**True known-zero into the MS2109 is NOT achievable with only:**
- MiSTer (that is the DUT — its A is unknown)
- this workstation
- MacroSilicon grabber on `/dev/video0` + `hw:0,0`

Host HDMI loopback measures `B_grabber + A_host_player`, and host player lipsync is **not** a certified zero. Saving a DUT median as “cal” is circular.

**Hardware that would make absolute real:** an external HDMI A/V test generator (or equivalent) with **certified simultaneous** flash+beep at the connector → cable → MS2109.

### Procedure when you have a generator

```bash
# 1) Cable: generator HDMI → grabber. MiSTer unplugged from grabber.
# 2) Generator: known-zero flash+beep (or rk=27-class markers with A=0 by design).
fuser -v /dev/video0; echo "true rc=$?"
tools/avsync_measure_hdmi.py --calibrate \
  --known-zero-kind external_hdmi_generator \
  --duration 30 --tol-ms 42 \
  --out .agent-work/w-instr/avsync_cal_gen \
  --calibration-out .agent-work/w-instr/avsync_cal_gen/cal.json
echo "true rc=$?"
# cal.json has absolute_trusted=true only for this kind

# 3) Re-cable MiSTer → grabber; measure DUT with cal:
tools/avsync_measure_hdmi.py --duration 60 --tol-ms 42 \
  --calibration .agent-work/w-instr/avsync_cal_gen/cal.json \
  --out .agent-work/w-instr/avsync_dut
echo "true rc=$?"
# Now abs median may legitimately OFFSET_FAIL rc=2 or PASS rc=0
```

### Other `--known-zero-kind` values (honest labels)

| kind | `absolute_trusted` | Use |
|------|--------------------|-----|
| `external_hdmi_generator` | **true** | only path for device absolute OFFSET_FAIL/PASS |
| `file_pts_synthetic` | true **only** with `--input` file | tool/file-path checks; not live grabber B |
| `host_loopback_UNTRUSTED` | **false** | forensic only; must not cite as device absolute |

`--calibrate` without `--known-zero-kind` → **rc=77 refuse** (no more silent DUT-as-zero).

## (3) Quant floor + wander

At 30 fps, `T=33 ms` → `video_quant_rms_ms = T/√12 ≈ 9.53` (printed every run).

```
wander_rms_tol = sqrt(quant_rms² + excess_budget²)
excess_budget default = 8.0 ms (DEFAULT_ASSUMED) or --wander-excess-tol-ms
excess_wander_rms = sqrt(max(0, residual² - quant²))
```

Parent arms: residual 16.05 / 14.29 → excess ≈ **12.92 / 10.66** after floor removal.

## (4) A/B delta significance (no hand arithmetic)

```bash
tools/avsync_measure_hdmi.py \
  --compare-json-a report_480.json --compare-json-b report_240.json \
  --compare-label-a 480p --compare-label-b 240p
echo "true rc=$?"
# prints ab_delta_ms, se_delta_ms, sigma, significant_2sigma/3sigma
# plus between-run context 25 ms (parent n=16)
```

## Host evidence on YOUR captures (true rc, no pipe)

```text
# default excess budget 8 → wander still attributable FAIL (not OFFSET_FAIL)
/tmp/lipsync/av.mkv     → VERDICT=WANDER_FAIL rc=5   (was OFFSET_FAIL rc=2)
/tmp/lipsync240/av.mkv  → VERDICT=WANDER_FAIL rc=5   (was OFFSET_FAIL rc=2)

# prove abs path when wander not gating (--wander-excess-tol-ms 20):
/tmp/lipsync/av.mkv     → VERDICT=ABS_OFFSET_UNSCOREABLE rc=77

# A/B on rescored JSONs:
ab_delta_ms=+7.00  se_delta_ms=5.72  sigma=1.22  significant_2sigma=False
(matches parent +7.0 ± 5.7)

self-test true rc=0
  uncalibrated abs → ABS_OFFSET_UNSCOREABLE rc=77
  trusted cal abs  → OFFSET_FAIL rc=2
```

```bash
python3 tools/avsync_measure_hdmi.py --self-test; echo "true rc=$?"

python3 tools/avsync_measure_hdmi.py --input /tmp/lipsync/av.mkv \
  --out .agent-work/w-instr/lipsync_rescore --label rk27_480p --tol-ms 42 --min-pairs 12
echo "true rc=$?"   # expect 5 WANDER_FAIL (not 2)

python3 tools/avsync_measure_hdmi.py \
  --compare-json-a .agent-work/w-instr/lipsync_rescore/rk27_480p_report.json \
  --compare-json-b .agent-work/w-instr/lipsync_rescore/rk27_240p_report.json \
  --compare-label-a 480p --compare-label-b 240p
echo "true rc=$?"
```
