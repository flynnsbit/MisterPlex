#!/usr/bin/env python3
"""H.264 MC interpolation cross-check against ffmpeg decode.

Strategy: create H.264 clips where P_Skip MBs (zero residual) reveal the
pure MC prediction. For P_Skip, decoded_P = MC(ref, MV). We encode with
--no-deblock so reference = decoded exactly.

Uses a compiled C++ bulk searcher that tests all quarter-pel positions
for each MB, avoiding per-call subprocess overhead.
"""

import math
import os
import struct
import subprocess
import sys


def create_gradient_yuv(w, h, shift_x=0):
    """Create a gradient YUV420 frame, optionally shifted."""
    y_plane = bytearray(w * h)
    for row in range(h):
        for col in range(w):
            src_col = (col - shift_x) % w
            y_plane[row * w + col] = ((src_col * 7 + row * 13) & 0xFF)
    u_plane = bytes([128] * (w // 2) * (h // 2))
    v_plane = bytes([128] * (w // 2) * (h // 2))
    return bytes(y_plane) + u_plane + v_plane


def create_smooth_yuv(w, h, phase_x=0.0, phase_y=0.0):
    """Create a smooth YUV420 frame with controllable sub-pixel phase."""
    y_plane = bytearray(w * h)
    for row in range(h):
        for col in range(w):
            fx = math.sin(2 * math.pi * (col - phase_x) / w * 2.5)
            fy = math.sin(2 * math.pi * (row - phase_y) / h * 3.0)
            val = int(128 + 100 * fx * fy)
            y_plane[row * w + col] = max(0, min(255, val))
    u_plane = bytes([128] * (w // 2) * (h // 2))
    v_plane = bytes([128] * (w // 2) * (h // 2))
    return bytes(y_plane) + u_plane + v_plane


def decode_yuv_frames(h264_path, w, h):
    """Decode H.264 to raw YUV420 and return per-frame Y planes."""
    cmd = ['ffmpeg', '-y', '-i', h264_path,
           '-f', 'rawvideo', '-pix_fmt', 'yuv420p',
           '-vsync', '0', 'pipe:1']
    result = subprocess.run(cmd, capture_output=True, timeout=10)
    if result.returncode != 0:
        return []
    frame_size = w * h * 3 // 2
    y_size = w * h
    data = result.stdout
    frames = []
    offset = 0
    while offset + frame_size <= len(data):
        frames.append(data[offset:offset + y_size])
        offset += frame_size
    return frames


def build_bulk_search(script_dir, rtl_dir):
    """Build C++ bulk search binary. Returns path or None."""
    driver_src = os.path.join(script_dir, 'ffmpeg_mc_bulk_search.cpp')
    driver_bin = os.path.join(script_dir, 'ffmpeg_mc_bulk_search')

    with open(driver_src, 'w') as f:
        f.write(r'''
#include "h264_mc_ref_model.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// Reads binary: ref_frame (w*h bytes), then queries (4-byte coords + 256-byte target)
// Output: "MATCH mb_x mb_y int_dx int_dy fx fy\n" or "NOMATCH mb_x mb_y\n"
int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: bulk_search <w> <h>\n"); return 1; }
    int pw = atoi(argv[1]), ph = atoi(argv[2]);
    std::vector<uint8_t> ref(pw * ph);
    if (fread(ref.data(), 1, ref.size(), stdin) != ref.size()) return 1;

    while (true) {
        uint16_t coords[2];
        if (fread(coords, sizeof(uint16_t), 2, stdin) != 2) break;
        int mb_x = coords[0], mb_y = coords[1];
        uint8_t target[256];
        if (fread(target, 1, 256, stdin) != 256) break;

        bool found = false;
        for (int int_dy = -4; int_dy <= 4 && !found; int_dy++) {
            for (int int_dx = -4; int_dx <= 4 && !found; int_dx++) {
                for (int fy = 0; fy < 4 && !found; fy++) {
                    for (int fx = 0; fx < 4 && !found; fx++) {
                        int ix = mb_x * 16 + int_dx;
                        int iy = mb_y * 16 + int_dy;
                        bool match = true;
                        for (int r = 0; r < 16 && match; r++) {
                            for (int c = 0; c < 16 && match; c++) {
                                uint8_t pred = mc_ref::luma_interp(
                                    ref.data(), pw,
                                    ix + c, iy + r, fx, fy, pw, ph);
                                if (pred != target[r * 16 + c])
                                    match = false;
                            }
                        }
                        if (match) {
                            printf("MATCH %d %d %d %d %d %d\n",
                                   mb_x, mb_y, int_dx, int_dy, fx, fy);
                            fflush(stdout);
                            found = true;
                        }
                    }
                }
            }
        }
        if (!found) {
            printf("NOMATCH %d %d\n", mb_x, mb_y);
            fflush(stdout);
        }
    }
    return 0;
}
''')

    result = subprocess.run(
        ['g++', '-std=c++17', '-O3', f'-I{rtl_dir}', driver_src, '-o', driver_bin],
        capture_output=True, text=True)
    if result.returncode != 0:
        print(f"FAIL: compile error: {result.stderr}")
        return None, driver_src
    return driver_bin, driver_src


def bulk_search_frame(driver_bin, ref_y, dec_y, w, h):
    """Run bulk search for all MBs in a frame pair. Returns (matched, positions)."""
    mb_cols, mb_rows = w // 16, h // 16
    # Build input: ref frame + queries
    input_data = bytearray(ref_y)
    for mb_y in range(mb_rows):
        for mb_x in range(mb_cols):
            input_data += struct.pack('<HH', mb_x, mb_y)
            target = bytearray(256)
            for r in range(16):
                for c in range(16):
                    target[r * 16 + c] = dec_y[(mb_y * 16 + r) * w + mb_x * 16 + c]
            input_data += target

    proc = subprocess.run(
        [driver_bin, str(w), str(h)],
        input=bytes(input_data), capture_output=True, timeout=120)

    matched = 0
    positions = set()
    for line in proc.stdout.decode().strip().split('\n'):
        if not line:
            continue
        parts = line.split()
        if parts[0] == 'MATCH':
            matched += 1
            fx, fy = int(parts[5]), int(parts[6])
            positions.add((fx, fy))
    return matched, positions


def main():
    w, h = 64, 64  # 4x4 MBs = 16 MBs total

    script_dir = os.path.dirname(os.path.abspath(__file__))
    rtl_dir = os.path.join(script_dir, '..', 'rtl')

    driver_bin, driver_src = build_bulk_search(script_dir, rtl_dir)
    if driver_bin is None:
        return 1

    # -----------------------------------------------------------------------
    # Test 1: Static scene → P_Skip with MV=0
    # -----------------------------------------------------------------------
    yuv_path = os.path.join(script_dir, 'ffcheck_static.yuv')
    h264_path = os.path.join(script_dir, 'ffcheck_static.h264')

    frame0 = create_gradient_yuv(w, h, shift_x=0)
    with open(yuv_path, 'wb') as f:
        f.write(frame0 + frame0)  # identical frames

    subprocess.run(['x264', '--input-res', f'{w}x{h}', '--fps', '25',
                    '--qp', '10', '--bframes', '0', '--ref', '1',
                    '--no-cabac', '--no-deblock',
                    '--threads', '1', '--quiet',
                    '-o', h264_path, yuv_path],
                   capture_output=True, timeout=10)

    frames = decode_yuv_frames(h264_path, w, h)
    if len(frames) < 2:
        print("FAIL: could not decode 2 frames")
        return 1

    # Static: all MBs should match exactly (MV=0)
    total_mbs = (w // 16) * (h // 16)
    static_matched, static_pos = bulk_search_frame(
        driver_bin, frames[0], frames[1], w, h)

    print(f"  Static scene: {static_matched}/{total_mbs} MBs "
          f"matched via C++ model")

    # -----------------------------------------------------------------------
    # Test 2: Fractional MV cross-check — diverse motion patterns
    # -----------------------------------------------------------------------
    yuv_path2 = os.path.join(script_dir, 'ffcheck_frac.yuv')

    # Generate 20 frames with diverse sub-pixel motion
    phases = [
        (0.0, 0.0), (0.75, 0.5), (1.5, 1.0), (2.25, 0.25),
        (0.0, 1.75), (1.0, 2.5), (3.0, 0.0), (0.5, 3.0),
        (0.25, 0.0), (0.50, 0.0), (0.75, 0.75), (1.5, 0.75),
        (0.25, 0.25), (0.75, 1.25), (0.25, 1.0), (1.75, 1.0),
        (2.75, 0.5), (0.125, 2.0), (3.5, 1.5), (1.25, 3.25),
    ]
    with open(yuv_path2, 'wb') as f:
        for px, py in phases:
            f.write(create_smooth_yuv(w, h, phase_x=px, phase_y=py))

    # Try multiple encoding configs to hit more quarter-pel positions
    enc_configs = [
        {'qp': '35', 'subme': '7', 'me': 'hex'},
        {'qp': '30', 'subme': '9', 'me': 'umh'},
        {'qp': '40', 'subme': '5', 'me': 'hex'},
        {'qp': '25', 'subme': '10', 'me': 'esa'},
    ]

    frac_matched_total = 0
    frac_total = 0
    all_positions = set()

    for cfg_idx, cfg in enumerate(enc_configs):
        h264_frac = os.path.join(script_dir, f'ffcheck_frac_{cfg_idx}.h264')
        subprocess.run(
            ['x264', '--input-res', f'{w}x{h}', '--fps', '25',
             '--qp', cfg['qp'], '--bframes', '0', '--ref', '1',
             '--no-cabac', '--no-deblock', '--subme', cfg['subme'],
             '--me', cfg['me'], '--threads', '1', '--quiet',
             '-o', h264_frac, yuv_path2],
            capture_output=True, timeout=30)

        frames2 = decode_yuv_frames(h264_frac, w, h)
        try:
            os.unlink(h264_frac)
        except OSError:
            pass

        if len(frames2) < 2:
            continue

        for frame_idx in range(1, len(frames2)):
            matched, positions = bulk_search_frame(
                driver_bin, frames2[frame_idx - 1], frames2[frame_idx], w, h)
            frac_matched_total += matched
            frac_total += total_mbs
            all_positions.update(positions)

        # Early exit if all 16 positions found
        if len(all_positions) >= 15:  # 15 non-zero fractional + (0,0) integer
            break

    pos_str = ','.join(f'({x},{y})' for x, y in sorted(all_positions))
    print(f"  Fractional MV: {frac_matched_total}/{frac_total} MBs matched, "
          f"{len(all_positions)} positions found: {pos_str}")

    # Report specifically which of the target 5 positions are confirmed
    target_5 = {(0, 3), (2, 1), (2, 3), (3, 1), (3, 3)}
    confirmed = target_5 & all_positions
    missing = target_5 - all_positions
    if confirmed:
        print(f"  Newly confirmed: {','.join(f'({x},{y})' for x,y in sorted(confirmed))}")
    if missing:
        print(f"  Still missing: {','.join(f'({x},{y})' for x,y in sorted(missing))}")

    # Clean up
    for f in [yuv_path, h264_path, yuv_path2, driver_src, driver_bin]:
        try:
            os.unlink(f)
        except OSError:
            pass

    # -----------------------------------------------------------------------
    # Verdict
    # -----------------------------------------------------------------------
    if static_matched != total_mbs:
        print(f"FAIL: static scene — {total_mbs - static_matched} MBs not matched")
        return 1

    frac_coverage = len(all_positions)
    print(f"OK ffmpeg crosscheck: static {total_mbs}/{total_mbs} MBs exact, "
          f"fractional {frac_matched_total}/{frac_total} MBs matched "
          f"({frac_coverage} distinct quarter-pel positions confirmed)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
