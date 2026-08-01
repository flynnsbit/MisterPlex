# Parent card — artifact pair stamp + vertical unique-row scorer

**Branch:** `w-avsync-hdmi-measure`  
**Agent does not touch the device.**

## Fleet rule (implemented)

**No measurement without artifact pair (RBF md5 + daemon md5).**  
Missing pair ⇒ `UNSCORED` rc=77. Short 8-hex prefixes refused (need full 32).

Also partition by `decode_src`. Mixed decode_src in one log ⇒ UNSCORED. Never pool across decode_src / phase / sigma classes.

### Collect live stamp (parent, on lab host)

```bash
tools/avsync_stamp_artifacts.sh > .agent-work/w-instr/stamp_live.json
echo "true rc=$?"
cat .agent-work/w-instr/stamp_live.json
# daemon via md5sum /proc/PID/exe (works if path shows deleted)
# RBF: md5 /media/fat/_Utility/Plex.rbf
```

Or export:

```bash
export MISTERPLEX_RBF_MD5=<32hex>
export MISTERPLEX_DAEMON_MD5=<32hex>
export MISTERPLEX_DECODE_SRC=caller_supplied   # or conf:… from log
```

### Score cadence (stamped)

```bash
python3 tools/publish_cadence_score.py daemon.log --phase session_end \
  --stamp-json .agent-work/w-instr/stamp_live.json \
  --vsync-hz "$MISTERPLEX_VSYNC_HZ"
echo "true rc=$?"
# unstamped → 77; hitch p_one_refresh_hold≥0.02 → 2; sigma≥mean → 77
```

PRIMARY hitch metric remains **`p_one_refresh_hold`** (not p_ge50, not p_d1 Δfd).

### Measure refresh (stamped)

```bash
fuser -v /dev/video0; echo "true rc=$?"
python3 tools/measure_refresh_hz.py --device /dev/video0 --frames 90 --warmup 15 \
  --stamp-json .agent-work/w-instr/stamp_live.json
echo "true rc=$?"
```

### Vertical unique-row scorer (NOT FFT) — T7 before/after

Direct consecutive-row MAE chain + even/odd dup fraction.

**PRE-REGISTER**

| Mode | PASS when |
|------|-----------|
| `--expect-ceiling-240` | unique_frac ≤ 0.62 AND frac_adjacent_dup ≥ 0.35 |
| `--expect-full-480` | unique_frac ≥ 0.80 AND frac_adjacent_dup ≤ 0.25 |
| flat / low vertical energy | **UNSCORED** (not a pass) |

```bash
# BEFORE (current ceiling still on glass) — detailed content frame, not solid grey
python3 tools/hdmi_vertical_unique_rows.py CAP.png --expect-ceiling-240 \
  --stamp-json .agent-work/w-instr/stamp_live.json \
  --decode-src caller_supplied
echo "true rc=$?"   # expect 0 CEILING_240_HOLD on doubled content

# AFTER T7 RBF — same content class
python3 tools/hdmi_vertical_unique_rows.py CAP_after.png --expect-full-480 \
  --stamp-json .agent-work/w-instr/stamp_live.json
echo "true rc=$?"   # expect 0 FULL_480_OK if fix landed

# Flat control must 77
python3 tools/hdmi_vertical_unique_rows.py mid_grey.png --expect-ceiling-240 \
  --stamp-json .agent-work/w-instr/stamp_live.json
echo "true rc=$?"
```

Still use flat-suite solids for binary ceiling proof:

```bash
python3 tools/hdmi_vstore_discriminate.py --flat-suite CAP_DIR \
  --stamp-json .agent-work/w-instr/stamp_live.json
echo "true rc=$?"
# after T7:
python3 tools/hdmi_vstore_discriminate.py --flat-suite CAP_DIR --expect-after-fix \
  --stamp-json .agent-work/w-instr/stamp_live.json
echo "true rc=$?"
```

### decode_src (daemon)

Logs now emit real `decode_src=` from `setDecodeSizeSource` (`caller_supplied` | `conf:…` | `osd_O4` | `default`), not hardcoded. Redeploy daemon to get it.

### Host gates (agent)

```bash
python3 tools/artifact_stamp.py --self-test; echo "true rc=$?"
python3 tools/hdmi_vertical_unique_rows.py --self-test; echo "true rc=$?"
python3 tools/publish_cadence_score.py --self-test; echo "true rc=$?"
python3 tools/measure_refresh_hz.py --self-test; echo "true rc=$?"
python3 tools/hdmi_vstore_discriminate.py --self-test; echo "true rc=$?"
```

All were **0** at commit time.
