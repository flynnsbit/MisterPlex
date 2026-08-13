# MiSTerPlex PMS test videos

This directory mirrors the 143 MiSTerPlex test videos used in the local Plex
Media Server lab. The collection is 8,563,774,346 bytes (7.98 GiB) and is
stored with Git LFS.

`manifest.json` records each filename, SHA-256 digest, byte size, duration,
video and audio stream details, and provenance.

## Download

Install Git LFS before cloning:

```bash
git lfs install
git clone --branch feat/hdmi-preview-app \
  https://github.com/flynnsbit/MisterPlex.git
```

For an existing clone that contains only LFS pointer files:

```bash
git lfs pull --include="lab/test-videos/*.mp4"
```

To add the collection to a Plex Movies library, copy the MP4 files into that
library and scan it from Plex:

```bash
cp lab/test-videos/*.mp4 /path/to/plex/media/movies/
```

## Provenance and attribution

Seventy-five videos are project-authored synthetic test fixtures. Sixty-eight
videos use modified footage from **Big Buck Bunny**:

- **Work:** Big Buck Bunny
- **Creator:** Blender Foundation
- **Source:** <https://archive.org/details/BigBuckBunny_124>
- **License:** [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/)
- **Changes:** Cropped, scaled, looped, re-encoded, and combined with
  MiSTerPlex timing, geometry, color, cadence, bitrate, and audio test overlays.

The affected families are `AdvReal`, `B6 RealGlass`, `DecLoad`, `DP-Control`,
`PromoScoreable`, `Real BBB`, `ResKnee`, and `S5 RealGlass`. No Star Trek or
other commercial video footage is included.
