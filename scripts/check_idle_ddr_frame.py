#!/usr/bin/env python3
"""Compare a live DDR frame-store bank against the exact bytes the ARM believes
it published, and grade the result positionally, per scan line.

Why this exists: a byte-value spot check ("the logo pixels are the right
colours") CANNOT detect a wrong line stride — every sampled value can be
correct while every line starts at the wrong offset. This checker compares the
whole I420 payload positionally, and when it mismatches it actively searches for
the specific failure shapes that were hypothesised for the idle-logo left-edge
artifact:

    (a) wrong stride            (618 / 624 / 640 / 656 bytes per line)
    (b) constant pixel shift    (present_x applied twice, or on one side only)
    (c) leading damaged run     (unmasked partial first DDR burst per line)

Inputs are produced by scripts/ddr_frame_dump_device.py (device readback) and
tools/gen_idle_frame.cpp (reference, built from the *product* renderer, so the
checker cannot pass by reimplementing the renderer's bug).

Prints `Scope:` first. Exit 0 = match / self-test ok, 1 = mismatch, 77 = skip.
"""

import argparse
import base64
import gzip
import sys

CODED_W = 624
CODED_H = 480
Y_BYTES = CODED_W * CODED_H
C_W = CODED_W // 2
C_H = CODED_H // 2
C_BYTES = C_W * C_H
FRAME_BYTES = Y_BYTES + 2 * C_BYTES

STRIDE_HYPOTHESES = (618, 624, 640, 656)
SHIFT_HYPOTHESES = (-16, -11, -6, -1, 0, 1, 6, 11, 16)


def load_dump(path):
    """Return (meta dict, raw bytes|None) from a ddr_frame_dump_device.py capture."""
    meta = {}
    raw = None
    with open(path, "r") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("DATA "):
                raw = gzip.decompress(base64.b64decode(line[5:]))
            elif line:
                parts = line.split()
                meta[parts[0]] = " ".join(parts[1:])
    return meta, raw


def plane_mismatch(got, exp, start, count):
    return sum(1 for i in range(start, start + count) if got[i] != exp[i])


def line_diffs(got, exp, width, height, stride=None):
    """Per-line (first_bad_col, bad_count) for the luma plane."""
    stride = width if stride is None else stride
    out = []
    for y in range(height):
        g = got[y * stride:y * stride + width]
        e = exp[y * width:y * width + width]
        first = -1
        bad = 0
        for x in range(width):
            if g[x] != e[x]:
                bad += 1
                if first < 0:
                    first = x
        out.append((first, bad))
    return out


def try_stride(got, exp, width, height, stride):
    """Luma bytes that would match if the writer used `stride` bytes per line."""
    if (height - 1) * stride + width > len(got):
        return -1
    ok = 0
    for y in range(height):
        g = got[y * stride:y * stride + width]
        e = exp[y * width:y * width + width]
        ok += sum(1 for a, b in zip(g, e) if a == b)
    return ok


def try_shift(got, exp, width, height, shift):
    """Luma bytes that would match if every line were displaced by `shift` px."""
    ok = 0
    for y in range(height):
        g = got[y * width:y * width + width]
        e = exp[y * width:y * width + width]
        lo = max(0, -shift)
        hi = min(width, width - shift)
        ok += sum(1 for x in range(lo, hi) if g[x + shift] == e[x])
    return ok


def grade(got, exp, out=print):
    """Positional grade of `got` against `exp`. Returns a dict of findings."""
    res = {}
    n = min(len(got), len(exp))
    out("dump_bytes=%d ref_bytes=%d compared=%d" % (len(got), len(exp), n))

    uniq = set(got[:Y_BYTES])
    out("luma_distinct_byte_values=%d" % len(uniq))
    if len(uniq) == 1:
        out("luma_uniform_value=0x%02X" % got[0])
    res["uniform"] = len(uniq) == 1

    ydiff = plane_mismatch(got, exp, 0, Y_BYTES)
    udiff = plane_mismatch(got, exp, Y_BYTES, C_BYTES)
    vdiff = plane_mismatch(got, exp, Y_BYTES + C_BYTES, C_BYTES)
    out("luma_mismatch_bytes=%d/%d chroma_u_mismatch=%d/%d chroma_v_mismatch=%d/%d"
        % (ydiff, Y_BYTES, udiff, C_BYTES, vdiff, C_BYTES))
    res["y"], res["u"], res["v"] = ydiff, udiff, vdiff
    if ydiff == 0 and udiff == 0 and vdiff == 0:
        res["match"] = True
        return res
    res["match"] = False

    out("--- stride hypotheses (luma bytes matching out of %d) ---" % Y_BYTES)
    best = None
    for stride in STRIDE_HYPOTHESES:
        ok = try_stride(got, exp, CODED_W, CODED_H, stride)
        out("stride=%d matched=%d (%.2f%%)"
            % (stride, ok, 100.0 * ok / Y_BYTES if ok >= 0 else -1.0))
        if best is None or ok > best[1]:
            best = (stride, ok)
    out("best_stride=%d matched=%d" % best)
    res["best_stride"] = best[0]

    out("--- horizontal shift hypotheses (stride=%d) ---" % CODED_W)
    bshift = None
    for shift in SHIFT_HYPOTHESES:
        ok = try_shift(got, exp, CODED_W, CODED_H, shift)
        out("shift=%+d matched=%d (%.2f%%)" % (shift, ok, 100.0 * ok / Y_BYTES))
        if bshift is None or ok > bshift[1]:
            bshift = (shift, ok)
    out("best_shift=%+d matched=%d" % bshift)
    res["best_shift"] = bshift[0]

    ld = line_diffs(got, exp, CODED_W, CODED_H)
    bad_lines = [y for y, (_f, c) in enumerate(ld) if c]
    out("--- per-line damage (stride=%d) ---" % CODED_W)
    out("bad_lines=%d/%d" % (len(bad_lines), CODED_H))
    res["bad_lines"] = len(bad_lines)
    if bad_lines:
        firsts = [ld[y][0] for y in bad_lines]
        hist = {}
        for f in firsts:
            hist[f] = hist.get(f, 0) + 1
        out("first_bad_col_histogram(top8)=%s"
            % sorted(hist.items(), key=lambda kv: -kv[1])[:8])
        out("min_first_bad_col=%d max_first_bad_col=%d" % (min(firsts), max(firsts)))
        left = sum(1 for y in bad_lines if ld[y][0] < 24)
        out("bad_lines_starting_within_left_24px=%d/%d" % (left, len(bad_lines)))
        res["min_first_bad_col"] = min(firsts)
        res["left_start_lines"] = left
    return res


def synth_reference():
    """A deterministic, non-uniform I420 stand-in for the self-test.

    It must not be uniform along a line, or a shift/stride would be invisible.
    """
    y = bytearray(Y_BYTES)
    for row in range(CODED_H):
        base = row * CODED_W
        for x in range(CODED_W):
            y[base + x] = (x * 7 + row * 13) & 0xFF
    c = bytearray(2 * C_BYTES)
    for i in range(len(c)):
        c[i] = (i * 5) & 0xFF
    return bytes(y) + bytes(c)


def mutate_stride(ref, stride):
    """Writer laid luma lines out at `stride` bytes instead of CODED_W."""
    buf = bytearray(FRAME_BYTES)
    for row in range(CODED_H):
        src = ref[row * CODED_W:(row + 1) * CODED_W]
        dst = row * stride
        if dst + CODED_W > Y_BYTES:
            break
        buf[dst:dst + CODED_W] = src
    buf[Y_BYTES:] = ref[Y_BYTES:]
    return bytes(buf)


def mutate_shift(ref, shift):
    """Every luma line displaced by `shift` pixels."""
    buf = bytearray(ref)
    for row in range(CODED_H):
        src = ref[row * CODED_W:(row + 1) * CODED_W]
        line = bytearray(CODED_W)
        for x in range(CODED_W):
            sx = x - shift
            line[x] = src[sx] if 0 <= sx < CODED_W else 0
        buf[row * CODED_W:(row + 1) * CODED_W] = line
    return bytes(buf)


def mutate_leading_run(ref, run):
    """First N pixels of every luma line forced black — the RTL line-buffer-miss
    signature: a ragged black prefix at the left edge of each scan line."""
    buf = bytearray(ref)
    for row in range(CODED_H):
        n = run if (row % 3) else max(1, run // 2)  # ragged, like a real miss
        for x in range(n):
            buf[row * CODED_W + x] = 0
    return bytes(buf)


def self_test():
    quiet = lambda *_a, **_k: None  # noqa: E731
    ref = synth_reference()
    cases = []

    r = grade(ref, ref, out=quiet)
    cases.append(("identity_must_match", r.get("match") is True, r))

    r = grade(mutate_stride(ref, 640), ref, out=quiet)
    cases.append(("stride640_must_fail_and_be_identified",
                  (not r["match"]) and r.get("best_stride") == 640, r))

    r = grade(mutate_shift(ref, 11), ref, out=quiet)
    cases.append(("shift_plus11_must_fail_and_be_identified",
                  (not r["match"]) and r.get("best_shift") == 11, r))

    r = grade(mutate_leading_run(ref, 16), ref, out=quiet)
    cases.append(("leading_black_run_must_fail_at_left_edge",
                  (not r["match"]) and r.get("min_first_bad_col") == 0
                  and r.get("left_start_lines") == r.get("bad_lines"), r))

    print("Scope: %d synthetic detector cases (1 must-pass, 3 must-fail)" % len(cases))
    bad = 0
    keys = ("match", "best_stride", "best_shift", "min_first_bad_col",
            "bad_lines", "left_start_lines")
    for name, ok, r in cases:
        print("%s %s %s" % ("OK  " if ok else "FAIL", name,
                            {k: v for k, v in r.items() if k in keys}))
        if not ok:
            bad += 1
    if bad:
        print("RESULT FAIL %d/%d self-test cases" % (bad, len(cases)))
        return 1
    print("RESULT PASS detector distinguishes stride, shift and left-edge damage")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump")
    ap.add_argument("--ref")
    ap.add_argument("--label", default="")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.dump or not args.ref:
        print("Scope: 0")
        print("SKIP --dump and --ref are required without --self-test")
        return 77

    try:
        meta, got = load_dump(args.dump)
    except FileNotFoundError:
        print("Scope: 0")
        print("SKIP missing dump %s" % args.dump)
        return 77
    try:
        with open(args.ref, "rb") as f:
            exp = f.read()
    except FileNotFoundError:
        print("Scope: 0")
        print("SKIP missing reference %s" % args.ref)
        return 77
    if got is None:
        print("Scope: 0")
        print("SKIP dump %s carried no DATA record" % args.dump)
        return 77
    if len(got) < FRAME_BYTES or len(exp) < FRAME_BYTES:
        print("Scope: 0")
        print("SKIP short payload dump=%d ref=%d need=%d"
              % (len(got), len(exp), FRAME_BYTES))
        return 77

    print("Scope: %d luma bytes (%dx%d) + %d chroma bytes; denominator = full "
          "%d-byte I420 payload, compared positionally"
          % (Y_BYTES, CODED_W, CODED_H, 2 * C_BYTES, FRAME_BYTES))
    if args.label:
        print("label: %s" % args.label)
    for k in ("BANK", "DOORBELL", "PLXD", "PLXF"):
        if k in meta:
            print("%s %s" % (k, meta[k]))

    res = grade(got, exp)
    if res["match"]:
        print("RESULT PASS bank matches product-rendered payload byte-for-byte")
        return 0
    print("RESULT FAIL bank does not match product-rendered payload")
    return 1


if __name__ == "__main__":
    sys.exit(main())
