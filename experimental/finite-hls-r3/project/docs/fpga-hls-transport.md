# Finite FPGA Plex transport

FPGA profiles request `universal/start.m3u8` and `protocol=hls`, including the
matching decision request. Software profiles retain `start.mp4`/HTTP.
The selected FPGA XML profile remains authoritative: no client ladder override
is sent, and the token stays in headers. Each of the eight FPGA profiles adds
an HLS target with exactly its existing HTTP encoding flags and constraints.
The HTTP targets remain available for the previous companion.

## Completion contract

Libav owns HLS parsing, variant selection, URI resolution, reloading, MPEG-TS
demuxing and timestamps. The companion's public `io_open`/`io_close2` wrapper
only forwards bytes and observes bounded manifest/completion metadata. It does
not implement a playlist downloader or segment scheduler.

The supported input is one finite muxed MPEG-TS media playlist, optionally
reached through a master, or an append-only event playlist that becomes finite.
Playback starts at the beginning, not libav's default near-live-tail position.
Natural EOF requires:

* An advertised, nonempty `EXT-X-ENDLIST`, a positive target duration and
  complete `EXTINF`/URI pairs.
* Successful underlying resource reads with a verifiable length. Missing
  resources, HTTP errors and short responses are fatal, not skipped.
* Original video timestamp extent matching the advertised segment durations.
  Decimal and segment-boundary clock rounding is bounded below half a frame;
  no timestamps, frames, delay or padding are generated. A missing final frame
  cannot become successful natural EOF merely because HTTP completed.

**Compatibility limits are intentional and require PMS qualification.**
Unknown-length/chunked resources are rejected: supported libav versions can
report ordinary EOF for an interrupted chunked response, and the public AVIO
interface does not expose sufficient framing state to prove completion.
Redirects and cross-origin child requests are rejected rather than forwarding
Plex session/token headers elsewhere. Direct HTTP must stay on the initially
selected host/port; local-file HLS is also supported. HTTPS, byteranges,
multiple media renditions, discontinuities, skipped/gap segments and changing
media-sequence windows are not this FPGA transport contract. These cases fail
closed, not through a progressive/software fallback.

Libav HTTP persistence and parallel HTTP input are disabled so nested reads
cannot bypass the public I/O guard. The existing five-second input deadlines
and cancellation callbacks remain in force; no EOF reconnect loop is added.
The wrapper adds at most eight 32-KiB AVIO buffers, retains no media bodies,
and bounds a manifest to 1 MiB and a metadata line/identity to 4095 bytes.
The existing AU/VCL limits, CAVLC/profile/signed-16 feature checks, PCM/video
queue bounds, audio decoder and native DAR/scaler path are unchanged.
Nested decoder probing is restricted to the existing audio decoder family;
FPGA video is still parser/bitstream-filter only.

PMS seeks still start a new offset transcode/session; the decision request
mirrors that offset. Native HLS seeks at segment boundaries preserve original
PTS. Existing direct-seek preroll rejection remains in force for unaligned
targets; this change does not discard pictures to conceal required preroll.

Diagnostics keep underlying `io_error` and the last underlying `io_eof`
observation separate from `finite_hls_error`, `finite_hls_error_kind` and
`finite_hls_verified`. For HLS, `io_bytes_read` counts forwarded media-resource
bytes, not the root manifest. Clean I/O alone is not finite-source completion.
All new error kinds are fixed strings; URL-bearing libav logging stays disabled.
Even verified HLS only proves the advertised representation, not that PMS
advertised every original library frame.

## Static ARM dependency

The reproducible FFmpeg 8.1.2 recipe enables the existing `hls` demuxer in
addition to the previous set. FFmpeg selects its AAC/AC3/EAC3 demuxers,
AC3 parser and ADTS-header support; MOV/MPEG-TS support was already enabled.
No new video codec, cryptographic/HTTPS protocol, shared library, iconv/module
loader or software scaling capability is enabled. The legacy H.264 decoder
remains compiled for the non-FPGA software path; the FPGA path never opens it.

The new defaults are:

* Build: `build/deps/ffmpeg-8.1.2-static-safe-hls-build`
* Install: `build/deps/ffmpeg-arm-static-safe-hls`

Existing directories/archives are never overwritten. The static capability
guard now requires `ff_hls_demuxer`; the old HTTP-only archive set is not a
valid dependency for an HLS-qualified companion. A later authorized ARM build
must retain the exact source/config/toolchain provenance, pass the archive
guard, link with `MPX_HAVE_LIBAV`, and retain the previous pair for rollback.
Host tests or a headers-only compatibility check do not validate ARM linking.

## Validation and qualification

The existing host runner includes generated finite HLS, negative transport/
manifest/last-segment cases, rational PTS and byte-exact AU/stereo PCM/DAR
comparison, decoder-open interposition, cancellation/reopen, pressure, pause,
seek and profile regressions. It only uses generated media and a loopback
HTTP server.

```sh
bash tests/unit/test_fpga_compressed_runtime.sh
MPX_COMPRESSED_TEST_SCOPE=hls bash tests/unit/test_fpga_compressed_runtime.sh
MPX_COMPRESSED_TEST_SCOPE=hls MPX_HLS_SANITIZE=1 \
  bash tests/unit/test_fpga_compressed_runtime.sh
```

`MPX_KEEP_TEST_WORK=1` retains generated fixtures and case logs on failure.
Before deployment, independently review this source and dependency change,
verify that the actual PMS serves the finite/length/origin contract with the
matching eight XML profiles, and use a separately authorized matched ARM
build/activation. Acceptance still requires genuine LAN Plex Web cast
selection, a real library play and continuous HDMI/stereo observation through
EOF and tail. This transport does not fix the separate backend throughput,
audio-gap or tail problems; no host regression is playback acceptance.
