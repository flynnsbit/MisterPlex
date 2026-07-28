#!/usr/bin/env python3
"""RTL gate for h264_rbsp_window, the decoder's random-access RBSP view."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN_VERILATOR = ROOT / "scripts/run_verilator.sh"
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
TB = ROOT / "tests/unit/rtl/h264_rbsp_window_tb.sv"
EXPECTED_RED = ROOT / "tests/unit/expected_red.py"

GREEN_SCOPE = (
    "Scope: h264_rbsp_window byte-serial slice capture and 64-byte random-access window; "
    "aligned and unaligned bases, two-row lane wrap, window_base/byte_out pairing, "
    "zero-fill plus sticky underflow past bytes_captured (including stale residue from a "
    "previous slice), sticky overflow past BUF_BYTES, and slice_complete. "
    "It does not cover nalu_scanner slice capture, DDR ring delivery, entropy parsing, "
    "residual math, reconstruction, or HDMI presentation."
)

HARNESS = r'''#include "Vh264_rbsp_window_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static int failures = 0;
static int checks = 0;

static uint8_t old_byte(int i) { return static_cast<uint8_t>(((i * 13) + 211) & 0xff) | 1; }
static uint8_t new_byte(int i) { return static_cast<uint8_t>((i * 29 + (i >> 6) * 13 + 5) & 0xff); }

static void tick(Vh264_rbsp_window_tb& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

static void check_u8(const char* what, int idx, int got, int want) {
    ++checks;
    if (got != want) {
        std::fprintf(stderr, "FAIL h264_rbsp_window: %s[%d] got=%u want=%u\n", what, idx, got, want);
        ++failures;
    }
}

static void check_u16(const char* what, int got, int want) {
    ++checks;
    if (got != want) {
        std::fprintf(stderr, "FAIL h264_rbsp_window: %s got=%u want=%u\n", what, got, want);
        ++failures;
    }
}

static void check_bool(const char* what, bool got, bool want) {
    ++checks;
    if (got != want) {
        std::fprintf(stderr, "FAIL h264_rbsp_window: %s got=%d want=%d\n", what, got ? 1 : 0, want ? 1 : 0);
        ++failures;
    }
}

static void feed(Vh264_rbsp_window_tb& dut, const std::vector<uint8_t>& bytes, bool end) {
    dut.cap_clear = 1;
    tick(dut);
    dut.cap_clear = 0;
    tick(dut);
    for (size_t i = 0; i < bytes.size(); ++i) {
        dut.cap_en = 1;
        dut.cap_data = bytes[i];
        tick(dut);
    }
    dut.cap_en = 0;
    dut.cap_data = 0;
    dut.cap_end = end ? 1 : 0;
    tick(dut);
    dut.cap_end = 0;
    tick(dut);
}

// Request a window and settle. The module registers (req_lane, base) one cycle
// and byte_out the next, so two ticks after request_valid the pair is stable.
static void request(Vh264_rbsp_window_tb& dut, int base) {
    dut.request_offset = static_cast<uint16_t>(base);
    dut.request_valid = 1;
    tick(dut);
    dut.request_valid = 0;
    tick(dut);
    tick(dut);
}

static void check_window(Vh264_rbsp_window_tb& dut, int base, const std::vector<uint8_t>& data) {
    request(dut, base);
    char what[64];
    std::snprintf(what, sizeof(what), "base%d_window_base", base);
    check_u16(what, dut.window_base, base);
    for (int i = 0; i < 64; ++i) {
        size_t off = static_cast<size_t>(base) + static_cast<size_t>(i);
        int want = off < data.size() ? data[off] : 0;
        std::snprintf(what, sizeof(what), "base%d_byte", base);
        check_u8(what, i, dut.byte_out[i], want);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::printf("%s\n", SCOPE_TEXT);
    Vh264_rbsp_window_tb dut;

    dut.reset = 1;
    dut.cap_clear = 0;
    dut.cap_en = 0;
    dut.cap_data = 0;
    dut.cap_end = 0;
    dut.request_valid = 0;
    dut.request_offset = 0;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut.reset = 0;
    tick(dut);

    check_bool("reset_window_valid", dut.window_valid != 0, false);

    // A full previous slice, so lane RAM rows past the next slice's length hold
    // real residue. Without this, "zero past bytes_captured" would pass on an
    // implementation that simply read uninitialised (zero) memory.
    std::vector<uint8_t> old_slice(1024);
    for (int i = 0; i < 1024; ++i) old_slice[i] = old_byte(i);
    feed(dut, old_slice, true);
    check_u16("old_bytes_captured", dut.bytes_captured, 1024);
    check_bool("old_overflow", dut.overflow != 0, false);

    // The slice under test: 1000 bytes, so offsets 1000..1023 still hold residue.
    std::vector<uint8_t> data(1000);
    for (int i = 0; i < 1000; ++i) data[i] = new_byte(i);
    feed(dut, data, true);
    check_u16("bytes_captured", dut.bytes_captured, 1000);
    check_bool("slice_complete", dut.slice_complete != 0, true);
    check_bool("overflow_clear", dut.overflow != 0, false);
    check_bool("underflow_clear", dut.underflow != 0, false);
    check_bool("window_valid", dut.window_valid != 0, true);

    // Aligned, unaligned, row-crossing and lane-63 bases.
    const int bases[] = {0, 1, 63, 64, 65, 100, 127, 128, 500, 511, 936};
    for (int b : bases) check_window(dut, b, data);

    // Tail: lanes past bytes_captured must be zero, not previous-slice residue.
    check_window(dut, 960, data);
    check_bool("tail_underflow_still_clear", dut.underflow != 0, false);

    // Idle cycles must not walk the window backwards.
    request(dut, 200);
    for (int i = 0; i < 8; ++i) tick(dut);
    check_u16("held_window_base", dut.window_base, 200);
    for (int i = 0; i < 64; ++i) check_u8("held_byte", i, dut.byte_out[i], data[200 + i]);

    // Wholly out of range: zeros plus sticky underflow.
    request(dut, 2000);
    check_bool("underflow_sticky", dut.underflow != 0, true);
    for (int i = 0; i < 64; ++i) check_u8("oob_byte", i, dut.byte_out[i], 0);
    request(dut, 0);
    check_bool("underflow_remains_sticky", dut.underflow != 0, true);

    // Overflow: a slice larger than BUF_BYTES clamps and flags.
    std::vector<uint8_t> big(1100);
    for (int i = 0; i < 1100; ++i) big[i] = new_byte(i + 7);
    feed(dut, big, true);
    check_u16("overflow_bytes_captured", dut.bytes_captured, 1024);
    check_bool("overflow_flag", dut.overflow != 0, true);
    check_bool("overflow_clears_underflow", dut.underflow != 0, false);

    if (failures != 0) {
        std::fprintf(stderr, "h264_rbsp_window RTL check FAILED: %d/%d checks failed\n", failures, checks);
        return 1;
    }
    std::printf("OK h264_rbsp_window: %d checks passed (capture, %d window bases, tail zero-fill, underflow, overflow)\n",
                checks, static_cast<int>(sizeof(bases) / sizeof(bases[0])) + 2);
    return 0;
}
'''


def write_harness(path: Path, scope: str) -> None:
    escaped = scope.replace("\\", "\\\\").replace('"', '\\"')
    path.write_text(f'#define SCOPE_TEXT "{escaped}"\n' + HARNESS)


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def build_and_run(build_dir: Path, define: str = "") -> subprocess.CompletedProcess[str]:
    build_dir.mkdir(parents=True, exist_ok=True)
    cpp = build_dir / "h264_rbsp_window_main.cpp"
    write_harness(cpp, GREEN_SCOPE)
    cmd = [
        str(RUN_VERILATOR), "--cc", "--exe", "--build",
        "--top-module", "h264_rbsp_window_tb",
        "--Mdir", str(build_dir),
        "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
        "-CFLAGS", "-std=c++17 -O2",
    ]
    if define:
        cmd.append(define)
    cmd += [
        str(RTL / "h264_rbsp_window.sv"),
        str(TB),
        str(cpp),
    ]
    proc = run(cmd)
    if proc.returncode != 0:
        return proc
    exe = build_dir / "Vh264_rbsp_window_tb"
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
    for path in [RTL / "h264_rbsp_window.sv", TB]:
        if not path.exists():
            print(f"RTL SIM ERROR: missing required file: {path}", file=sys.stderr)
            return 2

    green = build_and_run(ROOT / "build/verilator/h264_rbsp_window")
    sys.stdout.write(green.stdout)
    if green.returncode != 0:
        return green.returncode

    red_wrap = build_and_run(
        ROOT / "build/verilator/h264_rbsp_window_fault_no_wrap",
        "+define+H264_RBSP_WINDOW_FAULT_NO_WRAP",
    )
    require_expected_red("h264_rbsp_window_no_wrap", red_wrap)

    red_tail = build_and_run(
        ROOT / "build/verilator/h264_rbsp_window_fault_stale_tail",
        "+define+H264_RBSP_WINDOW_FAULT_STALE_TAIL",
    )
    require_expected_red("h264_rbsp_window_stale_tail", red_tail)

    print("OK h264_rbsp_window red-checks: single-row windows and stale-residue tails both failed the scoreboard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
