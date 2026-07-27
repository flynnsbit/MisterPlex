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
DDR_FRAME_LAYOUT_SVH = Path(
    os.environ.get(
        "DDR_FRAME_LAYOUT_SVH", ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
    )
)
FPGA_SPI_HPP = Path(os.environ.get("FPGA_SPI_HPP", ROOT / "arm/misterplexd/fpga_spi.hpp"))
FPGA_SPI_CPP = Path(os.environ.get("FPGA_SPI_CPP", ROOT / "arm/misterplexd/fpga_spi.cpp"))
DDR_FRAME_LAYOUT_HPP = Path(
    os.environ.get("DDR_FRAME_LAYOUT_HPP", ROOT / "host/libmisterplex/ddr_frame_layout.hpp")
)
MEDIA_PLAYER_CPP = Path(
    os.environ.get("MEDIA_PLAYER_CPP", ROOT / "arm/misterplexd/media_player.cpp")
)
MISTERPLEXD_MAIN_CPP = Path(
    os.environ.get("MISTERPLEXD_MAIN_CPP", ROOT / "arm/misterplexd/main.cpp")
)
DDR_BITSTREAM_READER = Path(
    os.environ.get(
        "DDR_BITSTREAM_READER", ROOT / "fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv"
    )
)
DDR_BITSTREAM_RING_HPP = Path(
    os.environ.get(
        "DDR_BITSTREAM_RING_HPP", ROOT / "host/libmisterplex/ddr_bitstream_ring.hpp"
    )
)
INPUT_MAILBOX_HPP = Path(
    os.environ.get("INPUT_MAILBOX_HPP", ROOT / "host/libmisterplex/input_mailbox.hpp")
)
STATUS_TELEMETRY_HPP = Path(
    os.environ.get("STATUS_TELEMETRY_HPP", ROOT / "host/libmisterplex/status_telemetry.hpp")
)
VALIDATE_PLAYBACK_HW_SH = Path(
    os.environ.get(
        "VALIDATE_PLAYBACK_HW_SH", ROOT / "scripts/validate_playback_controls_hw.sh"
    )
)
TEST_DDR_FRAME_SH = Path(
    os.environ.get("TEST_DDR_FRAME_SH", ROOT / "tests/hw/test_ddr_frame.sh")
)
HW_README_MD = Path(os.environ.get("HW_README_MD", ROOT / "tests/hw/README.md"))
PHASE3_DECODE_MD = Path(os.environ.get("PHASE3_DECODE_MD", ROOT / "docs/phase3-decode.md"))


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
        if "|" in expr:
            value = 0
            for part in expr.split("|"):
                value |= resolve(part)
            return value
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


def check_ddr_bitstream_ring() -> None:
    rtl = strip_comments(read(DDR_BITSTREAM_READER))
    host = strip_comments(read(DDR_BITSTREAM_RING_HPP))
    cases = [
        ("DATA_PHYS", "kDataPhys", 0x30100000),
        ("CTRL_PHYS", "kCtrlPhys", 0x30140000),
        ("READ_PHYS", "kReadPhys", 0x30140008),
        ("ERR_PHYS", "kErrPhys", 0x30140010),
        ("STAT0_PHYS", "kStat0Phys", 0x30140018),
        ("STAT1_PHYS", "kStat1Phys", 0x30140020),
        ("STAT2_PHYS", "kStat2Phys", 0x30140028),
        ("STAT3_PHYS", "kStat3Phys", 0x30140030),
        ("STAT4_PHYS", "kStat4Phys", 0x30140038),
        ("STAT5_PHYS", "kStat5Phys", 0x30140040),
        ("STAT6_PHYS", "kStat6Phys", 0x30140048),
        ("RING_BYTES", "kRingBytes", 262144),
        ("MAGIC_CTRL", "kCtrlMagic", 0x504C5842),
        ("MAGIC_READ", "kReadMagic", 0x504C5852),
        ("MAGIC_ERR", "kErrMagic", 0x504C5845),
        ("MAGIC_REC", "kRecordMagic", 0x504C584E),
        ("MAGIC_ST0", "kStat0Magic", 0x504C5854),
        ("MAGIC_ST1", "kStat1Magic", 0x504C5855),
        ("MAGIC_ST2", "kStat2Magic", 0x504C5856),
        ("MAGIC_ST3", "kStat3Magic", 0x504C5857),
        ("MAGIC_ST4", "kStat4Magic", 0x504C5859),
        ("MAGIC_ST5", "kStat5Magic", 0x504C585A),
        ("MAGIC_ST6", "kStat6Magic", 0x504C5851),
    ]
    for rtl_name, host_name, expected in cases:
        rv = sv_const(rtl, rtl_name)
        hv = cpp_const(host, host_name)
        check(
            rv == hv == expected,
            f"DDR bitstream ring ABI mismatch: RTL {rtl_name}=0x{rv:X}, "
            f"host {host_name}=0x{hv:X}, expected 0x{expected:X}.",
        )
    print("PASS DDR bitstream ring host/RTL ABI constants")


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
        "kReconSigBitLo": 112,
        "kReconSigBitHi": 119,
        "kReconDbgBitLo": 120,
        "kReconDbgBitHi": 127,
        "kResidualDcByte": 12,
        "kResidualCsumByte": 13,
        "kReconSigByte": 14,
        "kReconDbgByte": 15,
        "kReconSigMb0Block0": 0x3B,
        "kReconDbgMb0Block0": 0xF9,
    }
    for name, value in expected.items():
        got = cpp_const(status_h, name)
        check(
            got == value,
            f"status_telemetry.hpp {name}={got}, expected {value}. This is a status telemetry "
            "ABI position; moving it requires updating Plex.sv, parseCoreStatus, "
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
            r"status_telem_r\s*\[\s*119\s*:\s*112\s*\]\s*<=\s*st_recon_sig_sticky",
            "Plex.sv no longer packs reconstructed-pixel signature into status[119:112]/raw[14]. "
            "P3-3l2 hardware must publish an IDCT-sensitive signature; restore recon_sig at "
            "raw[14] or update the documented ABI and hardware gate.",
        ),
        (
            r"status_telem_r\s*\[\s*127\s*:\s*120\s*\]\s*<=\s*st_recon_dbg_sticky",
            "Plex.sv no longer keeps P3 recon RCA flags in status[127:120]/raw[15]. "
            "This byte distinguishes coefficient/dequant/IDCT/recon stages on silicon; "
            "restore it or update the documented RCA gate.",
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
        "status_telem_masked={st_recon_dbg_sticky,st_recon_sig_sticky,st_res_word_sticky[15:8],st_res_word_sticky[7:0],status_telem_r[95:0]}" in nt,
        "Plex.sv residual/recon mask no longer structurally forces {recon_dbg, recon_sig, csum, dc}. "
        "This mask prevents residual_csum/recon_sig from aliasing live stream bytes; restore it or "
        "add an equivalent guarded pack with a simulation proof.",
    )
    check(
        "raw[kResidualCsumByte]" in fpga_spi
        and "raw[kReconSigByte]" in fpga_spi
        and "raw[kReconDbgByte]" in fpga_spi,
        "parseCoreStatus is not using the shared status_telemetry byte constants. The host "
        "must decode raw[13] as residual_csum, raw[14] as recon_sig and raw[15] as recon debug; restore the "
        "shared constants to avoid silent host/RTL ABI drift.",
    )
    check(
        ".recon_sig(recon_sig)" in plex and ".recon_valid(recon_valid)" in plex,
        "Plex.sv/stream_path no longer wire decode_stub recon telemetry to status. "
        "P3-3l2 requires product RTL to publish an IDCT-sensitive signature.",
    )
    print("PASS residual/recon status telemetry ABI (raw[12]=dc raw[13]=csum raw[14]=recon_sig)")


def check_ddr_frame_layout_contract() -> None:
    host = strip_comments(read(DDR_FRAME_LAYOUT_HPP))
    rtl = strip_comments(read(DDR_FRAME_LAYOUT_SVH))
    pairs = [
        ("kPlex480pCodedWidth", "DDR_FRAME_CODED_WIDTH"),
        ("kPlex480pCodedHeight", "DDR_FRAME_CODED_HEIGHT"),
        ("kPlex480pDisplayWidth", "DDR_FRAME_DISPLAY_WIDTH"),
        ("kPlex480pDisplayHeight", "DDR_FRAME_DISPLAY_HEIGHT"),
        ("kPlex480pPresentedWidth", "DDR_FRAME_PRESENTED_WIDTH"),
        ("kPlex480pPresentedHeight", "DDR_FRAME_PRESENTED_HEIGHT"),
        ("kPlex480pCropLeft", "DDR_FRAME_CROP_LEFT"),
        ("kPlex480pCropRight", "DDR_FRAME_CROP_RIGHT"),
        ("kPlex480pCropTop", "DDR_FRAME_CROP_TOP"),
        ("kPlex480pCropBottom", "DDR_FRAME_CROP_BOTTOM"),
        ("kPlex480pPillarboxLeft", "DDR_FRAME_PILLARBOX_LEFT"),
        ("kPlex480pPillarboxRight", "DDR_FRAME_PILLARBOX_RIGHT"),
        ("kPlex480pRgb565LineQwords", "DDR_FRAME_RGB565_LINE_QWORDS"),
        ("kPlex480pYuvLumaLineQwords", "DDR_FRAME_YUV_LUMA_LINE_QWORDS"),
        ("kPlex480pYuvChromaLineQwords", "DDR_FRAME_YUV_CHROMA_LINE_QWORDS"),
        ("kPlex480pRgb565Bytes", "DDR_FRAME_RGB565_BYTES"),
        ("kPlex480pYuv420pBytes", "DDR_FRAME_YUV420P_BYTES"),
        ("kPlex480pYPlaneOffset", "DDR_FRAME_Y_PLANE_OFFSET"),
        ("kPlex480pUPlaneOffset", "DDR_FRAME_U_PLANE_OFFSET"),
        ("kPlex480pVPlaneOffset", "DDR_FRAME_V_PLANE_OFFSET"),
        ("kPlex480pYStrideBytes", "DDR_FRAME_Y_STRIDE_BYTES"),
        ("kPlex480pChromaStrideBytes", "DDR_FRAME_CHROMA_STRIDE_BYTES"),
        ("kPlex480pRgb565BankStride", "DDR_FRAME_RGB565_BANK_STRIDE"),
        ("kPlex480pYuv420pBankStride", "DDR_FRAME_YUV420P_BANK_STRIDE"),
        ("kPlex480pRgb565DoorbellPhys", "DDR_FRAME_RGB565_DOORBELL_PHYS"),
        ("kPlex480pYuv420pDoorbellPhys", "DDR_FRAME_YUV420P_DOORBELL_PHYS"),
        ("kYuv420BlackY", "DDR_FRAME_YUV_BLACK_Y"),
        ("kYuv420BlackU", "DDR_FRAME_YUV_BLACK_U"),
        ("kYuv420BlackV", "DDR_FRAME_YUV_BLACK_V"),
    ]
    for host_name, rtl_name in pairs:
        hv = cpp_const(host, host_name)
        rv = sv_const(rtl, rtl_name)
        check(
            hv == rv,
            f"DDR frame layout mismatch: {host_name}={hv} but {rtl_name}={rv}. "
            "ARM writer and RTL reader must agree on coded/display/presented geometry, "
            "burst qwords, bank stride, and doorbell addresses.",
        )
    check(
        cpp_const(host, "kPlex480pPillarboxLeft")
        + cpp_const(host, "kPlex480pDisplayWidth")
        + cpp_const(host, "kPlex480pPillarboxRight")
        == cpp_const(host, "kPlex480pPresentedWidth"),
        "480p pillarbox math no longer lands display width exactly in presented width",
    )
    print("PASS DDR frame layout ARM/RTL contract")


def check_yuv_ddr_writer_contract() -> None:
    media = strip_comments(read(MEDIA_PLAYER_CPP))
    main_cpp = strip_comments(read(MISTERPLEXD_MAIN_CPP))
    fpga_h = strip_comments(read(FPGA_SPI_HPP))
    fpga_cpp = strip_comments(read(FPGA_SPI_CPP))
    layout_h = strip_comments(read(DDR_FRAME_LAYOUT_HPP))
    ddr_writer_sources = "\n".join([media, main_cpp, fpga_h, fpga_cpp, layout_h])
    check(
        "packRgb24ToRgb565Le" not in media,
        "media_player.cpp reintroduced RGB24→RGB565 packing in the rawvideo present path. "
        "The C3 DDR frame store consumes planar YUV420p directly; do not leave a dead RGB565 "
        "alternate hot path that can drift from the RTL reader.",
    )
    check(
        "DdrFrameFormat::Rgb565" not in ddr_writer_sources,
        "ARM DDR writer code still exposes DdrFrameFormat::Rgb565. C3 RTL interprets DDR as "
        "I420/YUV420p unconditionally; retaining an RGB565 DDR enum/config is a silent "
        "cross-module format mismatch waiting to render garbage.",
    )
    check(
        "sendRgb565FrameDdr" not in ddr_writer_sources
        and "sendRgb24FrameDdr" not in ddr_writer_sources,
        "ARM code can still write RGB payloads to the DDR frame-store doorbell. C3 RTL is "
        "YUV-only; use sendYuv420pFrameDdr for DDR or fail loudly rather than producing "
        "decoder-looking garbage.",
    )
    check(
        "DDR_FRAME_FORMAT" in main_cpp
        and "fixed to yuv420p" in main_cpp
        and "DdrFrameFormat::Rgb565" not in main_cpp,
        "misterplexd main must not allow DDR_FRAME_FORMAT=rgb565 to reactivate the old "
        "writer. Keep any legacy config key as an ignored warning and leave production fixed "
        "to yuv420p.",
    )
    compact_media = norm(media)
    check(
        "renderIdleYuv420p" in media
        and "sendYuv420pFrameDdr(yuv.data(),yuv.size(),g,ddrBank_)" in compact_media,
        "MediaPlayer::paintIdle must send the rendered logo/screensaver through the YUV420p "
        "DDR path. A hard-coded black I420 payload clears stale video but makes the selectable "
        "FPGA idle logo/screensaver disappear under PRESENT=fpga.",
    )
    check(
        "memset(yuv.data(),kYuv420BlackY,yBytes)" not in compact_media,
        "MediaPlayer::paintIdle still constructs an all-black DDR idle payload. That is only "
        "valid for IDLE_SCREEN=black; logo/screensaver modes must preserve the idle renderer.",
    )
    tooling = "\n".join(
        [
            strip_comments(read(VALIDATE_PLAYBACK_HW_SH)),
            strip_comments(read(TEST_DDR_FRAME_SH)),
            read(HW_README_MD),
            read(PHASE3_DECODE_MD),
        ]
    )
    check(
        "--ddr --rgb24" not in tooling,
        "DDR helper tooling still invokes push_frame --ddr --rgb24. The DDR frame-store path "
        "is YUV420p only; RGB helpers must remain SPI-only or the hardware gate will now "
        "fail before presenting a frame.",
    )
    check(
        "push_frame --ddr" not in tooling or "file.rgb565" not in tooling,
        "DDR helper documentation still describes push_frame --ddr with RGB565 input. That "
        "call site was orphaned when 28c6c79 removed RGB DDR writes; use --yuv420p/I420.",
    )
    print("PASS ARM DDR writer uses product yuv420p frame-store path only")


def check_ddr_bitstream_product_path() -> None:
    media = strip_comments(read(MEDIA_PLAYER_CPP))
    check(
        "beginBitstreamSession" in media
        and "pushBitstreamNal" in media
        and "endBitstreamSession" in media,
        "media_player.cpp must feed STREAM=1 through the DDR record transport "
        "with explicit begin/pushNal/end. Falling back to ioctl or byte chunks "
        "reintroduces the one-shot/mid-NAL splice path that blocks FPGA decode.",
    )
    check(
        "NalDispatcher" in media and "h264stream::IBitstreamProducer" in media,
        "media_player.cpp must keep the w-a4 NalDispatcher/IBitstreamProducer source "
        "contract as the product feed loop. Replacing it with ad-hoc direct pushes risks "
        "duplicating sequence/backpressure policy and drifting from the host source side.",
    )
    check(
        "sendBitstreamChunkDdr" not in media,
        "media_player.cpp still calls sendBitstreamChunkDdr from the product stream. "
        "That legacy shim can wrap arbitrary byte chunks as records; product playback "
        "must copy complete Annex-B NALs with sequence/session metadata.",
    )
    check(
        "frames=0 with STREAM=1" in media
        and "DDR bitstream zero/effectively-empty delivery" in media
        and "readBitstreamStatus" in media,
        "STREAM=1 zero-delivery must fail loudly with DDR ring telemetry. A frames=0 "
        "session without producer/consumer/desync/underrun counters is indistinguishable "
        "from a decoder bug.",
    )
    print("PASS product STREAM path uses DDR NAL records with zero-delivery telemetry")


def main() -> int:
    check_present_core()
    check_phase_a_surface()
    check_mailboxes()
    check_ddr_bitstream_ring()
    check_status_telemetry()
    check_ddr_frame_layout_contract()
    check_yuv_ddr_writer_contract()
    check_ddr_bitstream_product_path()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
