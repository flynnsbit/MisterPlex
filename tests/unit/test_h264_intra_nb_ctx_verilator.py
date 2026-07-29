#!/usr/bin/env python3
"""RTL gate for reconstructed-neighbour context used by intra prediction."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN_VERILATOR = ROOT / "scripts/run_verilator.sh"
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
TB = ROOT / "tests/unit/rtl/h264_intra_nb_ctx_tb.sv"
EXPECTED_RED = ROOT / "tests/unit/expected_red.py"

GREEN_SCOPE = (
    "Scope: h264_intra_nb_ctx full-width pre-deblock reconstructed-neighbour context; "
    "coded=624x480, mb_grid=39x30 denominator=1170 MBs, luma block-level and h264_decode_top MB-level "
    "above/left/top-left/above-right plus chroma U/V above/left/top-left. "
    "Availability is semantic, including first_mb_in_slice slice boundaries. "
    "It does not cover entropy parsing, residual math, deblock filtering, "
    "DPB post-deblock storage, inter prediction, or HDMI presentation."
)

HARNESS = r'''#include "Vh264_intra_nb_ctx_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static uint8_t yval(int mb_x, int mb_y, int x, int y) {
    return static_cast<uint8_t>((37 + mb_y * 53 + mb_x * 7 + y * 5 + x * 3) & 0xff);
}
static uint8_t uval(int mb_x, int mb_y, int x, int y) {
    return static_cast<uint8_t>((91 + mb_y * 29 + mb_x * 11 + y * 3 + x * 5) & 0xff);
}
static uint8_t vval(int mb_x, int mb_y, int x, int y) {
    return static_cast<uint8_t>((17 + mb_y * 31 + mb_x * 13 + y * 7 + x * 2) & 0xff);
}

static void tick(Vh264_intra_nb_ctx_tb& dut) {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
}
static void wait_idle(Vh264_intra_nb_ctx_tb& dut) {
    int g = 0;
    while (dut.ctx_busy && g < 1024) { tick(dut); ++g; }
    tick(dut); tick(dut);
}
static void set_block_and_wait(Vh264_intra_nb_ctx_tb& dut, int idx) {
    dut.block_idx = idx;
    tick(dut);
    wait_idle(dut);
}

static void set_block(Vh264_intra_nb_ctx_tb& dut, int mb_x, int mb_y, int block_idx) {
    // H.264 Table 6-10 inverse: x={idx[2],idx[0],00}, y={idx[3],idx[1],00}
    int bx = (((block_idx >> 2) & 1) << 3) | (((block_idx >> 0) & 1) << 2);
    int by = (((block_idx >> 3) & 1) << 3) | (((block_idx >> 1) & 1) << 2);
    dut.block_idx = block_idx;
    for (int yy = 0; yy < 4; ++yy)
        for (int xx = 0; xx < 4; ++xx)
            dut.recon_in[yy * 4 + xx] = yval(mb_x, mb_y, bx + xx, by + yy);
}

static void set_mb_planes(Vh264_intra_nb_ctx_tb& dut, int mb_x, int mb_y) {
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x)
            dut.recon_y_mb[y * 16 + x] = yval(mb_x, mb_y, x, y);
    for (int y = 0; y < 8; ++y)
        for (int x = 0; x < 8; ++x) {
            dut.recon_u_mb[y * 8 + x] = uval(mb_x, mb_y, x, y);
            dut.recon_v_mb[y * 8 + x] = vval(mb_x, mb_y, x, y);
        }
}

static void start_mb_slice(Vh264_intra_nb_ctx_tb& dut, int mb_x, int mb_y, int first_mb_in_slice) {
    dut.mb_x = mb_x;
    dut.mb_y = mb_y;
    dut.mb_width = 39;
    dut.first_mb_in_slice = first_mb_in_slice;
    dut.mb_start = 1;
    tick(dut);
    dut.mb_start = 0;
    wait_idle(dut);
}

static void start_mb(Vh264_intra_nb_ctx_tb& dut, int mb_x, int mb_y) {
    start_mb_slice(dut, mb_x, mb_y, 0);
}

static void commit_mb(Vh264_intra_nb_ctx_tb& dut, int mb_x, int mb_y) {
    set_mb_planes(dut, mb_x, mb_y);
    for (int b = 0; b < 16; ++b) {
        set_block(dut, mb_x, mb_y, b);
        dut.block_valid = 1;
        tick(dut);
        dut.block_valid = 0;
        wait_idle(dut);
    }
    dut.mb_commit = 1;
    tick(dut);
    dut.mb_commit = 0;
    wait_idle(dut);
}

static int failures = 0;
static int checks = 0;
static int committed_mbs = 0;

static void check_bool(const char* what, bool got, bool want) {
    ++checks;
    if (got != want) {
        std::fprintf(stderr, "FAIL h264_intra_nb_ctx: %s got=%d want=%d\n", what, got ? 1 : 0, want ? 1 : 0);
        ++failures;
    }
}
static void check_u8(const char* what, int idx, uint8_t got, uint8_t want) {
    ++checks;
    if (got != want) {
        std::fprintf(stderr, "FAIL h264_intra_nb_ctx: %s[%d] got=%u want=%u\n", what, idx, got, want);
        ++failures;
    }
}

static void check_edge_mb00(Vh264_intra_nb_ctx_tb& dut) {
    dut.pred_mode = 2;
    set_block_and_wait(dut, 0);

    check_bool("mb00_has_above", dut.ctx_has_above, false);
    check_bool("mb00_has_left", dut.ctx_has_left, false);
    check_bool("mb00_has_chroma_above", dut.ctx_has_chroma_above, false);
    check_bool("mb00_has_chroma_left", dut.ctx_has_chroma_left, false);
    check_bool("mb00_mb_avail_top", dut.ctx_mb_avail_top, false);
    check_bool("mb00_mb_avail_left", dut.ctx_mb_avail_left, false);
    check_bool("mb00_mb_avail_topright", dut.ctx_mb_avail_topright, false);
    check_bool("mb00_mb_avail_topleft", dut.ctx_mb_avail_topleft, false);
    check_u8("mb00_top_left", 0, dut.ctx_top_left, 128);
    check_u8("mb00_nb_topleft", 0, dut.ctx_nb_topleft, 128);
    for (int i = 0; i < 16; ++i) {
        check_u8("mb00_dc_pred", i, dut.pred[i], 128);
        check_u8("mb00_nb_top", i, dut.ctx_nb_top[i], 128);
        check_u8("mb00_nb_left", i, dut.ctx_nb_left[i], 128);
    }
}

static void check_mb1_row0_left(Vh264_intra_nb_ctx_tb& dut) {
    dut.pred_mode = 2;
    set_block_and_wait(dut, 0);

    check_bool("mb10_has_above", dut.ctx_has_above, false);
    check_bool("mb10_has_left", dut.ctx_has_left, true);
    check_bool("mb10_mb_avail_left", dut.ctx_mb_avail_left, true);
    check_bool("mb10_mb_avail_top", dut.ctx_mb_avail_top, false);
    check_bool("mb10_mb_avail_topleft", dut.ctx_mb_avail_topleft, false);
    for (int i = 0; i < 4; ++i)
        check_u8("mb10_left_y", i, dut.ctx_left[i], yval(0, 0, 15, i));
    for (int i = 0; i < 16; ++i)
        check_u8("mb10_nb_left_y", i, dut.ctx_nb_left[i], yval(0, 0, 15, i));
    check_bool("mb10_has_chroma_left", dut.ctx_has_chroma_left, true);
    for (int i = 0; i < 8; ++i) {
        check_u8("mb10_left_u", i, dut.ctx_chroma_u_left[i], uval(0, 0, 7, i));
        check_u8("mb10_left_v", i, dut.ctx_chroma_v_left[i], vval(0, 0, 7, i));
    }
}

static void check_row1_above_and_corner(Vh264_intra_nb_ctx_tb& dut) {
    dut.pred_mode = 2;
    set_block_and_wait(dut, 0);

    check_bool("mb01_has_above", dut.ctx_has_above, true);
    check_bool("mb01_has_left", dut.ctx_has_left, false);
    check_bool("mb01_mb_avail_top", dut.ctx_mb_avail_top, true);
    check_bool("mb01_mb_avail_left", dut.ctx_mb_avail_left, false);
    check_bool("mb01_mb_avail_topright", dut.ctx_mb_avail_topright, true);
    for (int i = 0; i < 4; ++i)
        check_u8("mb01_above_y", i, dut.ctx_above[i], yval(0, 0, i, 15));
    for (int i = 0; i < 4; ++i)
        check_u8("mb01_above_right_y", i, dut.ctx_above[4 + i], yval(0, 0, 4 + i, 15));
    for (int i = 0; i < 16; ++i)
        check_u8("mb01_nb_top_y", i, dut.ctx_nb_top[i], yval(0, 0, i, 15));
    for (int i = 0; i < 4; ++i)
        check_u8("mb01_nb_topright_y", i, dut.ctx_nb_topright[i], yval(1, 0, i, 15));
    check_bool("mb01_has_chroma_above", dut.ctx_has_chroma_above, true);
    for (int i = 0; i < 8; ++i) {
        check_u8("mb01_above_u", i, dut.ctx_chroma_u_above[i], uval(0, 0, i, 7));
        check_u8("mb01_above_v", i, dut.ctx_chroma_v_above[i], vval(0, 0, i, 7));
    }
}

static void check_mb11_both(Vh264_intra_nb_ctx_tb& dut) {
    dut.pred_mode = 2;
    set_block_and_wait(dut, 0);

    check_bool("mb11_has_above", dut.ctx_has_above, true);
    check_bool("mb11_has_left", dut.ctx_has_left, true);
    check_bool("mb11_mb_avail_top", dut.ctx_mb_avail_top, true);
    check_bool("mb11_mb_avail_left", dut.ctx_mb_avail_left, true);
    check_bool("mb11_mb_avail_topleft", dut.ctx_mb_avail_topleft, true);
    check_u8("mb11_top_left_y", 0, dut.ctx_top_left, yval(0, 0, 15, 15));
    check_u8("mb11_nb_topleft_y", 0, dut.ctx_nb_topleft, yval(0, 0, 15, 15));
    check_u8("mb11_top_left_u", 0, dut.ctx_chroma_u_top_left, uval(0, 0, 7, 7));
    check_u8("mb11_top_left_v", 0, dut.ctx_chroma_v_top_left, vval(0, 0, 7, 7));
    for (int i = 0; i < 4; ++i) {
        check_u8("mb11_above_y", i, dut.ctx_above[i], yval(1, 0, i, 15));
        check_u8("mb11_left_y", i, dut.ctx_left[i], yval(0, 1, 15, i));
    }
}

static void check_above_right(Vh264_intra_nb_ctx_tb& dut) {
    dut.pred_mode = 3;
    set_block_and_wait(dut, 5);

    check_bool("mb37_above_right_available", dut.ctx_has_above_right, true);
    for (int i = 0; i < 4; ++i)
        check_u8("mb37_above_right_y", i, dut.ctx_above[4 + i], yval(38, 0, i, 15));
}

static void check_right_edge_above_right_unavailable(Vh264_intra_nb_ctx_tb& dut) {
    dut.pred_mode = 3;
    set_block_and_wait(dut, 5);

    check_bool("mb38_above_right_unavailable", dut.ctx_has_above_right, false);
    check_bool("mb38_mb_avail_topright_unavailable", dut.ctx_mb_avail_topright, false);
    for (int i = 0; i < 4; ++i)
        check_u8("mb38_above_right_replicate", i, dut.ctx_above[4 + i], dut.ctx_above[3]);
}

static void check_last_mb(Vh264_intra_nb_ctx_tb& dut) {
    dut.pred_mode = 2;
    set_block_and_wait(dut, 0);

    check_bool("mb38_29_mb_avail_top", dut.ctx_mb_avail_top, true);
    check_bool("mb38_29_mb_avail_left", dut.ctx_mb_avail_left, true);
    check_bool("mb38_29_mb_avail_topleft", dut.ctx_mb_avail_topleft, true);
    check_bool("mb38_29_mb_avail_topright", dut.ctx_mb_avail_topright, false);
    check_u8("mb38_29_nb_topleft_y", 0, dut.ctx_nb_topleft, yval(37, 28, 15, 15));
    for (int i = 0; i < 16; ++i) {
        check_u8("mb38_29_nb_top_y", i, dut.ctx_nb_top[i], yval(38, 28, i, 15));
        check_u8("mb38_29_nb_left_y", i, dut.ctx_nb_left[i], yval(37, 29, 15, i));
    }
}

static void check_slice_boundary_masks_storage(Vh264_intra_nb_ctx_tb& dut) {
    const int sx = 5;
    const int sy = 1;
    const int first = sy * 39 + sx;
    start_mb_slice(dut, sx, sy, first);
    dut.pred_mode = 2;
    set_block_and_wait(dut, 0);

    check_bool("slice_boundary_top_semantic_unavailable", dut.ctx_mb_avail_top, false);
    check_bool("slice_boundary_left_semantic_unavailable", dut.ctx_mb_avail_left, false);
    check_bool("slice_boundary_topleft_semantic_unavailable", dut.ctx_mb_avail_topleft, false);
    check_bool("slice_boundary_topright_semantic_unavailable", dut.ctx_mb_avail_topright, false);
    check_u8("slice_boundary_nb_topleft", 0, dut.ctx_nb_topleft, 128);
    for (int i = 0; i < 16; ++i) {
        check_u8("slice_boundary_nb_top", i, dut.ctx_nb_top[i], 128);
        check_u8("slice_boundary_nb_left", i, dut.ctx_nb_left[i], 128);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::printf("%s\n", "SCOPE_PLACEHOLDER");
    Vh264_intra_nb_ctx_tb dut;
    dut.clk = 0;
    dut.reset = 1;
    dut.mb_start = 0;
    dut.block_valid = 0;
    dut.mb_commit = 0;
    dut.mb_width = 39;
    dut.first_mb_in_slice = 0;
    dut.pred_mode = 2;
    tick(dut);
    tick(dut);
    dut.reset = 0;
    tick(dut);

    start_mb(dut, 0, 0);
    check_edge_mb00(dut);
    commit_mb(dut, 0, 0);
    ++committed_mbs;

    start_mb(dut, 1, 0);
    check_mb1_row0_left(dut);
    commit_mb(dut, 1, 0);
    ++committed_mbs;

    for (int x = 2; x < 39; ++x) {
        start_mb(dut, x, 0);
        commit_mb(dut, x, 0);
        ++committed_mbs;
    }

    start_mb(dut, 0, 1);
    check_row1_above_and_corner(dut);
    commit_mb(dut, 0, 1);
    ++committed_mbs;

    start_mb(dut, 1, 1);
    check_mb11_both(dut);
    commit_mb(dut, 1, 1);
    ++committed_mbs;

    for (int x = 2; x < 37; ++x) {
        start_mb(dut, x, 1);
        commit_mb(dut, x, 1);
        ++committed_mbs;
    }
    start_mb(dut, 37, 1);
    check_above_right(dut);
    commit_mb(dut, 37, 1);
    ++committed_mbs;

    start_mb(dut, 38, 1);
    check_right_edge_above_right_unavailable(dut);
    commit_mb(dut, 38, 1);
    ++committed_mbs;

    for (int y = 2; y < 30; ++y) {
        for (int x = 0; x < 39; ++x) {
            start_mb(dut, x, y);
            if (x == 38 && y == 29)
                check_last_mb(dut);
            commit_mb(dut, x, y);
            ++committed_mbs;
        }
    }

    check_slice_boundary_masks_storage(dut);

    if (failures) {
        std::fprintf(stderr, "h264_intra_nb_ctx RTL check FAILED: failures=%d checks=%d\n", failures, checks);
        return 1;
    }
    if (committed_mbs != 1170) {
        std::fprintf(stderr, "FAIL h264_intra_nb_ctx: committed_mbs=%d want=1170\n", committed_mbs);
        return 1;
    }
    std::printf("h264_intra_nb_ctx RTL check PASS: checks=%d full_width_mbs=39 full_height_mbs=30 denominator_mbs=%d pre_deblock_tap=1 slice_boundary_semantic=1\n", checks, committed_mbs);
    return 0;
}
'''


def write_harness(path: Path, scope: str) -> None:
    path.write_text(HARNESS.replace("SCOPE_PLACEHOLDER", scope.replace('\\', '\\\\').replace('"', '\\"')))


def run(cmd: list[str], *, cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def build_and_run(build_dir: Path, define: str = "") -> subprocess.CompletedProcess[str]:
    build_dir.mkdir(parents=True, exist_ok=True)
    cpp = build_dir / "h264_intra_nb_ctx_main.cpp"
    write_harness(cpp, GREEN_SCOPE)
    cmd = [
        str(RUN_VERILATOR), "--cc", "--exe", "--build",
        "--top-module", "h264_intra_nb_ctx_tb",
        "--Mdir", str(build_dir),
        "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
        "-CFLAGS", "-std=c++17 -O2",
    ]
    if define:
        cmd.append(define)
    cmd += [
        str(RTL / "h264_intra_nb_ctx.sv"),
        str(RTL / "h264_intra_pred.sv"),
        str(TB),
        str(cpp),
    ]
    proc = run(cmd)
    if proc.returncode != 0:
        return proc
    exe = build_dir / "Vh264_intra_nb_ctx_tb"
    return run([str(exe)])


def require_expected_red(red_id: str, proc: subprocess.CompletedProcess[str]) -> None:
    check = subprocess.run(
        [sys.executable, str(EXPECTED_RED), red_id, str(proc.returncode)],
        cwd=ROOT,
        text=True,
        input=proc.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    sys.stdout.write(proc.stdout)
    sys.stdout.write(check.stdout)
    if check.returncode != 0:
        raise SystemExit(check.returncode)


def main() -> int:
    print(GREEN_SCOPE)
    if not RUN_VERILATOR.exists():
        print("RTL SIM ERROR: run_verilator.sh missing; refusing to report PASS without running simulation.", file=sys.stderr)
        return 3
    for path in [RTL / "h264_intra_nb_ctx.sv", RTL / "h264_intra_pred.sv", TB]:
        if not path.exists():
            print(f"RTL SIM ERROR: missing required file: {path}", file=sys.stderr)
            return 2

    green = build_and_run(ROOT / "build/verilator/h264_intra_nb_ctx")
    sys.stdout.write(green.stdout)
    if green.returncode != 0:
        return green.returncode

    red = build_and_run(
        ROOT / "build/verilator/h264_intra_nb_ctx_fault_stub_neighbors",
        "+define+H264_INTRA_NB_CTX_FAULT_STUB_NEIGHBORS",
    )
    require_expected_red("h264_intra_nb_ctx_stub_neighbors", red)

    red_chroma = build_and_run(
        ROOT / "build/verilator/h264_intra_nb_ctx_fault_swap_chroma_uv",
        "+define+H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV",
    )
    require_expected_red("h264_intra_nb_ctx_swap_chroma_uv", red_chroma)

    red_edge = build_and_run(
        ROOT / "build/verilator/h264_intra_nb_ctx_fault_edge_available",
        "+define+H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE",
    )
    require_expected_red("h264_intra_nb_ctx_edge_available", red_edge)

    print("OK h264_intra_nb_ctx red-checks: stub neighbours, swapped chroma U/V, and false edge/slice availability all failed the scoreboard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
