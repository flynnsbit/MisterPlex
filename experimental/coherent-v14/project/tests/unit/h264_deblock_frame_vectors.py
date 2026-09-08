#!/usr/bin/env python3
"""Whole-picture filter leaf vectors; never used as decoder/reference injections."""
import pathlib
import re
import subprocess
import sys

build = pathlib.Path(sys.argv[1]).resolve()
for name, width, height, qp, alpha, beta in (
    ("textured", 64, 48, 32, 2, -2),
    ("strong", 32, 32, 43, -3, 3),
):
    raw = bytearray()
    for plane in range(3):
        w, h = (width, height) if plane == 0 else (width // 2, height // 2)
        side = 16 if plane == 0 else 8
        for y in range(h):
            for x in range(w):
                mbx, mby = x // side, y // side
                detail = ((x * y) % 17 - 8) if (mbx + mby) % 2 else 0
                raw.append(64 + plane * 32 + mbx * 9 + mby * 7 +
                           (x % side // 4) * 4 + (y % side // 4) * 3 + detail)
    source = build / f"{name}.source.yuv"
    stream = build / f"{name}.264"
    unfiltered = build / f"{name}.unfiltered-leaf-input.yuv"
    ordinary = build / f"{name}.ordinary-filtered.yuv"
    source.write_bytes(raw)
    params = (f"keyint=1:min-keyint=1:scenecut=0:bframes=0:cabac=0:8x8dct=0:"
              f"partitions=i4x4:aq-mode=0:psy=0:chroma-qp-offset=0:deblock={alpha},{beta}")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "yuv420p",
                    "-s", f"{width}x{height}", "-i", str(source), "-frames:v", "1",
                    "-c:v", "libx264", "-profile:v", "baseline", "-qp", str(qp),
                    "-x264-params", params, "-f", "h264", str(stream)], check=True)
    trace = subprocess.run(["ffmpeg", "-v", "info", "-i", str(stream), "-c:v", "copy",
                            "-bsf:v", "trace_headers", "-f", "null", "-"],
                           check=True, capture_output=True, text=True).stderr
    (build / f"{name}.headers.log").write_text(trace)
    for field, expected in (("disable_deblocking_filter_idc", 0),
                            ("slice_alpha_c0_offset_div2", alpha),
                            ("slice_beta_offset_div2", beta),
                            ("chroma_qp_index_offset", 0)):
        found = re.findall(rf"\b{field}\b.*?=\s*(-?\d+)", trace)
        if not found or any(int(value) != expected for value in found):
            raise RuntimeError(f"{name}: unexpected encoded {field}: {found}")
    # The input to this isolated scheduler is a completely reconstructed,
    # unfiltered I picture. The expected output is ordinary FFmpeg, unmodified.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-skip_loop_filter", "all",
                    "-i", str(stream), "-frames:v", "1", "-pix_fmt", "yuv420p",
                    "-f", "rawvideo", str(unfiltered)], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(stream), "-frames:v", "1",
                    "-pix_fmt", "yuv420p", "-f", "rawvideo", str(ordinary)], check=True)
    subprocess.run([str(build / "Vh264_deblock_frame"), str(stream), str(unfiltered),
                    str(ordinary), str(alpha * 2), str(beta * 2)], check=True)
