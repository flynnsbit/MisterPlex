# PARENT CARD — ERROR 17 provenance + colour B7 (w-instr)

**Branch:** `w-instr-provenance`  
**Worktree:** `.worktrees/w-instr-provenance`  
**Tool:** `tools/hdmi_motion_instrument.py`

## Why

Parent ERROR 17: `hdmi_motion_instrument.py` printed a hardcoded `src_fps=23.976…`
next to measured fields; two sources agreed without measuring the asset; parent
published a false 24-vs-23.976 defect. rd-review B7: colour was green-dominance
only (magenta / greyscale / U/V-swap / blue passed COLOR_OK).

## What shipped

1. **Every rate scalar prints `value [provenance]`** — bare numbers forbidden.
2. **Tokens (aligned with daemon / w-cpu-1):**
   - `measured` | `caller_supplied` | `DEFAULT_ASSUMED`
   - extension: `caller_supplied_measured` (PMS `frameRate=` / ffmpeg banner)
3. **Rate gates refuse assumed fps:** if src or cap is not authoritative →
   `rate=RATE_UNSCORED`, `expected=UNSCORED [UNSCORED_fps_not_authoritative]`
   (never a guessed number). Revisit (bank-swap) remains fps-independent.
4. **CLI:**
   ```bash
   --source-fps 24 --source-fps-src caller_supplied_measured
   --capture-fps 30.5587   # or measure via PNG mtime / --capture-wall-s
   ```
5. **Colour B7:** green_cast | chroma_cast (magenta/blue) | chroma_constant/greyscale
   | uv_swap. Label includes `CHROMA_CONSTANT` + `UV_SWAP` when hit.

## Daemon coordination (w-cpu-1)

Use the **same three tokens** on supply_bucket / cadence lines:
`measured` | `caller_supplied` | `DEFAULT_ASSUMED`.

Live disease still present on main telemetry line: trailing `tag=measured` beside
`fps_src=caller_supplied` / `expected_frames` from assumed rate
(`media_player.cpp` supply path). w-cpu-1 owns measuring true source fps and
removing the blanket `tag=measured`. Glass tool will accept daemon
`fps_src=measured` via `--source-fps-src measured` when that lands.

## Parent commands (host only; direct rc — never pipe)

```bash
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-instr-provenance
cd "$WT"

# Self-test (synthetic red-before-green for green/magenta/blue/grey/uv/structure/rate)
python3 tools/hdmi_motion_instrument.py --self-test
echo "true rc=$?"

# RED colour+structure: archived broken 480p
python3 tools/hdmi_motion_instrument.py /tmp/cap480a --warmup-skip 15
echo "true rc=$?"
# expect: color=GREEN+CHROMA+CHROMA_CONSTANT+GREYSCALE_CAST_FAIL
#         structure=VERT_DUP+HORIZ_WRAP  VERDICT=STRUCTURE_FAIL rc=3

# GREEN colour control
python3 tools/hdmi_motion_instrument.py /tmp/cap480b --warmup-skip 15
echo "true rc=$?"
# expect: color=COLOR_OK structure=STRUCTURE_OK
#         expected=UNSCORED when src_fps DEFAULT_ASSUMED
#         (overall may be RATE_FAIL on measured revisits=2 — OCR integrity,
#          not a colour pass/fail; colour dimension is COLOR_OK)

# Authoritative PMS rate (frameRate=24.000)
python3 tools/hdmi_motion_instrument.py /tmp/cap480b --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured
echo "true rc=$?"
# expect: src_fps=24.0 [caller_supplied_measured] expected=0.7854 [derived_src_over_cap]
```

## Host validation (this lane, quoted)

| run | true rc | color | expected | notes |
|---|---|---|---|---|
| `--self-test` | **0** | synthetic COLOR_FAIL paths | — | SELF_TEST_OK + flash excursion unit |
| `/tmp/cap480a` | **3** | GREEN+CHROMA+CHROMA_CONSTANT+GREYSCALE_CAST_FAIL | UNSCORED | STRUCTURE_FAIL |
| `/tmp/cap480b` + PMS fps | **0** | COLOR_OK STRUCTURE_OK RATE_OK | 0.7854 [derived] | revisits=0 after flash UNREADABLE |

### Blind-and-RED fix (cap480b revisits=2) — diagnosis (3)

**Verdict class: OCR misread, not display fault, not threshold loosen.**

Measured counter CSV before fix (exported from same PNGs):

Frames are `f_001.png`… so `cap_idx=i` → `f_{i+1:03d}.png`.

| cap_idx | PNG | n OCR | tier/raw | mean_luma | fate |
|---|---|---|---|---|---|
| 47 | f_048.png | 311 | TREK24 tier10 | 4.9 | keep |
| **48** | **f_049.png** | **322** | `field_inv_e2…:=322` | **171.4** | **UNREADABLE** |
| **49** | **f_050.png** | **323** | `field_inv_e1…:=323` | **171.4** | **UNREADABLE** |
| **50** | **f_051.png** | **323** | `field_inv_e1…:=323` | **171.4** | **UNREADABLE** |
| 51 | f_052.png | 314 | TREK24 tier10 | 5.0 | keep |
| 60–62 | f_061… | 322,322,323 | TREK24 tier10 | ~5 | keep (real later) |
| 79–80 | f_080/081 | 33→337/338 | field_inv trunc | 171.4 | digit recovery |

Flash OCR 322/323 between real 311 and 314 made later real 322/323 look like
`non_adjacent_revisits=2`. **Parent-view:** `/tmp/cap480b/f_049.png` `f_050.png`
`f_051.png` (white FLASH). No threshold change — multi-run OCR excursion marks
those reads **UNREADABLE** (same disease class as bare `src_fps`).

Bank-swap ping-pong still RATE_FAIL (self-test). Real +11 device skip still kept.

### After fix (quoted)

```
cap480b_png true rc=0
ocr_reject cap_idx=48/49/50 … ocr_excursion_unreadable
motion=MOTION_OK color=COLOR_OK structure=STRUCTURE_OK rate=RATE_OK
revisits=0 [measured] VERDICT=MOTION_OK rc=0

cap480a_png true rc=3
VERDICT=STRUCTURE_FAIL rc=3  (color still GREEN+CHROMA+CHROMA_CONSTANT+GREYSCALE)
```

## Severity ladder (unchanged)

`STRUCTURE_FAIL 3 > COLOR_FAIL 2 > FREEZE 1 > OK 0 > UNSCORED 77`  
(+ `RATE_FAIL 4` for rate/revisit integrity). Measured failure never decays to 77.
