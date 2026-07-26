#!/usr/bin/env python3
"""Generate a 320x240 RGB24 edge-marker frame for diagnosing edge wrap/shift.

Each of the four edges gets three uniquely coloured 1-pixel lines, so a capture
can tell not just *that* an edge is wrong but by how many pixels and in which
direction. The markers are inset along the perpendicular axis so the horizontal
and vertical markers never overlap.

  first col/row = luma 255 (white)
  last  col/row = luma 128 (mid grey)
  body          = luma 16

The four luma levels are mutually distinguishable, so a capture can tell exactly
which source column landed on the first and last displayed pixel. If the left
edge reads 128, the last column has wrapped around to the front.
"""
import struct
import sys

W, H = 320, 240
# Markers are GREYSCALE on purpose. The HDMI grabber only offers MJPEG (4:2:0) and
# YUYV (4:2:2); both subsample chroma horizontally, which smears 1-pixel coloured
# markers into false colours at the exact edges we are trying to measure. Luma is
# carried at full horizontal resolution in both formats, so luma-coded markers are
# artifact-free.
# Only two marker levels, widely separated, so the grabber's limited-range /
# gamma handling cannot confuse them: the first column/row is white and the last
# is mid-grey, against a near-black body. Position tells us whether an edge is
# shifted; run WIDTH tells us whether an edge pixel is being duplicated (a
# duplicated last column is exactly the "bar" seen on the right edge).
L_FIRST = (255, 255, 255)  # source column/row 0
R_LAST = (128, 128, 128)   # source column/row W-1
BODY = (16, 16, 16)

# Inset so the column markers and row markers occupy disjoint bands.
COL_Y0, COL_Y1 = 40, 200
ROW_X0, ROW_X1 = 40, 280


def main(path):
    px = [[BODY] * W for _ in range(H)]

    # Mid-frame reference bars so the body is not featureless and any global
    # shift is visible independently of the edges.
    bars = [255, 0, 224, 32, 192, 64, 160, 96]
    BAR_X0, BAR_X1 = 60, 150
    for y in range(210, 230):
        for x in range(BAR_X0, BAR_X1):
            v = bars[((x - BAR_X0) * len(bars)) // (BAR_X1 - BAR_X0)]
            px[y][x] = (v, v, v)

    for y in range(COL_Y0, COL_Y1):
        px[y][0] = L_FIRST
        px[y][W - 1] = R_LAST

    for x in range(ROW_X0, ROW_X1):
        px[0][x] = L_FIRST
        px[H - 1][x] = R_LAST

    with open(path, "wb") as f:
        for row in px:
            f.write(b"".join(struct.pack("BBB", *c) for c in row))
    print(f"wrote {path} ({W}x{H} RGB24, {W*H*3} bytes)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/edge_markers.rgb")
