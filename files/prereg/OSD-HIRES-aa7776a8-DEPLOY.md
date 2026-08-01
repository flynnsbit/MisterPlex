# Pre-registration — deploy after R1–R3 (span reconcile + drop w>=600)

Written **before** parent deploy/capture. Scoring: viewed pixels + quoted logs only.

## Binary

- Branch: `w-osd-hires`
- Worktree `make arm-plexd` → **`md5=972a7794b0616012a2f4aa074b832552`**, `true rc=0`
- Prior `aa7776a8` was `46981b36` (had dead `w>=600`). This binary drops that clause only;
  at true 624×480 product canvas behavior is unchanged (still 12×16). **Score this md5.**

## R1 reconciliation (archived silicon, host-measured)

| Artifact | Status |
|---|---|
| `files/device-evidence/osd_hires_0370af91_STOPPED_PASS.png` | **NOT-FOUND** |
| `files/device-evidence/osd_pause_3883f5ab_*` | **NOT-FOUND** |
| `files/device-evidence/overlay_FIXED_db3d9367_stopped.png` | **FOUND** 1920×1080 |

Command (FIXED only available STOPPED archive):

```bash
python3 tools/measure_overlay_word_span.py \
  --image files/device-evidence/overlay_FIXED_db3d9367_stopped.png \
  --expect STOPPED; echo "true rc=$?"
```

Host result this session:

| field | value |
|---|---|
| `ink_span_output_px` | **531** |
| `pred_12x16@2_via624` | 553.8 (err ≈4%) |
| `pred_12x16@2_via640` | 540.0 |
| `pred_8x13@2_via640` | **372.0** ← matches parent **370**, not FIXED pixels |
| `family_at_output` | **12x16** |

**Who is wrong on FIXED:** parent’s **370 out-px is wrong for this file**. Measured ink is **~531**, 12×16-class. Parent 370 is exactly the **8×13@2 via 640** *prediction*, not a measurement of FIXED.

**3883f5ab STOPPED:** cannot re-measure — archive **NOT-FOUND** on this tree. If parent still holds it, run the same tool; until then the silicon contradiction is settled only for FIXED: worker correct, parent 370 incorrect (or from another frame).

## Expected log (STOP / idle, chrome visible)

```
media: idle overlay canvas=624x480 font=12x16 scale=2 chrome=1
```

- PASS: `624x480` + `font=12x16` + `scale=2`
- FAIL: other canvas, `font=8x13`, or missing while panel visible

## STOPPED ink span @ **1920 output px** (vs parent 370)

| band @1920 | meaning |
|---|---|
| **PASS 480–580** | 12×16@2 on bank (FIXED measured **531**) |
| **FAIL 340–400** | 8×13-class; would confirm parent position / short canvas |
| UNSCORED | no STOPPED / tool rc=77 |

```bash
python3 tools/measure_overlay_word_span.py --image CAP.png --expect STOPPED; echo "true rc=$?"
python3 tools/readback_overlay_text.py --image CAP.png --expect STOPPED; echo "true rc=$?"
```

**Falsify worker:** span ∈ 340–400 with legible STOPPED, or log `font=8x13` / canvas ≠ 624×480.  
**Falsify parent 370-on-FIXED:** already done — host 531 on only on-disk STOPPED archive.

## Other (unchanged)

| ID | PASS | FAIL |
|---|---|---|
| P1 empty-center | mean luma ~50–70 grey | ≤35 black hole |
| P2 title | muted title if resolve has one | black hole |
| P3 sticky PAUSED | panel past 6s; bar≈t/T | missing |

Conf: do **not** change user DECODE/PRESENT/IDLE_SCREEN.
