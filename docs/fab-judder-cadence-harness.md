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

`JUDDER` is **conformance to the pattern's own clean class** (lower better).
Clean 3:2 and clean 2:1 both score ~0 — it catches pathology, it does **not**
rank 24 vs 30. For ranking use absolute hold irregularity:

| Metric | CLEAN_2_1 | CLEAN_3_2 | PATH_2_2_2_4 |
|--------|-----------|-----------|--------------|
| HOLD_MEAN | 2.0 | 2.5 | 2.5 |
| HOLD_STDEV | 0.0 | 0.5 | ≈0.866 |
| HOLD_MAXDEV | 0.0 | 0.5 | 1.5 |

Ordering assertion (red-twin): `HOLD_STDEV/MAXDEV`: 2_1 < 3_2 < 2224.
Both families share mean 2.5 and 10 frames / 4 holds — **ratio metrics tie
them; only the distribution separates them.**

**Static is judder=0 with an explicit FROZEN flag** — a naive
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

## Real-capture pitfalls (read before first glass run)

These are easy to misread. The harness is fail-closed where it can be; the rest
is annotation, not a silent pass.

| Symptom | Fields | Meaning | Do **not** conclude |
|---------|--------|---------|---------------------|
| Too few frames / empty dir | exit **4**, no `PATTERN=` | DEGENERATE — not a cadence claim | “clean 2:1” |
| Device missing/busy / decode fail | exit **3** `UNKNOWN_GRABBER` / IO | grabber problem | fabric judder |
| One long hold, `FROZEN=1` | `PATTERN=FROZEN`, `JUDDER=0` | static/paused content | “perfectly smooth 2:1” (JUDDER ties cleans at 0; FROZEN is the flag) |
| `DROPPED_HINT>0` | isolated `1`s or `≥5` holds in RUN_LENGTHS | *hint* of missing capture slots or glitch | definitive dropped-frame count |
| `IRREGULAR` | residuals high to all clean classes | mixed/unknown cadence | force-fit to 3:2 or 2:1 |
| Partial capture (window shorter than a few pulldown cycles) | short `RUN_LENGTHS` | classifier may pick wrong phase | trust PATTERN without looking at RUN_LENGTHS |
| Warm-up not discarded | black / locked frames at start | false NEW/repeat edges | any PATTERN from a bare `-frames:v 1` path |

**Ranking 24 vs 30:** use `HOLD_STDEV` / `HOLD_MAXDEV`, not `JUDDER`.
Clean 3:2 and clean 2:1 both have `JUDDER≈0`.

**Minimum useful window:** ≥ ~1 s at 60 Hz (≥8 frames after warm-up; prefer
3 s (`hdmi_capture_cadence.sh OUT 3`) so several 3:2 periods are visible.

**Always paste:** `RUN_LENGTHS=`, `PATTERN=`, `HOLD_STDEV=`, `HOLD_MAXDEV=`,
`FROZEN=`, `DROPPED_HINT=`, and the process `true rc=`.
