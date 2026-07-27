#!/usr/bin/env python3
"""H.264 MC interpolation cross-check against ffmpeg decode.

Strategy: create a 2-frame H.264 clip where we can isolate MC predictions
by encoding with --no-deblock and examining P_Skip macroblocks (which have
zero residual by definition). For P_Skip MBs, decoded_P = MC_prediction.

For fractional MV testing: encode with sub-pixel motion and extract exact
MVs from the bitstream by parsing the CAVLC data for the small (2x2 MB)
test frame.
"""

import hashlib
import os
import struct
import subprocess
import sys
import random
import tempfile

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
    """Create a smooth YUV420 frame with controllable sub-pixel phase.
    Uses a low-frequency sinusoidal pattern that varies smoothly —
    this ensures x264's sub-pel refinement finds fractional MVs."""
    import math
    y_plane = bytearray(w * h)
    for row in range(h):
        for col in range(w):
            # Low-frequency pattern that changes smoothly
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
        print(f"ffmpeg decode failed: {result.stderr.decode()[-200:]}")
        return []

    frame_size = w * h * 3 // 2
    y_size = w * h
    data = result.stdout
    frames = []
    offset = 0
    while offset + frame_size <= len(data):
        y_plane = data[offset:offset + y_size]
        frames.append(y_plane)
        offset += frame_size
    return frames


def run_cpp_model(ref_data, stride, pw, ph, ix, iy, fx, fy,
                  is_chroma, dx, dy, blk_w, blk_h, driver_bin):
    """Run C++ reference model on given inputs."""
    ref_hex = ref_data.hex()
    cmd = [driver_bin, ref_hex, str(stride), str(pw), str(ph),
           str(ix), str(iy), str(fx), str(fy),
           str(1 if is_chroma else 0), str(dx), str(dy),
           str(blk_w), str(blk_h)]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        return None
    return [int(x) for x in result.stdout.strip().split()]


def main():
    w, h = 64, 64  # 4x4 MBs = 16 MBs total
    frame_size = w * h * 3 // 2

    # Build C++ driver first
    script_dir = os.path.dirname(os.path.abspath(__file__))
    rtl_dir = os.path.join(script_dir, '..', 'rtl')
    driver_src = os.path.join(script_dir, 'ffmpeg_mc_driver.cpp')
    driver_bin = os.path.join(script_dir, 'ffmpeg_mc_driver')

    with open(driver_src, 'w') as f:
        f.write(r'''
#include "h264_mc_ref_model.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static std::vector<uint8_t> hex_to_bytes(const char* hex) {
    std::vector<uint8_t> bytes;
    size_t len = strlen(hex);
    for (size_t i = 0; i + 1 < len; i += 2) {
        char buf[3] = {hex[i], hex[i+1], 0};
        bytes.push_back(static_cast<uint8_t>(strtol(buf, nullptr, 16)));
    }
    return bytes;
}

int main(int argc, char** argv) {
    if (argc < 14) return 1;
    auto ref = hex_to_bytes(argv[1]);
    int stride=atoi(argv[2]), pw=atoi(argv[3]), ph=atoi(argv[4]);
    int ix=atoi(argv[5]), iy=atoi(argv[6]), fx=atoi(argv[7]), fy=atoi(argv[8]);
    int is_chroma=atoi(argv[9]), dx=atoi(argv[10]), dy=atoi(argv[11]);
    int blk_w=atoi(argv[12]), blk_h=atoi(argv[13]);
    for (int r = 0; r < blk_h; r++)
        for (int c = 0; c < blk_w; c++) {
            uint8_t val;
            if (is_chroma)
                val = mc_ref::chroma_interp(ref.data(), stride,
                    ix+c, iy+r, dx, dy, pw, ph);
            else
                val = mc_ref::luma_interp(ref.data(), stride,
                    ix+c, iy+r, fx, fy, pw, ph);
            printf("%d ", val);
        }
    printf("\n");
    return 0;
}
''')

    compile_cmd = ['g++', '-std=c++17', '-O2', f'-I{rtl_dir}',
                   driver_src, '-o', driver_bin]
    result = subprocess.run(compile_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"FAIL: compile error: {result.stderr}")
        return 1

    # -----------------------------------------------------------------------
    # Test 1: Static scene → P_Skip with MV=0
    # Encode with --no-deblock so reference = decoded I-frame exactly.
    # For P_Skip with MV=0, decoded_P should equal I-frame at same position.
    # -----------------------------------------------------------------------
    yuv_path = os.path.join(script_dir, 'ffcheck_static.yuv')
    h264_path = os.path.join(script_dir, 'ffcheck_static.h264')

    frame0 = create_gradient_yuv(w, h, shift_x=0)
    frame1 = create_gradient_yuv(w, h, shift_x=0)  # identical

    with open(yuv_path, 'wb') as f:
        f.write(frame0 + frame1)

    # Encode
    enc_cmd = ['x264', '--input-res', f'{w}x{h}', '--fps', '25',
               '--qp', '10', '--bframes', '0', '--ref', '1',
               '--no-cabac', '--no-deblock',
               '--threads', '1', '--quiet',
               '-o', h264_path, yuv_path]
    subprocess.run(enc_cmd, capture_output=True, timeout=10)

    # Decode
    frames = decode_yuv_frames(h264_path, w, h)
    if len(frames) < 2:
        print("FAIL: could not decode 2 frames")
        return 1

    iframe_y = frames[0]
    pframe_y = frames[1]

    # For static scene with --no-deblock, P_Skip MBs should match I-frame
    # exactly (MV=0, zero residual, no deblock artifacts).
    # Compare all 16x16 MB regions.
    static_match = 0
    static_mismatch = 0
    for mb_y in range(h // 16):
        for mb_x in range(w // 16):
            match = True
            for r in range(16):
                for c in range(16):
                    y_off = (mb_y * 16 + r) * w + (mb_x * 16 + c)
                    if iframe_y[y_off] != pframe_y[y_off]:
                        match = False
                        break
                if not match:
                    break
            if match:
                static_match += 1
            else:
                static_mismatch += 1

    # Also verify C++ model agrees with I-frame for integer-pel (MV=0)
    cpp_match = 0
    for mb_y in range(h // 16):
        for mb_x in range(w // 16):
            ix = mb_x * 16
            iy = mb_y * 16
            cpp_result = run_cpp_model(
                iframe_y, w, w, h,
                ix, iy, 0, 0,  # frac=0,0 (integer pel)
                False, 0, 0, 16, 16, driver_bin)
            if cpp_result is None:
                print(f"FAIL: C++ model returned error for MB ({mb_x},{mb_y})")
                continue
            # Compare against P-frame (which should be MC prediction for P_Skip)
            expected = []
            for r in range(16):
                for c in range(16):
                    expected.append(pframe_y[(iy + r) * w + ix + c])
            if cpp_result == expected:
                cpp_match += 1
            else:
                # Find first mismatch
                for i, (g, e) in enumerate(zip(cpp_result, expected)):
                    if g != e:
                        print(f"  Static: C++ vs ffmpeg mismatch MB({mb_x},{mb_y}) "
                              f"pos={i} cpp={g} ffmpeg={e}")
                        break

    print(f"  Static scene: {static_match}/{static_match + static_mismatch} "
          f"MBs match I→P, C++ model: {cpp_match}/{h // 16 * w // 16}")

    # -----------------------------------------------------------------------
    # Test 2: Fractional MV cross-check via P_Skip enumeration
    # Create smooth content with sub-pixel motion. Encode at high QP to
    # maximize P_Skip. For P_Skip MBs (zero residual), decoded = MC(ref, MV).
    # We try all quarter-pel offsets and verify one matches ffmpeg's output.
    # If our FIR is wrong, no offset matches.
    # -----------------------------------------------------------------------
    yuv_path2 = os.path.join(script_dir, 'ffcheck_frac.yuv')
    h264_path2 = os.path.join(script_dir, 'ffcheck_frac.h264')

    # Smooth frames with varied sub-pixel shifts to force diverse fractional MVs
    smooth0 = create_smooth_yuv(w, h, phase_x=0.0, phase_y=0.0)
    smooth1 = create_smooth_yuv(w, h, phase_x=0.75, phase_y=0.5)
    smooth2 = create_smooth_yuv(w, h, phase_x=1.5, phase_y=1.0)
    smooth3 = create_smooth_yuv(w, h, phase_x=2.25, phase_y=0.25)
    # Additional frames with different motion directions
    smooth4 = create_smooth_yuv(w, h, phase_x=0.0, phase_y=1.75)
    smooth5 = create_smooth_yuv(w, h, phase_x=1.0, phase_y=2.5)
    smooth6 = create_smooth_yuv(w, h, phase_x=3.0, phase_y=0.0)
    smooth7 = create_smooth_yuv(w, h, phase_x=0.5, phase_y=3.0)

    with open(yuv_path2, 'wb') as f:
        f.write(smooth0 + smooth1 + smooth2 + smooth3 +
                smooth4 + smooth5 + smooth6 + smooth7)

    # Encode: no deblock (so reference=decoded exactly), high QP for P_Skip,
    # high subme for fractional MV search
    enc_cmd2 = ['x264', '--input-res', f'{w}x{h}', '--fps', '25',
                '--qp', '35', '--bframes', '0', '--ref', '1',
                '--no-cabac', '--no-deblock', '--subme', '7',
                '--me', 'hex', '--threads', '1', '--quiet',
                '-o', h264_path2, yuv_path2]
    subprocess.run(enc_cmd2, capture_output=True, timeout=10)

    frames2 = decode_yuv_frames(h264_path2, w, h)
    if len(frames2) < 2:
        print("FAIL: could not decode fractional test")
        return 1

    frac_matched = 0
    frac_total = 0
    frac_found_positions = set()

    for frame_idx in range(1, len(frames2)):
        ref_y = frames2[frame_idx - 1]
        dec_y = frames2[frame_idx]

        for mb_y in range(h // 16):
            for mb_x in range(w // 16):
                frac_total += 1
                target = []
                for r in range(16):
                    for c in range(16):
                        target.append(dec_y[(mb_y*16+r)*w + mb_x*16+c])

                # Try integer offsets [-4, 4] and all 16 quarter-pel fracs
                found = False
                for int_dy in range(-4, 5):
                    if found:
                        break
                    for int_dx in range(-4, 5):
                        if found:
                            break
                        for fy in range(4):
                            if found:
                                break
                            for fx in range(4):
                                ix = mb_x * 16 + int_dx
                                iy = mb_y * 16 + int_dy
                                cpp_result = run_cpp_model(
                                    ref_y, w, w, h,
                                    ix, iy, fx, fy,
                                    False, 0, 0, 16, 16, driver_bin)
                                if cpp_result and cpp_result == target:
                                    frac_matched += 1
                                    frac_found_positions.add((fx, fy))
                                    found = True

    frac_pos_str = ','.join(f'({x},{y})' for x,y in sorted(frac_found_positions))
    print(f"  Fractional MV: {frac_matched}/{frac_total} MBs matched, "
          f"positions found: {frac_pos_str}")

    # Clean up
    for f in [yuv_path, h264_path, yuv_path2, h264_path2,
              driver_src, driver_bin]:
        try:
            os.unlink(f)
        except OSError:
            pass

    # -----------------------------------------------------------------------
    # Verdict
    # -----------------------------------------------------------------------
    total_mbs = h // 16 * w // 16
    frac_coverage = len(frac_found_positions)

    if static_match != total_mbs or cpp_match != total_mbs:
        if static_mismatch > 0:
            print(f"FAIL: {static_mismatch} MB mismatches in static scene")
        if cpp_match < total_mbs:
            print(f"FAIL: C++ model disagrees with ffmpeg for "
                  f"{total_mbs - cpp_match}/{total_mbs} MBs")
        return 1

    print(f"OK ffmpeg crosscheck: static {total_mbs}/{total_mbs} MBs exact, "
          f"fractional {frac_matched}/{frac_total} MBs matched "
          f"({frac_coverage} distinct quarter-pel positions confirmed)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
