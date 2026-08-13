# MiSTerPlex v0.4.1

True480 and Plex Companion reliability release. This release promotes 240p and
480p as the user-facing production modes, preserves original source aspect
ratio for MiSTer's scaler, and fixes the Plex Web elapsed timer across Docker
PMS loopback and LAN origins.

## Choose a content mode

Open **F12 → Content resolution**:

| Mode | What it does | Release status |
|------|--------------|----------------|
| **240p** | Decodes to the 320×240 bank. This is the compatibility/performance mode with the most CPU and frame-time margin. MiSTer's scaler owns the final output resolution and aspect. | **Production** |
| **480p** | Recommended quality mode. Uses a true 640×480 presentation with 624×480 coded and 618×480 visible geometry. Original source aspect is handed to MiSTer's scaler for widescreen, 4:3, or custom output policy. | **Production** |
| **720p** | Exercises the 1280×720 bank and higher-resolution pipeline. On the current dual-A9 path it can run below source frame rate and audio can fall behind. | **Alpha**; not recommended for normal viewing |

240p and 480p are runtime choices in the same RBF. With `OSD_CONTROL=1`, a
change during playback re-resolves the Plex transcode and resumes near the same
position. **Display resolution → Follow content** is the normal setting;
MiSTer's native scaler can still enforce a preferred display aspect or output
mode.

## Changes since v0.4.0

- **Native source aspect:** MiSTerPlex transports the source display aspect
  rather than baking widescreen or 4:3 policy into the daemon.
- **True480 presentation:** 640×480 output, 624×480 coded geometry, 618×480
  visible picture, and centered pillars.
- **Centered idle chevron:** the idle mark is centered on the visible raster.
- **24p playback:** the 480p ladder is capped to the measured dual-A9 realtime
  budget; tested 23.976 fps material tracks source cadence.
- **Plex Web timeline:** fragmented Companion HTTP, native subscriptions,
  callback delivery, command IDs, real play-queue item identity, and the
  required player response identity are hardened.
- **Docker PMS origin fix:** the packaged `examples/plex-cors-proxy/` sidecar
  preserves host-network cast discovery while making
  `X-Plex-Client-Identifier` browser-readable from both loopback and LAN Plex
  Web URLs.
- **Display fallback:** an unsupported selected display mailbox retries with
  content geometry instead of abandoning playback.

## Plex Web stuck at `0:00`

If video plays but the elapsed timer does not move, compare the Plex Web page
origin with the timeline poll origin. A page loaded from the PMS LAN address
can proxy through `127.0.0.1`; PMS may then expose only `Location, Date`, hiding
the player identity from browser JavaScript.

The immediate same-host workaround is
`http://127.0.0.1:32400/web`. The permanent Docker host-network solution is in
`examples/plex-cors-proxy/` and is also documented in the top-level README.

## Release artifacts

| Artifact | Identity |
|----------|----------|
| `cores/Plex.rbf` MD5 | `07f54d9f8f0eda2fe75d9cc314f6de54` |
| `cores/Plex.rbf` SHA-256 | `9d4977936d1b1a3420a3e97df976058573e70a34fd0c8917f2d785a5fe0d07cf` |
| `bin/misterplexd` SHA-256 | `646645ca2fb276c8266ee360a9df67b1dfefe91f67241e71f12b9ebfb880f6c8` |

The RBF closed with `+0.401 ns` worst setup slack and `+0.032 ns` worst hold
slack. Build the package with:

```bash
VERSION=v0.4.1 make package
```

Always install the daemon and RBF from the same v0.4.1 tarball.
