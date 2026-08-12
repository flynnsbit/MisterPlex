# Deterministic external A/V marker fixture

`generate_av_marker.py` creates 640×480 media for measuring the complete
MiSTer → HDMI → USB capture path. Each marker is:

- a two-source-frame full-white flash from a black frame; and
- a coincident 12 ms, 2 kHz stereo click at 48 kHz.

The manifest is the specification. It records every video frame index and audio
sample index, the exact rational source rate, and the marker period.

## Required rates

| Rate | Frames/marker | Samples/marker | Period |
|---|---:|---:|---:|
| `24000/1001` | 24 | 48048 | 1001 ms |
| `24/1` | 24 | 48000 | 1000 ms |
| `25/1` | 25 | 48000 | 1000 ms |
| `30000/1001` | 30 | 48048 | 1001 ms |
| `30/1` | 30 | 48000 | 1000 ms |

Fractional-rate markers intentionally occur every 1001 ms. This keeps both the
flash and click on exact frame/sample boundaries instead of pretending that
23.976 or 29.97 has an integer number of frames per second.

## Generate Plex fixtures

```bash
python3 tests/fixtures/external_av/generate_av_marker.py \
  --all-rates --out-dir build/external-av-fixtures --codec plex
```

Each MP4 has a sibling `*.manifest.json`. Keep the matching manifest when
importing a fixture into Plex.

For local parser tests, use lossless FFV1 + PCM:

```bash
python3 tests/fixtures/external_av/generate_av_marker.py \
  --output build/external-av-fixture.mkv --rate 24000/1001 --codec lossless
```

`--synthetic-offset-profile-ms START,MIDDLE,END` is fault injection for parser
self-tests. Product fixtures must use the default `0,0,0`.

The generator creates scratch audio beside the requested output and removes it
after muxing. It does not use a system temporary directory.
