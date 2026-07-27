#!/usr/bin/env python3
"""Fast source-level guards for MiSTerPlex RTL/host ABI invariants."""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PRESENT_CORE = Path(os.environ.get("PRESENT_CORE", ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"))
PLEX_SV = Path(os.environ.get("PLEX_SV", ROOT / "fpga/Plex_MiSTer/Plex.sv"))
DDRAM_FRAME_RD = Path(
    os.environ.get("DDRAM_FRAME_RD", ROOT / "fpga/Plex_MiSTer/rtl/ddram_frame_rd.sv")
)
FPGA_SPI_HPP = Path(os.environ.get("FPGA_SPI_HPP", ROOT / "arm/misterplexd/fpga_spi.hpp"))
FPGA_SPI_CPP = Path(os.environ.get("FPGA_SPI_CPP", ROOT / "arm/misterplexd/fpga_spi.cpp"))
INPUT_MAILBOX_HPP = Path(
    os.environ.get("INPUT_MAILBOX_HPP", ROOT / "host/libmisterplex/input_mailbox.hpp")
)
STATUS_TELEMETRY_HPP = Path(
    os.environ.get("STATUS_TELEMETRY_HPP", ROOT / "host/libmisterplex/status_telemetry.hpp")
)


def read(path: Path) -> str:
    try:
        return path.read_text()
    except OSError as e:
        fail(f"could not read {path}: {e}")


def strip_comments(text: str) -> str:
    out: list[str] = []
    i = 0
    in_str = False
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ""
        if in_str:
            out.append(c)
            if c == "\\" and n:
                out.append(n)
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif c == "/" and n == "/":
            while i < len(text) and text[i] != "\n":
                i += 1
            out.append("\n")
        elif c == "/" and n == "*":
            i += 2
            while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def norm(s: str) -> str:
    return re.sub(r"\s+", "", s)


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def check(cond: bool, msg: str) -> None:
    if not cond:
        fail(msg)


def parse_num(expr: str) -> int:
    expr = expr.strip().rstrip(";").replace("_", "")
    m = re.search(r"(\d+)?'([hHdD])([0-9a-fA-F]+)", expr)
    if m:
        return int(m.group(3), 16 if m.group(2).lower() == "h" else 10)
    m = re.search(r"0x([0-9a-fA-F]+)", expr, re.I)
    if m:
        return int(m.group(1), 16)
    m = re.search(r"([0-9]+)", expr)
    if m:
        return int(m.group(1), 10)
    raise ValueError(expr)


def sv_const(text: str, name: str) -> int:
    m = re.search(
        rf"(?:localparam|parameter)(?:\s+\w+)?(?:\s*\[[^\]]+\])?\s+{re.escape(name)}\s*=\s*([^,\n;)]+)",
        text,
    )
    if not m:
        fail(
            f"{name} is missing from RTL. This is part of the host/FPGA contract; "
            "restore the fixed mailbox/scanout parameter or update the matching host side and tests."
        )
    return parse_num(m.group(1))


def cpp_const_map(text: str) -> dict[str, str]:
    return {
        m.group(1): m.group(2).strip()
        for m in re.finditer(r"constexpr\s+(?:\w+\s+)+(\w+)\s*=\s*([^;]+);", text)
    }


def cpp_const(text: str, name: str) -> int:
    consts = cpp_const_map(text)
    if name not in consts:
        fail(
            f"{name} is missing from host constants. The ARM daemon and RTL must agree on "
            "DDR mailbox addresses/magic; restore the constant or update both sides together."
        )
    seen: set[str] = set()

    def resolve(expr: str) -> int:
        expr = expr.strip()
        if re.fullmatch(r"\w+", expr) and expr in consts:
            if expr in seen:
                fail(f"host constant alias cycle while resolving {name}")
            seen.add(expr)
            return resolve(consts[expr])
        return parse_num(expr)

    return resolve(consts[name])


def check_present_core() -> None:
    text = strip_comments(read(PRESENT_CORE))
    de_lag = sv_const(text, "DE_LAG")
    check(
        de_lag == 3,
        f"present_core DE_LAG is {de_lag}, expected 3. DE_LAG aligns delayed HBlank/HSync "
        "to the frame_store pixel pipeline; changing it can reintroduce the user-visible "
        "1-pixel edge wrap. If pipeline latency changed, re-run the G-VID1 edge-check "
        "simulation/hardware sweep and update this test with the new measured value.",
    )

    assigns = re.findall(r"\bstore_x\s*<=\s*([^;]+);", text)
    rhs = [norm(a) for a in assigns]
    check(
        "store_x_clamped" in rhs,
        "present_core no longer assigns store_x <= store_x_clamped on ce_pix. The edge-wrap "
        "fix depends on store_x following the clamped counter through blank/overhang pixels.",
    )
    zero_assigns = [x for x in rhs if x in {"10'd0", "0", "10'h0"}]
    check(
        len(zero_assigns) == 1 and all(x in {"10'd0", "0", "10'h0", "store_x_clamped"} for x in rhs),
        "present_core store_x has a non-reset or extra zero assignment. Do not reset store_x "
        "during blank time: that handed source column 0 to delayed right-edge pixels and caused "
        "the visible 1-pixel wrap. Keep only reset=>0 and ce_pix=>store_x_clamped.",
    )
    check(
        not any("in_content" in x or "?" in x for x in rhs),
        "present_core store_x assignment is conditional on content/blank. The G-VID1 fix requires "
        "no blank-time store_x reset; store_x must follow store_x_clamped on every ce_pix.",
    )

    nt = norm(text)
    check(
        "past_last_row=(py>=10'd240)" in nt and "store_y_clamped=past_last_row?10'd239:py" in nt,
        "present_core past_last_row clamp is missing. It prevents fetching row 240 and stops the "
        "241st-row/bottom-edge artifact; restore past_last_row and store_y_clamped.",
    )
    check(
        "vb_d=vb|past_last_row" in nt,
        "present_core VBlank no longer includes past_last_row. The bottom-edge fix blanks rows "
        "past source row 239; restore `vb_d = vb | past_last_row` or re-verify G-VID1.",
    )
    print("PASS present_core G-VID1 scanout invariants")


def check_phase_a_surface() -> None:
    text = strip_comments(read(PLEX_SV))
    strings = " ".join(re.findall(r'"([^"]*)"', text))
    for entry in ("F1,raw", "F2,raw", "F3,264"):
        check(
            entry in strings,
            f"Plex.sv CONF_STR missing `{entry}`. That drops a Phase A shipping file slot; "
            "restore F1 raw frame, F2 raw audio, and F3 H.264 annex-B menu entries.",
        )
    for label in ("Play/Pause", "Stop", "Skip Fwd", "Skip Back"):
        check(
            label in strings and "J1," in strings,
            f"Plex.sv J1 controller mapper missing `{label}`. Phase A playback controls must "
            "remain exposed to MiSTer's mapper; restore the J1 Play/Pause/Stop/Skip labels.",
        )
    for token, why in (
        (r"\bps2_key\b", "keyboard playback controls"),
        (r"\bjoystick_0\b", "controller playback controls"),
        (r"\.ps2_key\s*\(\s*ps2_key\s*\)", "hps_io PS/2 wiring"),
        (r"\.joystick_0\s*\(\s*joystick_0\s*\)", "hps_io joystick wiring"),
        (r"joy_rise\s*\[\s*4\s*\]", "J1 Play/Pause decode"),
        (r"joy_rise\s*\[\s*5\s*\]", "J1 Stop decode"),
        (r"joy_rise\s*\[\s*6\s*\]", "J1 Skip Fwd decode"),
        (r"joy_rise\s*\[\s*7\s*\]", "J1 Skip Back decode"),
        (r"ps2_code\s*==\s*8'h29", "Space Play/Pause decode"),
        (r"ps2_code\s*==\s*8'h76", "Esc Stop decode"),
        (r"ps2_code\s*==\s*8'h74", "Right-arrow Skip Fwd decode"),
        (r"ps2_code\s*==\s*8'h6B", "Left-arrow Skip Back decode"),
    ):
        check(
            re.search(token, text) is not None,
            f"Plex.sv missing {why}. Phase A requires joystick_0 and ps2_key command decode; "
            "restore the hps_io wiring and playback command decoder.",
        )
    print("PASS Plex.sv Phase A feature surface")


def check_mailboxes() -> None:
    rtl = strip_comments(read(DDRAM_FRAME_RD))
    fpga_spi = strip_comments(read(FPGA_SPI_HPP))
    input_h = strip_comments(read(INPUT_MAILBOX_HPP))
    host = fpga_spi + "\n" + input_h
    cases = [
        ("PLXS", "status", "MAILBOX_PHYS", "MAGIC_S", "kDdrMailboxPhys", "kDdrMailboxMagic", 0x3007F100, 0x504C5853),
        ("PLXI", "input", "INPUT_MAILBOX_PHYS", "MAGIC_I", "kInputMailboxPhys", "kInputMailboxMagic", 0x3007F108, 0x504C5849),
        ("PLXM", "memtest", "MEMTEST_MAILBOX_PHYS", "MAGIC_M", "kMemtestMailboxPhys", "kMemtestMailboxMagic", 0x3007F110, 0x504C584D),
        ("PLXF", "underrun", "UNDERRUN_MAILBOX_PHYS", "MAGIC_F", "kUnderrunMailboxPhys", "kUnderrunMailboxMagic", 0x3007F118, 0x504C5846),
    ]
    for magic, label, rtl_addr, rtl_magic, host_addr, host_magic, expected_addr, expected_magic in cases:
        ra = sv_const(rtl, rtl_addr)
        rm = sv_const(rtl, rtl_magic)
        ha = cpp_const(host, host_addr)
        hm = cpp_const(host, host_magic)
        check(
            ra == ha == expected_addr and rm == hm == expected_magic,
            f"DDR mailbox `{magic}` {label} mismatch: RTL {rtl_addr}=0x{ra:08X}/{rtl_magic}=0x{rm:08X}, "
            f"host {host_addr}=0x{ha:08X}/{host_magic}=0x{hm:08X}, expected "
            f"0x{expected_addr:08X}/0x{expected_magic:08X}. The ARM daemon reads fixed DDR offsets; "
            "a silent host/FPGA mismatch breaks controls/status with no compile error. Update both "
            "sides together and adjust this test only with an ABI migration note.",
        )
    print("PASS DDR mailbox host/RTL ABI constants")


def check_status_telemetry() -> None:
    plex = strip_comments(read(PLEX_SV))
    fpga_spi = strip_comments(read(FPGA_SPI_CPP))
    status_h = strip_comments(read(STATUS_TELEMETRY_HPP))
    nt = norm(plex)
    expected = {
        "kResidualDcBitLo": 96,
        "kResidualDcBitHi": 103,
        "kResidualCsumBitLo": 104,
        "kResidualCsumBitHi": 111,
        "kStreamBytesBitLo": 112,
        "kStreamBytesBitHi": 127,
        "kResidualDcByte": 12,
        "kResidualCsumByte": 13,
        "kStreamBytesLoByte": 14,
        "kStreamBytesHiByte": 15,
    }
    for name, value in expected.items():
        got = cpp_const(status_h, name)
        check(
            got == value,
            f"status_telemetry.hpp {name}={got}, expected {value}. raw[13] is the residual "
            "checksum ABI byte; moving it requires updating Plex.sv, parseCoreStatus, "
            "tests/parse_res_csum_status.py, and a hardware re-gate note.",
        )

    checks = [
        (
            r"status_telem_r\s*\[\s*103\s*:\s*96\s*\]\s*<=\s*st_res_word_sticky\s*\[\s*7\s*:\s*0\s*\]",
            "Plex.sv no longer packs residual_dc sticky into status[103:96]/raw[12]. "
            "res_dc=-24 is the adjacent control proving the residual latch fired.",
        ),
        (
            r"status_telem_r\s*\[\s*111\s*:\s*104\s*\]\s*<=\s*st_res_word_sticky\s*\[\s*15\s*:\s*8\s*\]",
            "Plex.sv no longer packs residual_csum sticky into status[111:104]/raw[13]. "
            "If raw[13] is stream_bytes[7:0], repeated pushes walk by file_size%256 and "
            "P3-3l1 remains blocked. Restore csum at raw[13] or re-gate with a new ABI.",
        ),
        (
            r"status_telem_r\s*\[\s*127\s*:\s*112\s*\]\s*<=\s*stream_bytes_in\s*\[\s*15\s*:\s*0\s*\]",
            "Plex.sv no longer starts stream_bytes at status[127:112]/raw[14]. The old "
            "pre-3.3l-1 layout started stream_bytes at raw[13] and masqueraded as res_csum.",
        ),
    ]
    for pat, msg in checks:
        check(re.search(pat, plex) is not None, msg)
    check(
        "status_telem_r[127:104]<=stream_bytes_in" not in nt
        and "status_telem[127:104]=stream_bytes_in" not in nt,
        "Plex.sv appears to use the old alias layout status[127:104]=stream_bytes_in. "
        "That leaves residual_dc at raw[12] but makes raw[13] the byte-counter low byte, "
        "exactly the +file_size%256 failure signature.",
    )
    check(
        "status_telem_masked={status_telem_r[127:112],st_res_word_sticky[15:8],st_res_word_sticky[7:0],status_telem_r[95:0]}" in nt,
        "Plex.sv residual mask no longer structurally forces {stream, csum, dc}. This mask "
        "prevents residual_csum from aliasing live stream bytes; restore it or add an "
        "equivalent guarded pack with a simulation proof.",
    )
    check(
        "raw[kResidualCsumByte]" in fpga_spi
        and "raw[kStreamBytesLoByte]" in fpga_spi
        and "raw[kStreamBytesHiByte]" in fpga_spi,
        "parseCoreStatus is not using the shared status_telemetry byte constants. The host "
        "must decode raw[13] as residual_csum and raw[14:15] as stream bytes; restore the "
        "shared constants to avoid silent host/RTL ABI drift.",
    )
    print("PASS residual status telemetry ABI (raw[12]=dc raw[13]=csum raw[14]=stream_low)")


def main() -> int:
    check_present_core()
    check_phase_a_surface()
    check_mailboxes()
    check_status_telemetry()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
