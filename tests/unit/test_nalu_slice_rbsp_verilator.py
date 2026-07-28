#!/usr/bin/env python3
"""RTL gate: nalu_scanner full-slice RBSP port -> h264_rbsp_window."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN_VERILATOR = ROOT / "scripts/run_verilator.sh"
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
TB = ROOT / "tests/unit/rtl/nalu_slice_rbsp_tb.sv"
EXPECTED_RED = ROOT / "tests/unit/expected_red.py"

GREEN_SCOPE = (
    "Scope: nalu_scanner sl_rbsp_* full-slice capture into h264_rbsp_window over a synthetic "
    "Annex-B stream (SPS, PPS, IDR slice of 1500 RBSP bytes, then a P slice). Covers "
    "emulation-prevention byte removal past the 96-byte slice-header window, slice length "
    "beyond that window, per-slice reset of the captured buffer, and window reads at "
    "aligned/unaligned/tail offsets. It does not cover bitstream_fifo, DDR ring delivery, "
    "slice header semantics, entropy decode, reconstruction, or presentation."
)

HARNESS = r'''#include "Vnalu_slice_rbsp_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static int failures = 0;
static int checks = 0;

static void tick(Vnalu_slice_rbsp_tb& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

static void check_u32(const char* what, unsigned got, unsigned want) {
    ++checks;
    if (got != want) {
        std::fprintf(stderr, "FAIL nalu_slice_rbsp: %s got=%u want=%u\n", what, got, want);
        ++failures;
    }
}

static void check_u8(const char* what, int idx, int got, int want) {
    ++checks;
    if (got != want) {
        std::fprintf(stderr, "FAIL nalu_slice_rbsp: %s[%d] got=%u want=%u\n", what, idx, got, want);
        ++failures;
    }
}

// Models bitstream_fifo: rd_data is registered, so the byte a read consumes
// becomes visible one cycle after rd_en, and rd_empty reflects bytes remaining.
// nalu_scanner is built for exactly that contract (data_valid <= rd_en &&
// !rd_empty, then rd_data is used the following cycle).
static void feed(Vnalu_slice_rbsp_tb& dut, const std::vector<uint8_t>& bytes) {
    size_t next = 0;
    int guard = 0;
    while ((next < bytes.size() || dut.in_valid) && guard++ < 500000) {
        dut.in_valid = (next < bytes.size()) ? 1 : 0;
        dut.eval();
        const bool consumed = (dut.rd_en_o != 0) && (next < bytes.size());
        tick(dut);
        if (consumed)
            dut.in_data = bytes[next++];
    }
    dut.in_valid = 0;
    dut.in_data = 0;
    for (int k = 0; k < 8; ++k) tick(dut);
}

static void request(Vnalu_slice_rbsp_tb& dut, int base) {
    dut.request_offset = static_cast<uint16_t>(base);
    dut.request_valid = 1;
    tick(dut);
    dut.request_valid = 0;
    tick(dut);
    tick(dut);
}

static void check_window(Vnalu_slice_rbsp_tb& dut, int base, const std::vector<uint8_t>& rbsp,
                         const char* tag) {
    request(dut, base);
    char what[96];
    std::snprintf(what, sizeof(what), "%s_base%d_window_base", tag, base);
    check_u32(what, dut.window_base, static_cast<unsigned>(base));
    for (int i = 0; i < 64; ++i) {
        size_t off = static_cast<size_t>(base) + static_cast<size_t>(i);
        int want = off < rbsp.size() ? rbsp[off] : 0;
        std::snprintf(what, sizeof(what), "%s_base%d_byte", tag, base);
        check_u8(what, i, dut.byte_out[i], want);
    }
}

// Annex-B escape: insert 0x03 after any 00 00 followed by a byte <= 0x03.
static std::vector<uint8_t> escape(const std::vector<uint8_t>& rbsp) {
    std::vector<uint8_t> out;
    int zeros = 0;
    for (uint8_t b : rbsp) {
        if (zeros >= 2 && b <= 0x03) {
            out.push_back(0x03);
            zeros = 0;
        }
        out.push_back(b);
        zeros = (b == 0x00) ? zeros + 1 : 0;
    }
    return out;
}

static void appendNal(std::vector<uint8_t>& stream, uint8_t header,
                      const std::vector<uint8_t>& rbsp) {
    stream.push_back(0x00);
    stream.push_back(0x00);
    stream.push_back(0x00);
    stream.push_back(0x01);
    stream.push_back(header);
    const std::vector<uint8_t> esc = escape(rbsp);
    stream.insert(stream.end(), esc.begin(), esc.end());
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::printf("%s\n", SCOPE_TEXT);
    Vnalu_slice_rbsp_tb dut;

    dut.reset = 1;
    dut.in_valid = 0;
    dut.in_data = 0;
    dut.request_valid = 0;
    dut.request_offset = 0;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut.reset = 0;
    tick(dut);

    // 1500 bytes: well past the 96-byte slice-header window, with emulation
    // sequences both inside and outside it. If EPB state were gated on the
    // header window, every 00 00 03 after byte 96 would survive into the RBSP.
    std::vector<uint8_t> idr(1500);
    for (size_t i = 0; i < idr.size(); ++i)
        idr[i] = static_cast<uint8_t>((i * 37 + 11) & 0xff);
    const int epb_at[] = {20, 40, 300, 700, 1400};
    for (int at : epb_at) {
        idr[at] = 0x00;
        idr[at + 1] = 0x00;
        idr[at + 2] = 0x01;  // forces an inserted 0x03 in the escaped stream
    }

    std::vector<uint8_t> pslice(200);
    for (size_t i = 0; i < pslice.size(); ++i)
        pslice[i] = static_cast<uint8_t>((i * 53 + 7) & 0xff);

    std::vector<uint8_t> stream;
    appendNal(stream, 0x67, std::vector<uint8_t>{0x42, 0x00, 0x1e, 0xaa});  // SPS
    appendNal(stream, 0x68, std::vector<uint8_t>{0xce, 0x3c, 0x80});        // PPS
    appendNal(stream, 0x65, idr);                                          // IDR slice
    feed(dut, stream);

    check_u32("idr_nalu_count", dut.nalu_count, 3);
    check_u32("idr_has_idr", dut.has_idr ? 1 : 0, 1);
    // The whole slice is captured, not the 96-byte header window. The scanner
    // may emit up to two trailing zeros of the following start code; there is
    // no following NAL here, so expect the slice exactly.
    check_u32("idr_bytes_captured", dut.bytes_captured, static_cast<unsigned>(idr.size()));
    check_u32("idr_overflow", dut.overflow ? 1 : 0, 0);

    for (int base : {0, 1, 63, 64, 95, 96, 97, 300, 1023, 1436})
        check_window(dut, base, idr, "idr");
    check_u32("idr_underflow_clear", dut.underflow ? 1 : 0, 0);

    // A second slice must replace the buffer, not append to it: cap_clear has
    // to fire per slice NAL or offset 0 would still return the IDR.
    std::vector<uint8_t> stream2;
    appendNal(stream2, 0x41, pslice);
    feed(dut, stream2);
    check_u32("p_bytes_captured", dut.bytes_captured, static_cast<unsigned>(pslice.size()));
    for (int base : {0, 7, 64, 136})
        check_window(dut, base, pslice, "p");

    if (failures != 0) {
        std::fprintf(stderr, "nalu_slice_rbsp RTL check FAILED: %d/%d checks failed\n",
                     failures, checks);
        return 1;
    }
    std::printf("OK nalu_slice_rbsp: %d checks passed (idr=%u bytes with %d EPBs, p=%u bytes)\n",
                checks, static_cast<unsigned>(idr.size()),
                static_cast<int>(sizeof(epb_at) / sizeof(epb_at[0])),
                static_cast<unsigned>(pslice.size()));
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
    cpp = build_dir / "nalu_slice_rbsp_main.cpp"
    write_harness(cpp, GREEN_SCOPE)
    cmd = [
        str(RUN_VERILATOR), "--cc", "--exe", "--build",
        "--top-module", "nalu_slice_rbsp_tb",
        "--Mdir", str(build_dir),
        "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
        "-CFLAGS", "-std=c++17 -O2",
    ]
    if define:
        cmd.append(define)
    cmd += [
        str(RTL / "nalu_scanner.sv"),
        str(RTL / "h264_rbsp_window.sv"),
        str(TB),
        str(cpp),
    ]
    proc = run(cmd)
    if proc.returncode != 0:
        return proc
    exe = build_dir / "Vnalu_slice_rbsp_tb"
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
    for path in [RTL / "nalu_scanner.sv", RTL / "h264_rbsp_window.sv", TB]:
        if not path.exists():
            print(f"RTL SIM ERROR: missing required file: {path}", file=sys.stderr)
            return 2

    green = build_and_run(ROOT / "build/verilator/nalu_slice_rbsp")
    sys.stdout.write(green.stdout)
    if green.returncode != 0:
        return green.returncode

    red = build_and_run(
        ROOT / "build/verilator/nalu_slice_rbsp_fault_96",
        "+define+NALU_SCANNER_FAULT_SLICE_RBSP_96",
    )
    require_expected_red("nalu_slice_rbsp_header_window_only", red)

    print("OK nalu_slice_rbsp red-check: restoring the 96-byte header window starves the window")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
