# Parent-run external HDMI/USB A/V verification

`external_av_sync.py` measures the authority requested for true-480 playback:
the selected HDMI-to-USB V4L2 endpoint and the ALSA capture endpoint on the
same physical USB adapter. It does not cast, deploy, contact a MiSTer, or use a
Plex token.

## Hardware prerequisites

1. A generated marker fixture is already playing, with its matching
   `*.manifest.json` available locally.
2. The exact V4L2 node is known, preferably a `/dev/v4l/by-id/...` symlink.
3. The adapter exposes an ALSA **capture** PCM. If it does not, the result is
   `BLOCKED`, never PASS.
4. The V4L2 input format, size, and frame rate are known.
5. Any HDMI preview using that node has been stopped deliberately. The harness
   never kills or replaces a preview process.
6. A fixed adapter A/V offset has been measured separately.
7. `ffmpeg`, `ffprobe`, `v4l2-ctl`, `arecord`, `fuser`, Python 3, and NumPy are
   installed.
8. The evidence directory is durable and has room for a lossless FFV1 + PCM
   capture.

Hardware execution is parent-only.

## Enumerate without assuming `/dev/video0`

```bash
python3 tests/hw/external_av_sync.py --list-devices
```

The JSON groups each V4L2 endpoint with `matching_audio` endpoints by common
USB sysfs parent. Capture requires explicit `--video-device` and
`--audio-device`; a different USB card is rejected.

## Adapter calibration file

The sign convention is:

```text
audio_minus_video_ms = captured click time - captured flash time
corrected offset     = observed offset - adapter offset
```

Example schema (replace every measured/identity value):

```json
{
  "schema": "misterplex.external-av.adapter-offset.v1",
  "audio_minus_video_ms": -123.4,
  "usb_vendor_id": "abcd",
  "usb_product_id": "1234",
  "usb_serial": "MEASURED-ADAPTER-SERIAL",
  "measured_at": "YYYY-MM-DD",
  "method": "independent known-synchronous source"
}
```

Identity fields are optional, but when present must match the selected video
device. Hardware capture requires non-empty `measured_at` and `method` fields
and accepts **only** `--adapter-offset-file`. `--adapter-offset-ms` is reserved
for synthetic/offline analysis and is rejected before hardware setup.

## Capture and measure

```bash
EVIDENCE_ROOT="${MISTERPLEX_EVIDENCE_ROOT:?set a durable evidence root}"

python3 tests/hw/external_av_sync.py --capture \
  --video-device /dev/v4l/by-id/usb-EXACT_ADAPTER-video-index0 \
  --audio-device hw:CARD=EXACT_CARD_ID,DEV=0 \
  --input-format mjpeg --video-size 1280x720 --framerate 60 \
  --duration 36 \
  --fixture-manifest build/external-av-fixtures/external_av_24000_1001_640x480.mp4.manifest.json \
  --adapter-offset-file "$EVIDENCE_ROOT/adapter-offset.json" \
  --out-dir "$EVIDENCE_ROOT/run-24000_1001"
```

Before opening V4L2, the harness scans device ownership and refuses if another
process has it open. It checks again after format probing to close the obvious
preview race.

The report independently gates marker offsets in the start, middle, and end
thirds. Endpoint slope is diagnostic only: equal start/end values cannot hide a
middle excursion. Median values are diagnostic, not sufficient for PASS. The
default hard gates require:

- at least three paired markers per third;
- every corrected marker within ±42 ms;
- no adjacent corrected-offset step over 42 ms;
- at least 95% pairing coverage between detected video/audio markers;
- median marker-period error within 25 ms; and
- every individual marker interval within 75 ms of the fixture period.

Thus a missed marker, compensating short/long intervals, or one outlier hidden
by a three-marker median fails closed.

All numeric CLI, calibration, manifest, timestamp, rate, duration, and threshold
values must be finite. Durations, rates, and thresholds must be positive;
pairing coverage must be in `(0, 1]`. The manifest period must exactly match its
declared required source rate.

## Persistent evidence

The output directory is never overwritten and contains:

- `capture.mkv` — lossless video and PCM audio;
- `ffmpeg.stderr.log`, `ffprobe.json`, and `v4l2_formats.txt`;
- device `inventory.json`, `binding.json`, and `ownership.json`;
- copied fixture/calibration JSON;
- every detected event and pair in `markers.json`;
- `report.json` with capture SHA-256 and thresholds.

## Offline parser and self-tests

```bash
python3 tests/hw/external_av_sync.py --self-test

python3 tests/hw/external_av_sync.py --analyze path/to/capture.mkv \
  --out-dir path/to/new-analysis-dir \
  --fixture-manifest path/to/fixture.mp4.manifest.json \
  --adapter-offset-file path/to/adapter-offset.json
```

Exit codes:

| rc | Meaning |
|---:|---|
| 0 | PASS |
| 1 | measured FAIL, including insufficient markers |
| 2 | invalid invocation/input |
| 4 | BLOCKED prerequisite, including missing audio or owned V4L2 |
