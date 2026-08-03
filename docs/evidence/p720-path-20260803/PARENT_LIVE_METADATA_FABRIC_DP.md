# Parent live check — metadata fabric Direct Play (no decision)

Branch tip at authoring: pin a detached worktree; quote `git rev-parse --abbrev-ref HEAD` + sha.

## What landed (host, no device)

1. `evaluateFabricDirectPlayMeta` — pure predicate (h264, baseline/CB, level≤30,
   W×H≤1280×720, bitrate 1…6000 kbps, B-frames, chroma when present).
2. `parseFabricDirectPlayMetaFromPlexXml` — Media/Stream fields.
3. `resolvePlayTarget`: if regime is DirectPlaySd **and** meta predicate OK →
   open Part URL + token **without** `/universal/decision` or `start.mp4`.
   Sets `metadataFabricDirectPlay=true`, `decisionAttr=metadata_fabric_direct`.
4. Fixed `attr()` so `<Media` does not match `<MediaContainer`.
5. Unit: `test_h264_fabric_stream_gate` + `test_resolve` NEGs (High, L>30, B,
   1080p, bitrate) — not ratingKey-hardcoded.

## Parent live commands (YOU run; no creds in repo)

Use env only: `PLEX_BASE`, `PLEX_TOKEN`, `PLEX_KEY` (e.g. `/library/metadata/7`).

### A) Metadata-only Part path (expected: HTTP 200, CB/L30/720)

```bash
# 1) Fetch library metadata (same shape daemon parses)
curl -sS -g -k -L --http1.1 \
  -H 'Accept: application/xml' \
  -H 'X-Plex-Client-Identifier: misterplex' \
  -H 'X-Plex-Product: Plex Web' \
  -H 'X-Plex-Version: 4.125.0' \
  -H 'X-Plex-Platform: Chrome' \
  -H 'X-Plex-Device: Linux' \
  -H 'X-Plex-Device-Name: Chrome' \
  -H 'X-Plex-Client-Profile-Name: MiSTerPlex' \
  "${PLEX_BASE}${PLEX_KEY}?X-Plex-Token=${PLEX_TOKEN}" \
  | tee /tmp/pms-meta-rk.xml | head -c 2000
echo
# Expect: Media width/height 1280/720, videoProfile constrained baseline,
# Stream level=30, Part key=...

# 2) Extract Part key and GET bytes (daemon path when metadata_fabric_dp ok)
PART_KEY=$(python3 - <<'PY'
import re,sys
xml=open("/tmp/pms-meta-rk.xml").read()
m=re.search(r'<Part[^>]*\bkey="([^"]+)"', xml)
print(m.group(1) if m else "")
PY
)
echo "PART_KEY=$PART_KEY"
curl -sS -g -k -L --http1.1 -o /tmp/pms-part-rk.mp4 -w "http=%{http_code} bytes=%{size_download}\n" \
  "${PLEX_BASE}${PART_KEY}?X-Plex-Token=${PLEX_TOKEN}"
echo "part curl true rc=$?"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,profile,level,width,height,has_b_frames,pix_fmt,r_frame_rate,bit_rate \
  -of default=nw=1 /tmp/pms-part-rk.mp4
echo "ffprobe true rc=$?"
# Expect: h264, Constrained Baseline, level=30, 1280x720, has_b_frames=0, yuv420p
```

### B) Confirm decision still broken (regression context; not required for DP)

```bash
# Optional: show decision still 400 so metadata path is the only 720 route today
SID=mplex-parent-live
curl -sS -g -k -o /tmp/pms-decision.body -w "http=%{http_code} bytes=%{size_download}\n" \
  -H 'Accept: application/xml' \
  -H 'X-Plex-Client-Identifier: misterplex' \
  -H 'X-Plex-Product: Plex Web' \
  -H 'X-Plex-Version: 4.125.0' \
  -H 'X-Plex-Platform: Chrome' \
  -H 'X-Plex-Device: Linux' \
  -H 'X-Plex-Device-Name: Chrome' \
  -H 'X-Plex-Client-Profile-Name: MiSTerPlex' \
  -H "X-Plex-Session-Identifier: ${SID}" \
  "${PLEX_BASE}/video/:/transcode/universal/decision?hasMDE=1&path=$(python3 -c 'import urllib.parse,os; print(urllib.parse.quote(os.environ["PLEX_KEY"], safe=""))')&mediaIndex=0&partIndex=0&protocol=http&fastSeek=1&directPlay=1&directStream=1&session=${SID}&videoQuality=100&videoResolution=1280x720&maxVideoBitrate=20000&videoCodec=h264&audioCodec=aac&videoProfile=baseline&videoLevel=30&X-Plex-Token=${PLEX_TOKEN}"
echo "decision true rc=$?"
head -c 200 /tmp/pms-decision.body; echo
```

### C) Unit (path worktree)

```bash
cd /path/to/MisterPlex-wt-path
make "$(pwd)/build/test_resolve" "$(pwd)/build/test_h264_fabric_stream_gate"
./build/test_resolve; echo "true rc=$?"
./build/test_h264_fabric_stream_gate; echo "true rc=$?"
```

## Integration note for parent / w-mem

Metadata DP delivers **1280×720 I420** after host decode/copy path today;
fabric bitstream path still needs w-mem bank stride ≥ 1 382 400 and
bitstream AU gate. `metadataFabricDirectPlay` ≠ glass mode report.

## ON_MAIN status (code only; parent merges)

| unit | ON_MAIN | notes |
|------|---------|--------|
| evaluateFabricDirectPlayMeta | NO until merge | host header |
| parseFabricDirectPlayMetaFromPlexXml | NO until merge | resolve |
| resolve metadata Part short-circuit | NO until merge | skips decision |
| 720p profile / ladder ceiling | branch earlier | still needed for non-fabric assets |
| RTL present modules | main L4 default-off | not this lane |
