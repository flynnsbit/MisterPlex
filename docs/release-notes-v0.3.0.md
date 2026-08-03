# MiSTerPlex v0.3.0 release notes (draft)

v0.3.0 is a self-contained release candidate for general MiSTer users: the package includes the
`Plex.rbf` FPGA core, the `misterplexd` ARM daemon, a static ARM `ffmpeg`, install docs, checksums,
and FFmpeg license/source notices.

## Release core identity

The v0.3.0 package must ship the Phase A playback-controls core validated on hardware:

```text
MD5  41adb98c7a630b541091c22ce291be68  cores/Plex.rbf
```

`make package` refuses to include any `Plex.rbf` with a different MD5, so a stale local Quartus
output cannot silently become the release core.

## Highlights

- **Local playback controls:** Space / Esc / Right / Left and mapped gamepad buttons now drive
  play/pause, stop, skip forward, and skip back through the FPGA input mailbox. This works even
  though MiSTer's `Main` owns the input devices.
- **On-screen playback overlay:** local commands show state, progress, and skip feedback on screen.
- **Casting app sync:** local transport changes are reflected back to the originating Plex app.
- **PMS timeline reporting:** MiSTerPlex now reports progress to Plex Media Server `/:/timeline`,
  so resume position and watched state persist on the server.
- **F12 Load menu fix:** the core now uses MiSTer's three-character extension field correctly
  (`F1,raw`, `F2,raw`, `F3,264`), fixing garbled OSD Load lines.
- **Output resolution sweep:** HDMI output modes from 640×480 through 2048×1536 were tested for
  120 seconds each. 720p and 1080p output signals, including 1920×1080@60 and @50, stayed locked
  with unchanged drop/drift behavior and unchanged ARM CPU load.
- **Privacy cleanup:** release inputs are guarded against private Plex server addresses and literal
  Plex token leaks, including generated package artifacts.

## Important resolution note

The output sweep proves that higher **output signal** modes are supported. It does **not** mean
MiSTerPlex decodes 1080p video today. Current decoded content remains **320×240** and is scaled by
MiSTer's video path.

## Known limitations

- Native/content resolution is still **320×240** by default.
- Higher native resolution is in progress and depends on SDRAM frame-store work plus enough ARM CPU
  headroom for the decode/transcode path; SDRAM frame-store work is **not** included in v0.3.0.
- FPGA-side full H.264 reconstruction remains under development; the current product path still uses
  the ARM daemon and FFmpeg for decode/transcode.
- `MATCH_SOURCE_HZ` logs/cadences to source FPS, but true runtime modeline switching is not finished.
- On-device browse/menu scripts need a `PLEX_TOKEN`; casting from a Plex app usually supplies a
  transient token automatically.

## Upgrade notes

Install from the v0.3.0 tarball rather than mixing old files. Copy `bin/`, `scripts/`, `docs/`,
`licenses/`, and `cores/Plex.rbf` from the extracted package, then copy
`conf/misterplex.conf.example` to `/media/fat/misterplex/misterplex.conf` and set your own
`PLEX_BASE=http://YOUR-PLEX-SERVER:32400`.

## Lab pair (do not split)

Core MD5 `41adb98c7a630b541091c22ce291be68` and daemon built at tag **v0.3.0**
(`cacd8717`, binary MD5 `06c5735a2f85114688f0ff2ac36e4fd4`) must ship together.
**320×240 bank1 = `0x30040000`; 480p bank1 = `0x30080000`.** A mixed deploy
recreates background/bank corruption. Full 2am card: [`docs/release.md`](release.md)
§ *Lab stable pair (v0.3.0)*.
