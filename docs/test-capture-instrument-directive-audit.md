# Capture-instrument directive audit (W-GATE)

Audit date: 2026-07-28. Branch: `w-gate-inst-vacuity`.

## Raw findings first

Static scan before fixes:

```text
stale default capture device in scripts/tests: /dev/video4
raw capture paths in active harnesses: yuyv422
human-scoreable gate: tests/hw/test_bank_release_visual.sh could emit HUMAN_RESULT=PASS
manual confirmation script: scripts/validate_playback_controls_hw.sh accepted read/--yes confirmations
```

Post-fix harness defaults:

```text
device=/dev/video0
format=mjpeg
size=1280x720
fps=60
raw_yuyv=refused before device access
human_questionnaire_pass=removed
```

## Gate assertions

Literal comparisons added to `tests/unit/test_capture_rig.py`:

```text
check_edges.DEFAULT_DEV == "/dev/video0"
check_edges.DEFAULT_FORMAT == "mjpeg"
check_edges.DEFAULT_SIZE == "1280x720"
hw_visual_compare.DEFAULT_DEV == "/dev/video0"
hw_visual_compare.DEFAULT_FORMAT == "mjpeg"
hw_visual_compare.DEFAULT_SIZE == "1280x720"
hw_visual_compare.DEFAULT_FPS == "60"
"read -r ans" not in validate_playback_controls_hw.sh
"[assumed yes]" not in validate_playback_controls_hw.sh
"HUMAN_RESULT=PASS" not in test_bank_release_visual.sh
"PLEASE ANSWER" not in test_bank_release_visual.sh
```

Literal comparison added to `tests/unit/test_hw_visual_compare.py`:

```text
hw_visual_compare.py capture --input-format yuyv422
  returns rc=2 with "raw UVC capture formats are forbidden"
```

What this does not cover: it does not prove live HDMI content quality and does
not open `/dev/video0`; W-E2E owns the capture instrument. It prevents stale
device/raw-mode/human-confirmation gates from reporting green before a real
capture grader scores no-signal, valid-black, and valid-with-content.

## Red/green proof

```text
CAPTURE_DEFAULT_RED_RC=1
AssertionError: edge capture default must be /dev/video0, got /dev/video4

CAPTURE_DEFAULT_RESTORE_RC=0
PASS capture harness defaults to /dev/video0 MJPEG 1280x720@60 with no human confirmation

RAW_REFUSAL_RED_RC=1
raw YUYV capture must be refused before touching the device

RAW_REFUSAL_RESTORE_RC=0
PASS raw YUYV capture mode refused before device access
```

Validation:

```text
python3 tests/unit/test_capture_rig.py                         rc=0
python3 tests/unit/test_hw_visual_compare.py                    rc=0
python3 scripts/check_pipe_exit_safety.py                       rc=0
python3 tests/unit/test_unit_rollcall.py                        rc=0
make unit                                                       rc=0
```
