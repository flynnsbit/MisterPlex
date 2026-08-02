# PARENT CARD — B7 colour hole + ERROR 17 provenance (w-instr)

Branch: `w-instr-provenance`
SHA: 52e0c6804a49616474607aabce3fc5242ce44629

## Standing rule owned — provenance labelling (ERROR 17)
Every load-bearing value is tagged `measured` | `caller_supplied` | `caller_supplied_measured` | `DEFAULT_ASSUMED`.
- Defaults: `src_fps=24.000 [DEFAULT_ASSUMED]`, never 23.976.
- `RATE_OK` never mints on assumed fps.
- `--strict-fps` refuses MOTION_OK when fps assumed; **never decays** STRUCTURE/COLOR/STARVED/RATE/FREEZE → 77.
- `--capture-fps-src` / `--source-fps-src` honored on PNG path.

## B7 colour — distinct labelled defects (not green-only)

| class | how detected | label |
|-------|--------------|-------|
| green cast (U,V~0) | green_frac + mean_rgb fingerprint | `GREEN` |
| magenta (U&V high / R+B crush G) | channel means + spread | `MAGENTA` |
| blue cast | B-primary + chroma spread | `BLUE` |
| greyscale (dead chroma on lit) | active_chroma_mean≈0 | `GREYSCALE` |
| UV swap | saturated primary inversion | `UV_SWAP` |
| red bar missing (flash fixture) | white field w/o red bar | `RED_BAR_MISSING` |
| vertical dup / horiz wrap | structure_metrics | `VERT_DUP` / `HORIZ_WRAP` → STRUCTURE_FAIL |

Severity unchanged: STRUCTURE > COLOR > STARVED > RATE > FREEZE > OK > 77.

### Adaptive evidence floor
`color_need = min(3, n_non_warmup)` so a **single archived defect PNG** hard-fails (was stuck at 77).
Single file without `--one` goes through `score_burst` (not per-frame dump).

## Red-before-green (direct `true rc`, no pipe)

| evidence | verdict | true rc | labels |
|----------|---------|---------|--------|
| `files/device-evidence/le3_c5382bee_broken.png` | COLOR_FAIL | **2** | GREEN+CHROMA |
| `files/device-evidence/DDR_PLAYBACK_CORRECT_*.png` | UNSCORED | **77** | COLOR_OK STRUCTURE_OK (no counter — not a pass) |
| cap480a magenta f018–021 | STRUCTURE_FAIL | **3** | MAGENTA+RED_BAR_MISSING + VERT_DUP+HORIZ_WRAP |
| cap480a green f022–025 | STRUCTURE_FAIL | **3** | GREEN+CHROMA + VERT_DUP |
| `/tmp/cap480a` full | STRUCTURE_FAIL | **3** | GREEN+MAGENTA+BLUE+GREYSCALE+RED_BAR_MISSING; vdup=15 wrap=8 |
| `/tmp/cap480b` full | MOTION_OK | **0** | COLOR_OK STRUCTURE_OK |
| synthetic grey/blue/magenta/uv | COLOR_FAIL | 2 | per-kind self-test |
| `SELF_TEST_OK` | — | **0** | |

### Commands
```bash
python3 tools/hdmi_motion_instrument.py files/device-evidence/le3_c5382bee_broken.png \
  --warmup-skip 0 --min-reads 1
echo "true rc=$?"   # expect 2 COLOR_FAIL GREEN+CHROMA

python3 tools/hdmi_motion_instrument.py files/device-evidence/DDR_PLAYBACK_CORRECT_c5382bee_e9f79de2.png \
  --warmup-skip 0 --min-reads 1
echo "true rc=$?"   # expect 77 UNSCORED, color=COLOR_OK

python3 tools/hdmi_motion_instrument.py /tmp/cap480a \
  --source-fps 24.0 --source-fps-src caller_supplied_measured \
  --capture-fps 30.0 --capture-fps-src measured
echo "true rc=$?"   # expect 3 STRUCTURE_FAIL

python3 tools/hdmi_motion_instrument.py /tmp/cap480b \
  --source-fps 24.0 --source-fps-src caller_supplied_measured \
  --capture-fps 30.0 --capture-fps-src measured
echo "true rc=$?"   # expect 0 MOTION_OK

python3 tools/hdmi_motion_instrument.py --self-test
echo "true rc=$?"   # expect 0
```

## make unit
- Fixed pre-existing rollcall drift: registered `test_fabric_content_window_math` (already in Makefile).
- `make unit` still exits 2 on unrelated missing fit artifact:
  `FAIL: missing fitted freeze .agent-work/w-fit/leftedge3-proj/rtl/ddr_frame_store.sv`
  (test_c5382bee_frames_done_pack.sh) — not instrument scope; not introduced here.
