#!/usr/bin/env python3
"""Generated finite HLS fixtures through the real compressed libav reader."""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock, Thread
from urllib.parse import urlsplit
import json
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET


EXECUTABLE = Path(sys.argv.pop(1)).resolve()
WORK = Path(sys.argv.pop(1)).resolve() / "hls"
ROOT = Path(__file__).resolve().parents[2]


class FiniteHlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        WORK.mkdir()
        cls.fixtures = {}
        cls.requests = Counter()
        cls.auth_failures = 0
        cls.lock = Lock()
        cls.serial = 0
        for label, rate, duration in (("24", "24", "2"), ("23976", "24000/1001", "2.002")):
            directory = WORK / label
            directory.mkdir()
            command = [
                "ffmpeg", "-v", "error", "-nostdin", "-filter_threads", "1",
                "-f", "lavfi", "-i", f"testsrc2=size=320x240:rate={rate}:duration={duration}",
                "-f", "lavfi", "-i", f"sine=frequency=880:sample_rate=48000:duration={duration}",
                "-frames:v", "48", "-vf", "setsar=4/3", "-c:v", "libx264",
                "-profile:v", "baseline", "-level:v", "3.0", "-threads", "1",
                "-x264-params", "cabac=0:bframes=0:ref=1:weightp=0:partitions=none:"
                "qp=28:scenecut=0:slices=1:threads=1:keyint=1:no-deblock=1",
                "-colorspace", "smpte170m", "-color_primaries", "smpte170m",
                "-color_trc", "smpte170m", "-color_range", "tv",
                "-c:a", "aac", "-ar", "48000", "-ac", "2",
                "-hls_time", "0.5", "-hls_playlist_type", "vod",
                "-hls_segment_filename", str(directory / "seg%03d.ts"),
                "-f", "hls", str(directory / "index.m3u8"),
            ]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            (directory / "generate-command.json").write_text(json.dumps(command, indent=2) + "\n")
            (directory / "generate.stderr").write_text(result.stderr)
            if result.returncode:
                raise AssertionError("local HLS fixture generation failed: " + result.stderr)
            playlist = directory / "index.m3u8"
            # The host muxer rounds the half-second target to zero; HLS requires
            # a positive integer target. Media bytes and timestamps are unmodified.
            playlist.write_text(playlist.read_text().replace(
                "#EXT-X-TARGETDURATION:0", "#EXT-X-TARGETDURATION:1"))
            segments = sorted(directory.glob("seg*.ts"))
            assert len(segments) == 4
            (directory / "reference.ts").write_bytes(b"".join(p.read_bytes() for p in segments))
            cls.fixtures[label] = directory

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def do_GET(self):
                path = urlsplit(self.path).path
                pieces = path.strip("/").split("/")
                if len(pieces) < 3 or pieces[1] not in cls.fixtures:
                    self.send_error(404)
                    return
                scenario, label, name = pieces[0], pieces[1], pieces[-1]
                with cls.lock:
                    visit = cls.requests[path]
                    cls.requests[path] += 1
                    authenticated = (
                        self.headers.get("X-Plex-Token") == "generated-test-token"
                        and self.headers.get("X-Plex-Session-Identifier") == "generated-test-session"
                    )
                    if not authenticated:
                        cls.auth_failures += 1
                if not authenticated:
                    self.send_error(401)
                    return
                directory = cls.fixtures[label]
                content_type = "video/mp2t"
                status = 200
                length_extra = 0
                chunk_short = False
                chunk_complete = False
                if name in ("index.m3u8", "start.m3u8", "start"):
                    content_type = "application/vnd.apple.mpegurl"
                    text = (directory / "index.m3u8").read_text()
                    if scenario in ("master", "master-blank", "master-comment",
                                    "master-spaced", "master-conflict",
                                    "master-missing") and name == "start.m3u8":
                        text = ('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,'
                                'CODECS="avc1.42e01e,mp4a.40.2",RESOLUTION=320x240\n'
                                'media/index.m3u8\n')
                        if scenario == "master-blank":
                            text = text.replace("\nmedia/index.m3u8\n", "\n\nmedia/index.m3u8\n")
                        elif scenario == "master-comment":
                            text = text.replace("\nmedia/index.m3u8\n",
                                                "\n# ordinary comment\nmedia/index.m3u8\n")
                        elif scenario == "master-spaced":
                            text = text.replace("\nmedia/index.m3u8\n",
                                                "\n# ordinary comment\n\nmedia/index.m3u8\n")
                        elif scenario == "master-conflict":
                            text = text.replace("\nmedia/index.m3u8\n",
                                                "\n# ordinary comment\n"
                                                "#EXT-X-MEDIA-SEQUENCE:0\n"
                                                "media/index.m3u8\n")
                        elif scenario == "master-missing":
                            text = text.replace("media/index.m3u8\n",
                                                "# ordinary comment\n\n")
                    if scenario == "redirect" and name == "start.m3u8":
                        self.send_response(302)
                        self.send_header("Location", f"/complete/{label}/index.m3u8")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    if scenario in ("no-end", "event", "shift", "regress"):
                        lines = text.replace("#EXT-X-PLAYLIST-TYPE:VOD",
                                             "#EXT-X-PLAYLIST-TYPE:EVENT").splitlines()
                        header = lines[:lines.index(next(x for x in lines if x.startswith("#EXTINF:")))]
                        pairs = [lines[i:i + 2] for i, line in enumerate(lines)
                                 if line.startswith("#EXTINF:")]
                        count = 4
                        terminal = False
                        if scenario == "event":
                            count, terminal = (2, False) if not visit else (4, True)
                        elif scenario == "shift":
                            count = 2 if not visit else 4
                            if visit:
                                header = [x.replace("#EXT-X-MEDIA-SEQUENCE:0",
                                                    "#EXT-X-MEDIA-SEQUENCE:1") for x in header]
                        elif scenario == "regress":
                            count, terminal = (3, False) if not visit else (2, True)
                        text = "\n".join(header + [x for pair in pairs[:count] for x in pair] +
                                         (["#EXT-X-ENDLIST"] if terminal else [])) + "\n"
                    if scenario == "gap":
                        text = text.replace("seg001.ts", "#EXT-X-GAP\nseg001.ts")
                    if scenario == "segment-range":
                        text = text.replace("seg001.ts",
                                            "#EXT-X-BYTERANGE:188@0\nseg001.ts")
                    if scenario == "map":
                        lines = text.splitlines()
                        first_extinf = next(i for i, line in enumerate(lines)
                                            if line.startswith("#EXTINF:"))
                        lines.insert(first_extinf, '#EXT-X-MAP:URI="init.ts"')
                        text = "\n".join(lines) + "\n"
                    if scenario == "map-range":
                        lines = text.splitlines()
                        first_extinf = next(i for i, line in enumerate(lines)
                                            if line.startswith("#EXTINF:"))
                        lines.insert(first_extinf,
                                     '#EXT-X-MAP:URI="init.ts",BYTERANGE="188@0"')
                        text = "\n".join(lines) + "\n"
                    if scenario == "dangling":
                        text = text.replace("#EXT-X-ENDLIST", "#EXTINF:1.0,\n#EXT-X-ENDLIST")
                    if scenario == "orphan-before":
                        lines = text.splitlines()
                        first_extinf = next(i for i, line in enumerate(lines)
                                            if line.startswith("#EXTINF:"))
                        lines.insert(first_extinf, "orphan.ts")
                        text = "\n".join(lines) + "\n"
                    if scenario == "after-end":
                        text += "#EXTINF:1.0,\nseg003.ts\n"
                    if scenario == "orphan-after-end":
                        text += "tail.ts\n"
                    if scenario == "bad-target":
                        text = text.replace("#EXT-X-TARGETDURATION:1",
                                            "#EXT-X-TARGETDURATION:0")
                    if scenario == "discontinuity-sequence":
                        text = text.replace("#EXT-X-MEDIA-SEQUENCE:0",
                            "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-DISCONTINUITY-SEQUENCE:5")
                    if scenario == "cross-origin":
                        text = text.replace("seg001.ts",
                            f"http://localhost:{cls.server.server_port}/complete/{label}/seg001.ts")
                    body = text.encode()
                    if scenario == "progressive":
                        body = (directory / "reference.ts").read_bytes()
                elif name.startswith("seg") and (directory / name).is_file():
                    body = (directory / name).read_bytes()
                    target = "seg003.ts" if scenario.startswith("last-") else "seg001.ts"
                    if name == target:
                        if scenario == "missing":
                            status = 404
                            body = b""
                        elif scenario == "server-error":
                            status = 500
                            body = b""
                        elif scenario == "short":
                            length_extra = len(body) - len(body) // 2
                            body = body[:len(body) // 2]
                        elif scenario in ("chunk-short", "last-chunk-short"):
                            chunk_short = True
                        elif scenario == "chunked":
                            chunk_complete = True
                        elif scenario == "empty":
                            body = b""
                        elif scenario in ("garbage", "last-garbage"):
                            body = b"not a transport stream\n" * 30
                        elif scenario in ("last-incomplete", "last-one-frame"):
                            starts = [i for i in range(0, len(body), 188)
                                      if body[i + 1] & 0x40 and
                                      ((body[i + 1] & 31) << 8 | body[i + 2]) == 256]
                            assert len(starts) == 12
                            body = body[:starts[11 if scenario == "last-one-frame" else 6]]
                elif name == "init.ts":
                    body = (directory / "seg000.ts").read_bytes()[:188]
                else:
                    self.send_error(404)
                    return
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Connection", "close")
                if chunk_short or chunk_complete:
                    self.send_header("Transfer-Encoding", "chunked")
                    body = (f"{len(body):x}\r\n".encode() +
                            (body[:len(body) // 2] if chunk_short else body + b"\r\n0\r\n\r\n"))
                else:
                    self.send_header("Content-Length", str(len(body) + length_extra))
                self.end_headers()
                self.close_connection = True
                try:
                    self.wfile.write(body)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = Thread(target=cls.server.serve_forever)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()
        (WORK / "server-summary.json").write_text(json.dumps({
            "requests": dict(cls.requests), "auth_failures": cls.auth_failures,
            "thread_joined": not cls.thread.is_alive(),
        }, indent=2) + "\n")

    def run_case(self, scenario, mode="complete", rate="24", entry="index.m3u8"):
        type(self).serial += 1
        output = WORK / f"{self.serial:03d}-{scenario}-{mode}-{rate}"
        source = (str(self.fixtures[rate] / "index.m3u8") if scenario == "file"
                  else f"{self.base}/{scenario}/{rate}/{entry}")
        command = [
            str(EXECUTABLE), mode, source,
            str(self.fixtures[rate] / "reference.ts"),
            "24" if rate == "24" else "24000", "1" if rate == "24" else "1001",
            f"{self.base}/complete/{rate}/index.m3u8",
        ]
        output.with_suffix(".command.json").write_text(json.dumps(command, indent=2) + "\n")
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        output.with_suffix(".stdout").write_text(result.stdout)
        output.with_suffix(".stderr").write_text(result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.auth_failures, 0, "a nested HLS request lost session/auth headers")
        return json.loads(result.stdout)

    def run_unit_case(self, scenario):
        command = [
            str(EXECUTABLE), "unit", scenario,
            str(self.fixtures["24"] / "reference.ts"),
            "24", "1", str(self.fixtures["24"] / "reference.ts"),
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_complete_original_timestamps_audio_and_dar(self):
        for rate in ("24", "23976"):
            with self.subTest(rate=rate):
                self.run_case("complete", rate=rate)

    def test_master_relative_paths(self):
        self.run_case("master", entry="start.m3u8")

    def test_master_variant_can_follow_blank_and_comment_lines(self):
        for scenario in ("master-blank", "master-comment", "master-spaced"):
            with self.subTest(scenario=scenario):
                self.run_case(scenario, entry="start.m3u8")

    def test_master_variant_still_requires_uri_before_conflicting_tags_or_eof(self):
        for scenario in ("master-conflict", "master-missing"):
            with self.subTest(scenario=scenario):
                before = self.requests[f"/{scenario}/24/media/index.m3u8"]
                self.run_case(scenario, mode="error", entry="start.m3u8")
                self.assertEqual(self.requests[f"/{scenario}/24/media/index.m3u8"], before)

    def test_redirects_and_cross_origin_cannot_forward_tokens(self):
        before = self.requests["/complete/24/index.m3u8"]
        self.run_case("redirect", mode="error", entry="start.m3u8")
        self.assertEqual(self.requests["/complete/24/index.m3u8"], before)
        before = self.requests["/complete/24/seg001.ts"]
        self.run_case("cross-origin", mode="error")
        self.assertEqual(self.requests["/complete/24/seg001.ts"], before)

    def test_local_file_hls(self):
        self.run_case("file")

    def test_constant_discontinuity_sequence_is_not_a_clock_jump(self):
        self.run_case("discontinuity-sequence")

    def test_explicit_extensionless_hls(self):
        self.run_case("extensionless", mode="explicit", entry="start")
        self.run_case("unguarded", mode="error", entry="start")
        self.assertEqual(self.requests["/unguarded/24/seg000.ts"], 0)

    def test_event_to_advertised_endlist(self):
        self.run_case("event")

    def test_orphan_or_trailing_media_uris_are_rejected(self):
        for scenario in ("orphan-before", "orphan-after-end"):
            with self.subTest(scenario=scenario):
                self.run_case(scenario, mode="error")

    def test_unsupported_map_and_byterange_forms_are_rejected(self):
        for scenario in ("segment-range", "map", "map-range"):
            with self.subTest(scenario=scenario):
                initial_segment = self.requests[f"/{scenario}/24/seg001.ts"]
                initial_init = self.requests[f"/{scenario}/24/init.ts"]
                self.run_case(scenario, mode="error")
                self.assertEqual(self.requests[f"/{scenario}/24/seg001.ts"], initial_segment)
                self.assertEqual(self.requests[f"/{scenario}/24/init.ts"], initial_init)

    def test_transport_errors_are_not_eof_or_skipped(self):
        for scenario in ("missing", "server-error", "short", "chunk-short", "chunked",
                         "empty", "garbage"):
            with self.subTest(scenario=scenario):
                initial_bad = self.requests[f"/{scenario}/24/seg001.ts"]
                initial_next = self.requests[f"/{scenario}/24/seg002.ts"]
                self.run_case(scenario, mode="error")
                self.assertEqual(self.requests[f"/{scenario}/24/seg001.ts"] - initial_bad, 1)
                if scenario != "garbage":
                    self.assertEqual(self.requests[f"/{scenario}/24/seg002.ts"] - initial_next, 0)

    def test_last_segment_cannot_hide_truncation_at_eof(self):
        for scenario in ("last-chunk-short", "last-garbage", "last-incomplete", "last-one-frame"):
            with self.subTest(scenario=scenario):
                result = self.run_case(scenario, mode="error")
                self.assertFalse(result["finite_hls_verified"])
                if scenario in ("last-incomplete", "last-one-frame"):
                    self.assertEqual(result["io_error"], 0)
                    self.assertTrue(result["io_eof"])
                    self.assertEqual(result["finite_hls_error_kind"], "video-extent")

    def test_unfinished_or_inconsistent_manifest(self):
        for scenario in ("no-end", "shift", "regress", "gap", "dangling", "after-end",
                         "progressive", "bad-target"):
            with self.subTest(scenario=scenario):
                self.run_case(scenario, mode="error")

    def test_error_then_reopen(self):
        self.run_case("missing", mode="reopen")

    def test_cancel_and_external_cancel_then_reopen(self):
        self.run_case("no-end", mode="cancel")
        self.run_case("no-end", mode="external-cancel")

    def test_required_close_without_eof_tracks_completion_and_abandonment(self):
        complete = self.run_unit_case("close-complete")
        self.assertTrue(complete["finite_hls_verified"])
        self.assertFalse(complete["transport_eof"])
        self.assertGreater(complete["media_bytes"], 0)

        partial = self.run_unit_case("close-partial")
        self.assertFalse(partial["finite_hls_verified"])
        self.assertEqual(partial["finite_hls_error_kind"], "resource-length")

        abandon = self.run_unit_case("close-abandon")
        self.assertEqual(abandon["finite_hls_error"], 0)
        self.assertEqual(abandon["transport_error"], 0)
        self.assertFalse(abandon["finite_hls_verified"])

    def test_pause_and_bounded_backpressure(self):
        self.run_case("complete", mode="backpressure")

    def test_seek_preserves_original_clock(self):
        self.run_case("complete", mode="seek")
        self.run_case("complete", mode="seek-reject")

    def test_profiles_are_additive_and_keep_the_same_limits(self):
        def normalized(element, root=False):
            return (element.tag,
                    sorted((key, value) for key, value in element.attrib.items()
                           if not (root and key == "protocol")),
                    [normalized(child) for child in element])
        profiles = sorted((ROOT / "assets/plex-profiles").glob("MiSTerPlex-FPGA-*.xml"))
        self.assertEqual(len(profiles), 8)
        for path in profiles:
            with self.subTest(profile=path.name):
                tree = ET.parse(path)
                for tag in ("TranscodeTargets/VideoProfile",
                            "TranscodeTargetProfiles/VideoTranscodeTarget"):
                    http = tree.findall(f"{tag}[@protocol='http']")
                    hls = tree.findall(f"{tag}[@protocol='hls']")
                    self.assertEqual(len(http), 1)
                    self.assertEqual(len(hls), 1)
                    self.assertEqual(normalized(http[0], True), normalized(hls[0], True))
                flags = tree.find("TranscodeTargets/VideoProfile[@protocol='hls']/"
                                  "Setting[@name='VideoEncodeFlags']").attrib["value"]
                for setting in ("-profile:v baseline", "cabac=0", "bframes=0", "ref=1",
                                "weightp=0", "8x8dct=0", "partitions=none", "slices=1"):
                    self.assertIn(setting, flags)


if __name__ == "__main__":
    unittest.main(verbosity=2)
