#!/usr/bin/env python3
"""Minimal PMS stub for local cast E2E (no user PMS required).

Serves just enough of the Plex HTTP surface that misterplexd STREAM=0 resolve
can land a real media URL:

  GET /library/metadata/<id>     → MediaContainer + Part
  GET /video/:/transcode/universal/decision → MediaContainer (decision OK)
  GET /video/:/transcode/universal/start.mp4 → the media file (bytes)
  GET /library/parts/1/file.mp4  → same file (direct-Part fallback)

Also answers /identity for casual probes. Documented for reuse by other lanes
(e.g. w-hybrid-arm); keep self-contained — only stdlib + one media path.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def _xml_meta(duration_ms: int, part_path: str, frame_rate: str = "24") -> bytes:
    # Shape matches what plex_resolve.cpp scrapes (Video/Media/Part/Stream attrs).
    body = f"""<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer size="1">
  <Video ratingKey="1" key="/library/metadata/1" title="StubCastClip"
         duration="{duration_ms}" viewOffset="0">
    <Media id="1" duration="{duration_ms}" bitrate="800" width="320" height="240"
           videoCodec="h264" audioCodec="aac" videoFrameRate="{frame_rate}"
           videoResolution="320x240" container="mp4">
      <Part id="1" key="{part_path}" duration="{duration_ms}" file="{part_path}"
            container="mp4" size="1">
        <Stream id="1" streamType="1" type="video" codec="h264" width="320" height="240"
                frameRate="{frame_rate}" bitrate="700"/>
        <Stream id="2" streamType="2" type="audio" codec="aac" channels="2"
                samplingRate="48000"/>
      </Part>
    </Media>
  </Video>
</MediaContainer>
"""
    return body.encode("utf-8")


def _xml_decision() -> bytes:
    return b"""<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer size="1" transcodeDecisionCode="1000">
  <Video title="StubCastClip">
    <Media videoCodec="h264" audioCodec="aac"/>
  </Video>
</MediaContainer>
"""


class Handler(BaseHTTPRequestHandler):
    media_path: Path
    media_bytes: bytes
    duration_ms: int
    frame_rate: str

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("stub_pms: %s\n" % (fmt % args))

    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.send_header("Access-Control-Allow-Origin", "*")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve_media(self) -> None:
        data = self.media_bytes
        total = len(data)
        rng = self.headers.get("Range") or self.headers.get("range")
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng.strip())
            if m:
                start_s, end_s = m.group(1), m.group(2)
                start = int(start_s) if start_s else 0
                end = int(end_s) if end_s else total - 1
                end = min(end, total - 1)
                if start > end or start >= total:
                    self.send_error(416, "Range Not Satisfiable")
                    return
                chunk = data[start : end + 1]
                self.send_response(206)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(len(chunk)))
                self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Connection", "close")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(chunk)
                return
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(total))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802
        u = urlparse(self.path)
        path = u.path
        qs = parse_qs(u.query)

        if path in ("/identity", "/"):
            body = b'<?xml version="1.0"?><MediaContainer machineIdentifier="stub-pms-cast"/>'
            self._send(200, body, "application/xml")
            return

        if path.startswith("/library/metadata/"):
            self._send(
                200,
                _xml_meta(self.duration_ms, "/library/parts/1/file.mp4", self.frame_rate),
                "application/xml",
            )
            return

        if path.startswith("/video/:/transcode/universal/decision"):
            # Non-empty MediaContainer / transcodeDecisionCode → ensureUniversalDecision OK.
            self._send(200, _xml_decision(), "application/xml")
            return

        if path.startswith("/video/:/transcode/universal/start") or path.startswith(
            "/library/parts/"
        ):
            self._serve_media()
            return

        # Timeline pings are best-effort; 200 empty keeps daemon logs clean.
        if path.startswith("/:/timeline") or path == "/:/timeline":
            self._send(200, b"", "text/plain")
            return

        # Friendly 404 body (must NOT look like MediaContainer — resolve treats that as found).
        self._send(404, b"stub_pms: not found\n", "text/plain")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--media", required=True, type=Path, help="mp4/h264 file to serve")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=32499)
    ap.add_argument("--duration-ms", type=int, default=0, help="0 = probe from filename only")
    ap.add_argument("--frame-rate", default="24")
    ap.add_argument("--write-port-file", type=Path, default=None)
    args = ap.parse_args()

    media = args.media.resolve()
    if not media.is_file():
        print(f"stub_pms: media not found: {media}", file=sys.stderr)
        return 2
    data = media.read_bytes()
    if not data:
        print("stub_pms: media empty", file=sys.stderr)
        return 2

    dur = args.duration_ms
    if dur <= 0:
        # Default for assets/avsync/sync_trekmatch_320x240_24_blip.mp4 (30s).
        dur = 30000

    Handler.media_path = media
    Handler.media_bytes = data
    Handler.duration_ms = dur
    Handler.frame_rate = args.frame_rate

    # SO_REUSEADDR so e2e can hand off a just-probed port without EADDRINUSE.
    ThreadingHTTPServer.allow_reuse_address = True
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    host, port = httpd.server_address[:2]
    if args.write_port_file:
        args.write_port_file.parent.mkdir(parents=True, exist_ok=True)
        args.write_port_file.write_text(f"{port}\n")
    print(f"stub_pms: listening http://{host}:{port} media={media} bytes={len(data)}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
