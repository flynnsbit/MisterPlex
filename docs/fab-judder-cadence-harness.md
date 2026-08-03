# Glass judder / cadence harness (w-osd)

**Purpose:** measure 60 Hz glass hold pattern so 24 fps 3:2 vs 30 fps 2:1 vs
pathological `2,2,2,4` is an empirical question, not taste.

**No device for agents.** Parent runs capture on glass when the board is up.

## Scripts

| Path | Role |
|------|------|
| `scripts/hdmi_judder_cadence.py` | Classify ordered frames → `RUN_LENGTHS` + `PATTERN` + `JUDDER` |
| `scripts/hdmi_capture_cadence.sh` | Multi-second `/dev/video0` capture, **warm-up discard**, then analyze |
| `tests/unit/test_hdmi_judder_cadence.sh` | Synthetic red-twin acceptance gate |

## Patterns

| Source | Glass holds | `PATTERN=` |
|--------|-------------|------------|
| 24 fps content, clean telecine | `3,2,3,2,…` | `CLEAN_3_2` |
| 30 fps content, clean duplicate | `2,2,2,2,…` | `CLEAN_2_1` |
| 24 through 30 Hz core → 60 glass | `2,2,2,4,…` | `PATH_2_2_2_4` |
| No content change | one long hold | `FROZEN` / `STATIC_FIELD` |

`JUDDER` is residual vs nearest **clean** telecine (lower better). Pathological
ranks worse than clean. **Static is judder=0 with an explicit flag** — a naive
“every frame is a repeat ⇒ infinite judder” detector is a FAIL of the harness.

## Capture discipline

Same grabber rules as `hdmi_capture_idle.sh`:

- Never bare `ffmpeg -frames:v 1` (false black).
- Default warm-up **20** frames discarded before the analysis window.
- Device busy / missing → `UNKNOWN_GRABBER` rc=3, not a cadence class.
- Too few frames → `DEGENERATE` rc=4, not a cadence class.

```bash
# Parent, device up:
scripts/hdmi_capture_cadence.sh docs/agent-evidence/cadence-24tier 3
scripts/hdmi_capture_cadence.sh docs/agent-evidence/cadence-30tier 3
# Compare PATTERN= and JUDDER= lines (and RUN_LENGTHS=).

# Offline / CI:
scripts/hdmi_capture_cadence.sh --selftest
# or:
tests/unit/test_hdmi_judder_cadence.sh
```

## Analyze-only (already captured PNGs)

```bash
scripts/hdmi_capture_cadence.sh --analyze-only path/to/frames/
python3 scripts/hdmi_judder_cadence.py --frames-dir path/to/frames/
```

## Acceptance (synthetic)

Must distinguish on synthetic moving-bar frames, true rc=0:

1. `3_2` → `CLEAN_3_2`
2. `2_1` → `CLEAN_2_1`
3. `2_2_2_4` → `PATH_2_2_2_4`
4. `static` → `FROZEN` (not CLEAN_*)
5. `partial_motion` → still `CLEAN_2_1` (corner-only motion)
6. Path must **reject** expect `CLEAN_3_2` / `CLEAN_2_1` (rc≠0)
7. `JUDDER(path) > JUDDER(clean_*)` and `JUDDER(static)==0`

## Related

- PLAYING gate: `scripts/parent_playing_gate.sh` (geometry/motion, not pulldown)
- Chrome paint domain: `docs/fab-chrome-paint-domain.md` (post-ascal HDMI_OUT)
- Parent plan: 960×540@24 fits decode budget; @30 fails by ~1.17 ms; 640×360@30 fits
