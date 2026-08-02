# PARENT CARD — CAPTURE_NO_SIGNAL (dead grabber ≠ device blank)

Branch: `w-instr-provenance`
Tool: `tools/hdmi_motion_instrument.py` + `tools/grabber_preflight.py`

## Why
Parent nearly rolled back a healthy daemon when MacroSilicon unlocked
(`Active 0×0`, every pixel=7, stddev=0). Instrument correctly returned
rc=77 but said only `insufficient_decodes=0` and printed `COLOR_OK` on
non-frames — easy to misread as a device blank under pressure.

## Design (locked)
| Item | Choice | Why |
|------|--------|-----|
| Frame rule | `min==max` (⇒ std=0) → `NO_SIGNAL` | Uniform synthetic is grabber absent, **not** black content |
| Burst rule | picture_frames==0 AND no_signal ≥ half burst → `CAPTURE_NO_SIGNAL` | Names the capture path |
| Exit | **rc=78** | Distinct from device UNSCORED **77** so scripts/humans cannot confuse dead grabber with idle/no-counter |
| colour/structure | `COLOR_UNASSESSABLE_NO_SIGNAL` / `STRUCTURE_UNASSESSABLE_NO_SIGNAL` | Never emit OK on unassessable input |
| device_state | `UNKNOWN` | Instrument cannot speak for MiSTer when capture path is dead |
| capture_path | `FAULT_NO_SIGNAL` | Explicit grabber blame |

Severity note: 78 is a **capture-path** code, not a device hard-fail.
Device ladder still: STRUCTURE 3 > COLOR 2 > STARVED 5 > RATE 4 > FREEZE 1 > OK 0.
Capture ladder: CAPTURE_NO_SIGNAL 78 > UNSCORED 77. Measured device fails never decay to 77/78.

## Greyscale footgun (self-caught)
Uniform grey fixtures are physics-identical to no-signal. GREYSCALE RBG now
uses **non-uniform** R=G=B texture so dead-chroma still scores COLOR_FAIL GREYSCALE
while uniform-7 stays CAPTURE_NO_SIGNAL.

## Commands (parent — direct rc, never pipe)

```bash
# Pre-flight BEFORE any cast/session (host only)
python3 tools/grabber_preflight.py
# expect locked: VERDICT=CAPTURE_OK rc=0
# unlocked today: VERDICT=CAPTURE_NO_SIGNAL rc=78 + ACTION re-plug

# Archived no-signal (repo copies of parent's /tmp/capPlay|/tmp/capIdle2)
python3 tools/hdmi_motion_instrument.py files/device-evidence/capture_no_signal_play --warmup-skip 0 --min-reads 1
echo "true rc=$?"   # expect 78

python3 tools/hdmi_motion_instrument.py files/device-evidence/capture_no_signal_idle2 --warmup-skip 0 --min-reads 1
echo "true rc=$?"   # expect 78

# Real dark contrast (parent /tmp/capA/f_045.png) — NOT no-signal
python3 tools/hdmi_motion_instrument.py files/device-evidence/real_dark/f_045.png --warmup-skip 0 --min-reads 1
echo "true rc=$?"   # expect != 78 (single-frame FREEZE rc=1 is OK; has counter n=717)

python3 tools/hdmi_motion_instrument.py --self-test
echo "true rc=$?"   # expect 0
```

## RBG evidence (this lane, true rc direct)

| Input | VERDICT | rc | color | structure | notes |
|-------|---------|----|-------|-----------|-------|
| `files/device-evidence/capture_no_signal_play` | CAPTURE_NO_SIGNAL | **78** | COLOR_UNASSESSABLE_NO_SIGNAL | STRUCTURE_UNASSESSABLE_NO_SIGNAL | pixel=7 uniform |
| `files/device-evidence/capture_no_signal_idle2` | CAPTURE_NO_SIGNAL | **78** | same | same | same |
| `files/device-evidence/real_dark/f_045.png` | FREEZE | **1** | COLOR_OK | STRUCTURE_OK | mean~3.5 std>0; counter n=717; **not** no-signal |
| `grabber_preflight.py` (live) | CAPTURE_NO_SIGNAL | **78** | — | — | dv active=0x0 pixelclock=0; sample pixel=7 |
| `--self-test` | SELF_TEST_OK | **0** | — | — | includes no-signal + non-uniform greyscale |

Logs: `.agent-work/w-instr/nosig_rbg/{play,idle2,real_dark,preflight}.txt`

## Output shape (no-signal)
```
motion=UNSCORED color=COLOR_UNASSESSABLE_NO_SIGNAL structure=STRUCTURE_UNASSESSABLE_NO_SIGNAL ...
capture_path=FAULT_NO_SIGNAL device_state=UNKNOWN no_signal_frames=N picture_frames=0 — uniform min==max is NO CAPTURE (grabber), not a black screen
reason=CAPTURE_NO_SIGNAL ... This is NOT a black screen and NOT a device fault ...
VERDICT=CAPTURE_NO_SIGNAL rc=78 ...
```

## Preflight quotes what it reads
- `v4l2-ctl --query-dv-timings` → Active width/height, Pixelclock (0 = unlocked) `[measured]`
- optional sample frame min/max/std `[measured]`
- ACTION line: re-plug / power-cycle MS2109; do NOT rollback device software on this symptom alone

## Rule 0
No device touched. Archives only + live preflight query of grabber state (host).
