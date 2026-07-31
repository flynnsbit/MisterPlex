#!/usr/bin/env python3
"""Fast source-level guards for MiSTerPlex RTL/host ABI invariants."""
from __future__ import annotations

import os
import re
import subprocess
import sys
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PRESENT_CORE = Path(os.environ.get("PRESENT_CORE", ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"))
PLEX_SV = Path(os.environ.get("PLEX_SV", ROOT / "fpga/Plex_MiSTer/Plex.sv"))
PLEX_SDC = Path(os.environ.get("PLEX_SDC", ROOT / "fpga/Plex_MiSTer/Plex.sdc"))
SYS_TOP_SDC = Path(os.environ.get("SYS_TOP_SDC", ROOT / "fpga/Plex_MiSTer/sys/sys_top.sdc"))
PLEX_QSF = Path(os.environ.get("PLEX_QSF", ROOT / "fpga/Plex_MiSTer/Plex.qsf"))
DDRAM_FRAME_RD = Path(
    os.environ.get("DDRAM_FRAME_RD", ROOT / "fpga/Plex_MiSTer/rtl/ddram_frame_rd.sv")
)
DDR_FRAME_LAYOUT_SVH = Path(
    os.environ.get(
        "DDR_FRAME_LAYOUT_SVH", ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
    )
)
DDR_FRAME_STORE = Path(
    os.environ.get("DDR_FRAME_STORE", ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv")
)
H264_DEBLOCK = Path(
    os.environ.get("H264_DEBLOCK", ROOT / "fpga/Plex_MiSTer/rtl/h264_deblock.sv")
)
H264_DPB = Path(os.environ.get("H264_DPB", ROOT / "fpga/Plex_MiSTer/rtl/h264_dpb.sv"))
ASYNC_FIFO = Path(os.environ.get("ASYNC_FIFO", ROOT / "fpga/Plex_MiSTer/rtl/async_fifo.sv"))
FPGA_SPI_HPP = Path(os.environ.get("FPGA_SPI_HPP", ROOT / "arm/misterplexd/fpga_spi.hpp"))
FPGA_SPI_CPP = Path(os.environ.get("FPGA_SPI_CPP", ROOT / "arm/misterplexd/fpga_spi.cpp"))
DDR_FRAME_LAYOUT_HPP = Path(
    os.environ.get("DDR_FRAME_LAYOUT_HPP", ROOT / "host/libmisterplex/ddr_frame_layout.hpp")
)
MEDIA_PLAYER_CPP = Path(
    os.environ.get("MEDIA_PLAYER_CPP", ROOT / "arm/misterplexd/media_player.cpp")
)
FFMPEG_VF_HPP = Path(
    os.environ.get("FFMPEG_VF_HPP", ROOT / "host/libmisterplex/ffmpeg_vf.hpp")
)
FB_PRESENT_CPP = Path(os.environ.get("FB_PRESENT_CPP", ROOT / "arm/misterplexd/fb_present.cpp"))
MISTERPLEXD_MAIN_CPP = Path(
    os.environ.get("MISTERPLEXD_MAIN_CPP", ROOT / "arm/misterplexd/main.cpp")
)
H264_RECON_HPP = Path(
    os.environ.get("H264_RECON_HPP", ROOT / "host/libmisterplex/h264_recon.hpp")
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
MAILBOX_ABI_SPEC = Path(
    os.environ.get("MAILBOX_ABI_SPEC", ROOT / "host/libmisterplex/mailbox_abi_spec.hpp")
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
TEST_FPGA_PUSH_SH = Path(
    os.environ.get("TEST_FPGA_PUSH_SH", ROOT / "tests/hw/test_fpga_push.sh")
)
HW_README_MD = Path(os.environ.get("HW_README_MD", ROOT / "tests/hw/README.md"))
PHASE3_DECODE_MD = Path(os.environ.get("PHASE3_DECODE_MD", ROOT / "docs/phase3-decode.md"))
PUSH_FRAME_CPP = Path(os.environ.get("PUSH_FRAME_CPP", ROOT / "tools/push_frame.cpp"))
SET_STATUS_CPP = Path(os.environ.get("SET_STATUS_CPP", ROOT / "tools/set_status.cpp"))
H264_DPB_RTL = Path(os.environ.get("H264_DPB_RTL", ROOT / "fpga/Plex_MiSTer/rtl/h264_dpb.sv"))
H264_DEBLOCK_RTL = Path(os.environ.get("H264_DEBLOCK_RTL", ROOT / "fpga/Plex_MiSTer/rtl/h264_deblock.sv"))
QUARTUS_SV_GUARD = ROOT / "scripts/check_quartus_sv_subset.py"
GEN_EDGE_MARKERS_PY = Path(
    os.environ.get("GEN_EDGE_MARKERS_PY", ROOT / "scripts/gen_edge_markers.py")
)

ACTIVE_SV_MACROS = {
    # Product/Quartus define set relevant to these source invariants.
    "DDR_FRAME_STORE",
    "FRAME_W",
    "FRAME_H",
}
ACTIVE_C_MACROS = {
    # ARM daemon product-side view.
    "__arm__",
}

PRODUCT_AUDIT_ROOTS = (
    "arm",
    "host",
    "tools",
    "scripts",
    "tests/hw",
    "fpga/Plex_MiSTer/rtl",
)
DOC_AUDIT_ROOTS = ("docs",)


def read(path: Path) -> str:
    try:
        return path.read_text()
    except OSError as e:
        fail(f"could not read {path}: {e}")


def tracked_files_under(*roots: str) -> list[Path]:
    """Return committed files under the given roots; ignored worktree debris is out of scope."""
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "--", *roots],
            cwd=ROOT,
            text=True,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as e:
        fail(f"could not enumerate tracked files with git ls-files: {e}")
    return [ROOT / line for line in out.splitlines() if line]


def tracked_product_and_doc_files() -> list[Path]:
    """Return committed product/runtime files plus docs that describe product commands."""
    return tracked_files_under(*PRODUCT_AUDIT_ROOTS, *DOC_AUDIT_ROOTS)


def strip_hash_comments(text: str) -> str:
    """Drop shell/python comments for literal sweeps without parsing strings."""
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith("#") and not stripped.startswith("#!"):
            out.append("\n" if line.endswith("\n") else "")
        else:
            out.append(line)
    return "".join(out)


def active_audit_text(path: Path) -> str:
    text = strip_comments(read(path))
    if path.suffix in {".py", ".sh"}:
        text = strip_hash_comments(text)
    return text


def sv_module_text(text: str, module_name: str) -> str:
    m = re.search(rf"\bmodule\s+{re.escape(module_name)}\b.*?\bendmodule\b", text, re.S)
    check(
        m is not None,
        f"could not find active SystemVerilog module {module_name}; source-text invariants "
        "must be scoped to the module that carries the property, not the whole file.",
    )
    return m.group(0)


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
    return strip_inactive_preprocessor_blocks("".join(out))


def eval_preprocessor_condition(expr: str, active_macros: set[str]) -> bool:
    expr = expr.strip()
    if expr in {"0", ""}:
        return False
    if expr == "1":
        return True
    m = re.fullmatch(r"defined\s*\(?\s*(\w+)\s*\)?", expr)
    if m:
        return m.group(1) in active_macros
    if re.fullmatch(r"\w+", expr):
        return expr in active_macros
    # Keep this intentionally conservative: unknown compound expressions are not
    # evidence for product code. If an invariant needs one, add it explicitly.
    return False


def strip_inactive_preprocessor_blocks(text: str) -> str:
    """Select the product/default branch of simple SV/C preprocessor conditionals.

    Source-text invariants must not be satisfiable by a decoy literal in
    `ifdef NEVER, #if 0, or fault-injection branches. This small line-oriented
    preprocessor is deliberately conservative and covers the condition forms
    used by the files this test audits.
    """
    out: list[str] = []
    stack: list[dict[str, bool]] = []

    def active() -> bool:
        return all(frame["current"] for frame in stack)

    def begin(cond: bool) -> None:
        parent = active()
        stack.append({"parent": parent, "current": parent and cond, "seen": cond})

    def alternate(cond: bool) -> None:
        if not stack:
            return
        frame = stack[-1]
        take = frame["parent"] and not frame["seen"] and cond
        frame["current"] = take
        frame["seen"] = frame["seen"] or cond

    for line in text.splitlines(keepends=True):
        sv = re.match(r"\s*`(ifdef|ifndef|elsif|else|endif)\b\s*(\w+)?", line)
        c = re.match(r"\s*#\s*(ifdef|ifndef|if|elif|else|endif)\b\s*(.*)", line)
        if sv:
            op, name = sv.group(1), sv.group(2) or ""
            if op == "ifdef":
                begin(name in ACTIVE_SV_MACROS)
            elif op == "ifndef":
                begin(name not in ACTIVE_SV_MACROS)
            elif op == "elsif":
                alternate(name in ACTIVE_SV_MACROS)
            elif op == "else":
                alternate(True)
            elif op == "endif" and stack:
                stack.pop()
            continue
        if c:
            op, expr = c.group(1), c.group(2)
            if op == "ifdef":
                begin(expr.strip() in ACTIVE_C_MACROS)
            elif op == "ifndef":
                begin(expr.strip() not in ACTIVE_C_MACROS)
            elif op == "if":
                begin(eval_preprocessor_condition(expr, ACTIVE_C_MACROS))
            elif op == "elif":
                alternate(eval_preprocessor_condition(expr, ACTIVE_C_MACROS))
            elif op == "else":
                alternate(True)
            elif op == "endif" and stack:
                stack.pop()
            continue
        if active():
            out.append(line)
    return "".join(out)


def select_default_sv_fault_branches(text: str) -> str:
    """Return the product/default view of small fault-injection `ifdef blocks."""
    return re.sub(
        r"`ifdef\s+DDR_FRAME_STORE_FAULT_SWAP_UV_READ\b.*?`else\s*(.*?)`endif",
        r"\1",
        text,
        flags=re.S,
    )


def norm(s: str) -> str:
    return re.sub(r"\s+", "", s)


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def check(cond: bool, msg: str) -> None:
    if not cond:
        fail(msg)


def conf_str_payload(src: str) -> str:
    m = re.search(r"\blocalparam\s+CONF_STR\s*=\s*\{(.*?)\n\s*\}\s*;", src, re.S)
    check(
        m is not None,
        "Plex.sv missing active CONF_STR localparam. Phase A menu/input labels must be "
        "proved from the hps_io CONF_STR payload, not unrelated string literals.",
    )
    payload = " ".join(re.findall(r'"([^"]*)"', m.group(1)))
    hps_instances = re.findall(r"hps_io\s*#\s*\(([^;]*?)\)\s+\w+\s*\(", src, re.S)
    check(
        len(hps_instances) == 1
        and re.search(r"\.CONF_STR\s*\(\s*CONF_STR\s*\)", hps_instances[0]),
        "Plex.sv hps_io must consume the audited CONF_STR localparam. Do not satisfy "
        "the Phase A menu guard with an unrelated or unbound string literal.",
    )
    return payload


def phase_a_menu_violations(src: str) -> list[str]:
    strings = conf_str_payload(src)
    violations: list[str] = []
    for entry in ("F1,raw", "F2,raw", "F3,264"):
        if entry not in strings:
            violations.append(
                f"Plex.sv CONF_STR missing `{entry}`. That drops a Phase A shipping file slot; "
                "restore F1 raw frame, F2 raw audio, and F3 H.264 annex-B menu entries."
            )
    if "O[15:14],Idle screen,Plex logo,Black,Screensaver,Last frame;" not in strings:
        violations.append(
            "Plex.sv CONF_STR idle-screen field drifted. The daemon decodes status[15:14] "
            "with option order Logo/Black/Screensaver/LastFrame; update "
            "libmisterplex/osd_menu.hpp and its red-check if the CONF_STR layout "
            "intentionally changes."
        )
    for label in ("Play/Pause", "Stop", "Skip Fwd", "Skip Back"):
        if not (label in strings and "J1," in strings):
            violations.append(
                f"Plex.sv J1 controller mapper missing `{label}`. Phase A playback controls "
                "must remain exposed to MiSTer's mapper; restore the J1 Play/Pause/Stop/Skip labels."
            )
    return violations


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
    matches = list(re.finditer(
        rf"(?:localparam|parameter)(?:\s+\w+)?(?:\s*\[[^\]]+\])?\s+{re.escape(name)}\s*=\s*([^,\n;)]+)",
        text,
    ))
    if not matches:
        fail(
            f"{name} is missing from RTL. This is part of the host/FPGA contract; "
            "restore the fixed mailbox/scanout parameter or update the matching host side and tests."
        )
    if len(matches) > 1:
        fail(
            f"{name} has {len(matches)} active RTL definitions. Source-text invariants must not be "
            "satisfiable by a duplicate decoy definition; keep one product definition."
        )
    return parse_num(matches[0].group(1))


def sv_param_expr(text: str, name: str) -> str:
    m = re.search(
        rf"(?:localparam|parameter)(?:\s+\w+)?(?:\s*\[[^\]]+\])?\s+{re.escape(name)}\s*=\s*([^,\n;)]+)",
        text,
    )
    if not m:
        fail(f"{name} is missing from RTL")
    return m.group(1).strip()


def sv_expr_uses_doorbell_offset(expr: str, offset: int) -> bool:
    compact = norm(expr).replace("_", "")
    return compact in {
        f"DOORBELLPHYS+32'h{offset:X}",
        f"DOORBELLPHYS+32'h{offset:x}",
        f"DOORBELLPHYS+{offset}",
    }


def cpp_const_map(text: str) -> dict[str, str]:
    """Map host constexpr names to their initializer expression text.

    Supports assignment form (``constexpr int kFoo = 1;``) and strong-typed
    brace-init (``constexpr CodedWidth kFoo{624};``).
    """
    out: dict[str, str] = {}

    def _add(name: str, value: str) -> None:
        value = value.strip()
        if name in out:
            fail(
                f"{name} has multiple active host constexpr definitions. Source-text invariants "
                "must not be satisfiable by a duplicate decoy definition."
            )
        out[name] = value

    for m in re.finditer(r"constexpr\s+(?:\w+\s+)+(\w+)\s*=\s*([^;]+);", text):
        _add(m.group(1), m.group(2))
    for m in re.finditer(r"constexpr\s+(?:\w+\s+)+(\w+)\s*\{\s*([^}]+)\s*\}\s*;", text):
        _add(m.group(1), m.group(2))
    return out


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
        # Handle namespace::symbol references (e.g. mailbox_abi::kPlxsAddr)
        if "::" in expr:
            bare = expr.rsplit("::", 1)[1]
            if bare in consts:
                if bare in seen:
                    fail(f"host constant alias cycle while resolving {name}")
                seen.add(bare)
                return resolve(consts[bare])
        if re.fullmatch(r"\w+", expr) and expr in consts:
            if expr in seen:
                fail(f"host constant alias cycle while resolving {name}")
            seen.add(expr)
            return resolve(consts[expr])
        return parse_num(expr)

    return resolve(consts[name])


def check_source_text_matcher_hardening() -> None:
    sv = strip_comments(
        "`ifdef NEVER_DEFINED_DECOY\n"
        "localparam DE_LAG = 3'd3;\n"
        "`endif\n"
        "localparam DE_LAG = 3'd4;\n"
    )
    check(
        sv_const(sv, "DE_LAG") == 4,
        "inactive SV preprocessor branches can still satisfy source-text invariants",
    )
    cpp = strip_comments(
        "#if 0\n"
        "constexpr uint32_t kDecoyValue = 1;\n"
        "#endif\n"
        "constexpr uint32_t kDecoyValue = 2;\n"
    )
    check(
        cpp_const(cpp, "kDecoyValue") == 2,
        "inactive C/C++ preprocessor branches can still satisfy source-text invariants",
    )
    print("PASS source-text matcher ignores inactive preprocessor decoys")


def check_present_core() -> None:
    text = sv_module_text(strip_comments(read(PRESENT_CORE)), "present_core")
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
    text = sv_module_text(strip_comments(read(PLEX_SV)), "emu")

    missing_menu = phase_a_menu_violations(text)
    if missing_menu:
        fail(f"Plex.sv Phase A feature surface: {missing_menu[0]}")

    decoy_menu = text.replace('"F1,raw,RGB565 frame (320x240);"', '"F1,bad,decoy removed;"', 1)
    decoy_menu += '\nlocalparam W_GATE_DECOY_CONF_STR = "F1,raw,RGB565 frame (320x240);";\n'
    if not phase_a_menu_violations(decoy_menu):
        fail("decoy string outside CONF_STR satisfied the Phase A menu surface guard")

    hps_instances = re.findall(r"hps_io\s*#\s*\([^;]*?\)\s+\w+\s*\((.*?)\n\s*\);", text, re.S)
    check(
        len(hps_instances) == 1,
        f"Plex.sv should contain exactly one active hps_io instance; found {len(hps_instances)}. "
        "Do not satisfy the input-surface guard with a decoy instance.",
    )
    hps_ports = hps_instances[0]
    for token, why in (
        (r"\.ps2_key\s*\(\s*ps2_key\s*\)", "hps_io PS/2 wiring"),
        (r"\.joystick_0\s*\(\s*joystick_0\s*\)", "hps_io joystick wiring"),
    ):
        check(
            re.search(token, hps_ports) is not None,
            f"Plex.sv missing {why}. Phase A requires joystick_0 and ps2_key command decode; "
            "restore the hps_io wiring and playback command decoder.",
        )
    exact_decodes = [
        (
            r"wire\s+key_play_pause\s*=\s*ps2_press\s*&\s*~ps2_ext\s*&\s*\(\s*ps2_code\s*==\s*8'h29\s*\)\s*;",
            "Space Play/Pause decode",
        ),
        (
            r"wire\s+key_stop\s*=\s*ps2_press\s*&\s*~ps2_ext\s*&\s*\(\s*ps2_code\s*==\s*8'h76\s*\)\s*;",
            "Esc Stop decode",
        ),
        (
            r"wire\s+key_skip_fwd\s*=\s*ps2_press\s*&\s*ps2_ext\s*&\s*\(\s*ps2_code\s*==\s*8'h74\s*\)\s*;",
            "Right-arrow Skip Fwd decode",
        ),
        (
            r"wire\s+key_skip_back\s*=\s*ps2_press\s*&\s*ps2_ext\s*&\s*\(\s*ps2_code\s*==\s*8'h6B\s*\)\s*;",
            "Left-arrow Skip Back decode",
        ),
    ]
    for token, why in exact_decodes:
        check(
            re.search(token, text) is not None,
            f"Plex.sv missing {why}. Phase A requires joystick_0 and ps2_key command decode; "
            "restore the hps_io wiring and playback command decoder.",
        )
    for bit, why in ((4, "J1 Play/Pause"), (5, "J1 Stop"), (6, "J1 Skip Fwd"), (7, "J1 Skip Back")):
        check(
            re.search(rf"\bjoy_rise\s*\[\s*{bit}\s*\]", text) is not None,
            f"Plex.sv missing {why} decode. Phase A requires joystick_0 and ps2_key command decode; "
            "restore the hps_io wiring and playback command decoder.",
        )
    print("PASS Plex.sv Phase A feature surface")


def check_plex_reset_domains() -> None:
    text = sv_module_text(strip_comments(read(PLEX_SV)), "emu")

    def missing_reset_requirements(src: str) -> list[str]:
        missing: list[str] = []
        if re.search(r"wire\s+present_reset\s*=\s*reset\s*\|\s*sdram_startup_busy\s*;", src):
            missing.append(
                "Plex.sv must keep DDR_FRAME_STORE present_core reset independent of "
                "sdram_startup_busy. Product DDR presentation may not wait for SDRAM startup"
            )
        if not re.search(r"wire\s+present_reset\s*=\s*reset\s*;", src):
            missing.append(
                "Plex.sv must keep DDR_FRAME_STORE present_core reset independent of "
                "sdram_startup_busy, while non-DDR builds still wait for SDRAM startup"
            )
        m = re.search(r"present_core\s*#\s*\(.*?\)\s+present\s*\((.*?)\n\s*\);", src, re.S)
        if not m or re.search(r"\.reset\s*\(\s*present_reset\s*\)", m.group(1)) is None:
            missing.append(
                "present_core must consume present_reset. Resetting DDR presentation with "
                "reset|sdram_startup_busy can leave accepted DDR/YUV doorbells unpublished "
                "with has_frame=0."
            )
        return missing

    missing = missing_reset_requirements(text)
    if missing:
        fail(f"Plex.sv reset-domain contract: {missing[0]}")

    faulted = re.sub(
        r"(wire\s+present_reset\s*=\s*)reset(\s*;)",
        r"\1reset | sdram_startup_busy\2",
        text,
        count=1,
    )
    if not missing_reset_requirements(faulted):
        fail("deliberately tying DDR present reset to sdram_startup_busy did not make the reset gate red")
    print("PASS Plex.sv DDR presenter reset is not held behind SDRAM startup")


def check_quartus_syntax_tripwires() -> None:
    deblock = strip_comments(read(H264_DEBLOCK))
    dpb = strip_comments(read(H264_DPB))

    def missing_quartus_requirements(deblock_text: str, dpb_text: str) -> list[str]:
        missing: list[str] = []
        m = re.search(r"module\s+h264_deblock_writeback_ctrl\s*#\s*\((.*?)\)\s*\(", deblock_text, re.S)
        if not m or re.search(r"\blocalparam\b", m.group(1)):
            missing.append(
                "h264_deblock_writeback_ctrl parameter port list contains localparam. "
                "Verilator accepts this, but Quartus rejected the fit source; keep "
                "derived port widths as parameters or move them out of the port list."
            )
        if re.search(r"\)\s*\[[^\]]+\]", dpb_text):
            missing.append(
                "h264_dpb.sv contains a part-select directly on a function/expression "
                "result. Quartus rejected this around qpel_at; assign through a sized "
                "helper/value instead."
            )
        return missing

    missing = missing_quartus_requirements(deblock, dpb)
    if missing:
        fail(f"Quartus syntax tripwire: {missing[0]}")

    fault_deblock = deblock.replace("parameter int MB_AW =", "localparam int MB_AW =", 1)
    if not missing_quartus_requirements(fault_deblock, dpb):
        fail("deliberate h264_deblock localparam-in-parameter-list fault did not go red")
    fault_dpb = dpb.replace("low8(pix(row, col))", "pix(row, col)[7:0]", 1)
    if not missing_quartus_requirements(deblock, fault_dpb):
        fail("deliberate h264_dpb function-call part-select fault did not go red")
    print("PASS Quartus syntax tripwires for known Verilator-clean fit failures")


def check_async_fifo_write_full_no_comb_loop() -> None:
    text = sv_module_text(strip_comments(read(ASYNC_FIFO)), "async_fifo")
    nt = norm(text)
    check(
        "wr_full_now=(wr_gray==wr_gray_full)" in nt,
        "async_fifo wr_full must be based on the registered write pointer. The old "
        "wr_bin_next->wr_gray_next->wr_full->wr_bin_next dependency formed a Quartus "
        "combinational loop inside ddr_frame_store input_fifo.",
    )
    check(
        "wr_bin_next=wr_bin+(wr_accept?PTR_ONE:'0)" in nt
        and "wr_accept=wr_en&&!wr_full_now" in nt,
        "async_fifo write pointer advance must use a separate wr_accept from registered "
        "full state; do not feed wr_full back through wr_bin_next.",
    )
    fault = nt.replace(
        "wr_accept=wr_en&&!wr_full_now",
        "wr_bin_next=wr_bin+((wr_en&&!wr_full)?PTR_ONE:'0)",
    )
    check(
        "wr_bin_next=wr_bin+((wr_en&&!wr_full)?PTR_ONE:'0)" not in nt
        and "wr_bin_next=wr_bin+((wr_en&&!wr_full)?PTR_ONE:'0)" in fault,
        "async_fifo deliberate write-full feedback fault did not go red",
    )
    print("PASS async_fifo write-full path has no source-level combinational loop")


def check_frame_store_cdc_contract() -> None:
    fs = sv_module_text(strip_comments(read(DDR_FRAME_STORE)), "ddr_frame_store")
    afifo = sv_module_text(strip_comments(read(ASYNC_FIFO)), "async_fifo")
    sdc = strip_comments(read(PLEX_SDC) + "\n" + read(SYS_TOP_SDC))
    nft = norm(fs)
    nt_afifo = norm(afifo)

    requirements = [
        (
            "always@(posedgeclk_ddr)beginif(reset)beginreset_ddr_s1<=1'b1;reset_ddr_s2<=1'b1;",
            "ddr_frame_store must synchronously assert and release reset into clk_ddr before first DDR command",
        ),
        (
            ".wr_clk(clk),.wr_reset(reset)",
            "input FIFO write side must stay in the clk domain",
        ),
        (
            ".rd_clk(clk_ddr),.rd_reset(reset_ddr)",
            "input FIFO read side must use the clk_ddr-synchronised reset",
        ),
        (
            "swap_req_s1<=swap_req_t_ddr;swap_req_s2<=swap_req_s1;",
            "DDR-to-present frame-swap request must be a two-flop toggle crossing",
        ),
        (
            "pending_ready_s1<=pending_ready_ddr;pending_ready_s2<=pending_ready_s1;",
            "DDR-to-present pending-ready flag must be two-flop synchronised",
        ),
        (
            "line_buf_ram#(.WIDTH(Y_LINE_QWORDS),.AW(Y_QW_AW),.DATA_W(64))yram(.wr_clk(clk_ddr)",
            "frame line-buffer RAM writes must remain in clk_ddr",
        ),
        (
            ".rd_clk(clk),.rd_addr(y_rd_addr)",
            "frame line-buffer RAM reads must remain in clk",
        ),
    ]
    for needle, msg in requirements:
        check(needle in nft, f"ddr_frame_store CDC contract: {msg}")

    check(
        "wr_gray" in nt_afifo
        and "rd_gray_w1<=rd_gray;rd_gray_w2<=rd_gray_w1;" in nt_afifo
        and "wr_gray_r1<=wr_gray;wr_gray_r2<=wr_gray_r1;" in nt_afifo,
        "async_fifo CDC contract: pointers must cross as gray-coded values through two flops",
    )
    check(
        not re.search(
            r"set_(?:false|multicycle)_path[^\n]*(?:fstore|ddr_frame_store|DDRAM|present_ddr|stream_ddr|ddr_arb|async_fifo)",
            sdc,
            re.I,
        ),
        "SDC must not hide frame-store/DDR/arbiter timing with false or multicycle paths",
    )
    print("PASS frame-store CDC contract (clk/clk_ddr crossings and DDR timing constraints)")


def check_mailboxes() -> None:
    # --- Single-source-of-truth gate ---
    # All mailbox addresses and magics are defined ONCE in mailbox_abi_spec.hpp.
    # This gate verifies that BOTH the RTL (SystemVerilog) and the ARM C++
    # (input_mailbox.hpp, sdram_mailbox.hpp, ddr_bitstream_ring.hpp, fpga_spi.hpp)
    # consume from the spec and haven't drifted.
    spec_text = strip_comments(read(MAILBOX_ABI_SPEC))
    rtl = sv_module_text(strip_comments(read(DDRAM_FRAME_RD)), "ddram_frame_rd")
    ddr_fs = sv_module_text(strip_comments(read(DDR_FRAME_STORE)), "ddr_frame_store")
    fpga_spi = strip_comments(read(FPGA_SPI_HPP))
    input_h = strip_comments(read(INPUT_MAILBOX_HPP))
    host = spec_text + "\n" + fpga_spi + "\n" + input_h

    # --- Verify spec declares authoritative values ---
    spec_entries = {
        "PLXK": ("kPlxkAddr", "kPlxkMagic", 0x3007F000, 0x504C584B),
        "PLXS": ("kPlxsAddr", "kPlxsMagic", 0x3007F100, 0x504C5853),
        "PLXI": ("kPlxiAddr", "kPlxiMagic", 0x3007F108, 0x504C5849),
        "PLXM": ("kPlxmAddr", "kPlxmMagic", 0x3007F110, 0x504C584D),
        "PLXF": ("kPlxfAddr", "kPlxfMagic", 0x3007F118, 0x504C5846),
        "DIAG": ("kSdramDiagAddr", None, 0x3007F120, None),
        "PLXD": ("kPlxdAddr", "kPlxdMagic", 0x3007F128, 0x504C5844),
        "PLXB": ("kPlxbAddr", "kPlxbMagic", 0x30140000, 0x504C5842),
    }
    for name, (addr_sym, magic_sym, exp_addr, exp_magic) in spec_entries.items():
        sa = cpp_const(spec_text, addr_sym)
        check(sa == exp_addr,
              f"mailbox_abi_spec.hpp {addr_sym}=0x{sa:08X}, expected 0x{exp_addr:08X}. "
              "The spec file is the single source of truth; fix it there.")
        if magic_sym and exp_magic:
            sm = cpp_const(spec_text, magic_sym)
            check(sm == exp_magic,
                  f"mailbox_abi_spec.hpp {magic_sym}=0x{sm:08X}, expected 0x{exp_magic:08X}. "
                  "The spec file is the single source of truth; fix it there.")

    # --- Verify C++ consumers re-export from the spec (not hardcoded) ---
    # input_mailbox.hpp must use mailbox_abi:: references, not literal hex.
    input_raw = read(INPUT_MAILBOX_HPP)
    for cpp_name in ["kDdrStatusMailboxPhys", "kDdrStatusMailboxMagic",
                     "kInputMailboxPhys", "kInputMailboxMagic",
                     "kMemtestMailboxPhys", "kMemtestMailboxMagic",
                     "kUnderrunMailboxPhys", "kUnderrunMailboxMagic",
                     "kBankReleaseMailboxPhys", "kBankReleaseMailboxMagic"]:
        check("mailbox_abi::" in input_raw or "mailbox_abi_spec" in input_raw,
              f"input_mailbox.hpp must import from mailbox_abi_spec.hpp, "
              f"not hardcode {cpp_name}. Two copies will drift.")

    # --- Cross-check RTL against spec for frame-store mailboxes ---
    rtl_cases = [
        ("PLXS", "MAILBOX_PHYS", "MAGIC_S", 0x3007F100, 0x504C5853, 0x100),
        ("PLXI", "INPUT_MAILBOX_PHYS", "MAGIC_I", 0x3007F108, 0x504C5849, 0x108),
        ("PLXM", "MEMTEST_MAILBOX_PHYS", "MAGIC_M", 0x3007F110, 0x504C584D, 0x110),
        ("PLXF", "UNDERRUN_MAILBOX_PHYS", "MAGIC_F", 0x3007F118, 0x504C5846, 0x118),
    ]
    for magic, rtl_addr, rtl_magic, expected_addr, expected_magic, offset in rtl_cases:
        ra_expr = sv_param_expr(rtl, rtl_addr)
        rm = sv_const(rtl, rtl_magic)
        host_addr = cpp_const(host, {"PLXS": "kDdrMailboxPhys",
                                     "PLXI": "kInputMailboxPhys",
                                     "PLXM": "kMemtestMailboxPhys",
                                     "PLXF": "kUnderrunMailboxPhys"}[magic])
        host_magic = cpp_const(host, {"PLXS": "kDdrMailboxMagic",
                                      "PLXI": "kInputMailboxMagic",
                                      "PLXM": "kMemtestMailboxMagic",
                                      "PLXF": "kUnderrunMailboxMagic"}[magic])
        check(
            sv_expr_uses_doorbell_offset(ra_expr, offset)
            and host_addr == expected_addr and rm == host_magic == expected_magic,
            f"DDR mailbox `{magic}` mismatch: RTL {rtl_addr}={ra_expr}/{rtl_magic}=0x{rm:08X}, "
            f"host=0x{host_addr:08X}/0x{host_magic:08X}, spec=0x{expected_addr:08X}/0x{expected_magic:08X}. "
            "RTL mailbox addresses must derive from DOORBELL_PHYS + the mailbox offset; "
            "host/spec define the base offsets in mailbox_abi_spec.hpp.",
        )
        fs_expr = sv_param_expr(ddr_fs, {
            "PLXS": "MAILBOX_PHYS",
            "PLXI": "INPUT_MAILBOX_PHYS",
            "PLXM": "SDRAM_MAILBOX_PHYS",
            "PLXF": "FRAME_MAILBOX_PHYS",
        }[magic])
        check(
            sv_expr_uses_doorbell_offset(fs_expr, offset),
            f"ddr_frame_store {magic} mailbox must derive from DOORBELL_PHYS + 0x{offset:X}, "
            f"got {fs_expr}",
        )
    check(
        sv_expr_uses_doorbell_offset(sv_param_expr(rtl, "MEMTEST_DIAG_MAILBOX_PHYS"), 0x120),
        "ddram_frame_rd diagnostic mailbox must derive from DOORBELL_PHYS + 0x120",
    )
    check(
        sv_expr_uses_doorbell_offset(sv_param_expr(ddr_fs, "BANK_MAILBOX_PHYS"), 0x128),
        "ddr_frame_store PLXD mailbox must derive from DOORBELL_PHYS + 0x128",
    )

    # --- Cross-check PLXD bank-release against spec ---
    # Legacy example absolute (doorbell base 0x3007F000) still equals 0x3007F128.
    # Product doorbell is 0x300FF000 → live PLXD is 0x300FF128 via offset 0x128.
    plxd_addr = cpp_const(host, "kBankReleaseMailboxPhys")
    plxd_magic = cpp_const(host, "kBankReleaseMailboxMagic")
    check(plxd_addr == 0x3007F128,
          f"legacy example PLXD address must be 0x3007F128 (got 0x{plxd_addr:08X})")
    check(plxd_magic == 0x504C5844,
          f"PLXD bank-release magic must be 0x504C5844 'PLXD' (got 0x{plxd_magic:08X})")
    plxd_off = cpp_const(spec_text, "kPlxdOffset")
    check(plxd_off == 0x128,
          f"kPlxdOffset must be 0x128 (got 0x{plxd_off:X})")
    product_doorbell = 0x300FF000
    product_plxd = product_doorbell + plxd_off
    check(product_plxd == 0x300FF128,
          f"product PLXD must be 0x300FF128 (got 0x{product_plxd:08X})")
    check(product_plxd != 0x3007F128,
          "product PLXD must not collapse to legacy absolute 0x3007F128")
    spi = (ROOT / "arm" / "misterplexd" / "fpga_spi.cpp").read_text()
    check("bankReleaseMailboxPhys(ddrLayout_.doorbell_phys)" in spi,
          "fpga_spi readBankRelease must use bankReleaseMailboxPhys(doorbell)")
    check("kBankReleaseMailboxPhys - ddrLayout_.phys_base" not in spi,
          "fpga_spi must not map PLXD via legacy absolute kBankReleaseMailboxPhys")

    # Verify PLXD bit-field positions in the spec are what the RTL packs.
    check(cpp_const(spec_text, "kPlxdFreeBankMaskBit") == 0,
          "PLXD free_bank_mask starts at bit 0 of upper word (bits [33:32])")
    check(cpp_const(spec_text, "kPlxdFreeBankMaskWidth") == 2,
          "PLXD free_bank_mask is 2 bits wide")
    check(cpp_const(spec_text, "kPlxdDispBankBit") == 2,
          "PLXD disp_bank at bit 2 of upper word (bit [34])")
    check(cpp_const(spec_text, "kPlxdSwapPendingBit") == 3,
          "PLXD swap_pending at bit 3 of upper word (bit [35])")
    check(cpp_const(spec_text, "kPlxdFramesDoneBit") == 16,
          "PLXD frames_done starts at bit 16 of upper word (bits [63:48])")
    check(cpp_const(spec_text, "kPlxdFramesDoneWidth") == 16,
          "PLXD frames_done is 16 bits wide")
    # c5382bee packed bank_vsync_count as frames_done — liveness never saw stuck
    # swaps. Product must pack the CDC'd real swap counter into DDRAM_DIN.
    plxd_din = ""
    for chunk in ddr_fs.split("DDRAM_DIN <="):
        if "MAGIC_D" in chunk[:400]:
            plxd_din = chunk[:400]
            break
    check(plxd_din != "", "PLXD DDRAM_DIN assignment with MAGIC_D must exist")
    check("bank_vsync_count" not in plxd_din,
          "PLXD DIN must not pack bank_vsync_count as frames_done")
    check("frames_done_d2" in plxd_din,
          "PLXD DIN must pack frames_done_d2 (CDC'd real swap counter)")
    check("selectDdrWriteBank" in spi,
          "sendDdrFrame must use selectDdrWriteBank (display-ack / stale-free guard)")
    check("no force-write" in spi,
          "sendDdrFrame must log/drop on PLXD timeout (no force-write)")
    check("bank = brs.disp_bank ^ 1" not in spi,
          "sendDdrFrame must not force-write disp^1 on PLXD timeout")

    # --- Address collision detection ---
    # Reject any two mailboxes at the same physical address.
    all_addrs: dict[int, str] = {}
    for name, (addr_sym, _, exp_addr, _) in spec_entries.items():
        if exp_addr in all_addrs:
            check(False,
                  f"ADDRESS COLLISION: {name} at 0x{exp_addr:08X} overlaps "
                  f"{all_addrs[exp_addr]}. Check mailbox_abi_spec.hpp.")
        all_addrs[exp_addr] = name

    # --- Magic collision detection ---
    # Reject any two mailboxes sharing the same magic value.
    all_magics: dict[int, str] = {}
    for name, (_, magic_sym, _, exp_magic) in spec_entries.items():
        if exp_magic is None:
            continue
        if exp_magic in all_magics:
            check(False,
                  f"MAGIC COLLISION: {name} magic 0x{exp_magic:08X} overlaps "
                  f"{all_magics[exp_magic]}. Check mailbox_abi_spec.hpp.")
        all_magics[exp_magic] = name

    # Also check bitstream ring magics for collisions with mailbox magics.
    ring_magics = {
        "PLXR": 0x504C5852, "PLXE": 0x504C5845, "PLXN": 0x504C584E,
        "PLXT": 0x504C5854, "PLXU": 0x504C5855, "PLXV": 0x504C5856,
        "PLXW": 0x504C5857, "PLXY": 0x504C5859, "PLXZ": 0x504C585A,
        "PLXQ": 0x504C5851,
    }
    for rname, rmagic in ring_magics.items():
        if rmagic in all_magics:
            check(False,
                  f"MAGIC COLLISION: ring {rname} magic 0x{rmagic:08X} overlaps "
                  f"mailbox {all_magics[rmagic]}. Check mailbox_abi_spec.hpp.")
        all_magics[rmagic] = f"ring:{rname}"

    print("PASS DDR mailbox host/RTL ABI constants (single-source-of-truth spec gate)")


def check_mailbox_map_collisions() -> None:
    """Verify the authoritative mailbox map has no address or magic collisions,
    and that RTL constants match the registry for every entry that has an
    rtl_addr_param.  This is the single-source-of-truth gate the parent
    required after the PLXA/PLXD ABI collision."""
    import json

    map_path = ROOT / "docs" / "plx_mailbox_map.json"
    check(map_path.exists(), f"Mailbox registry missing: {map_path}")
    registry = json.loads(map_path.read_text())
    mailboxes = registry["mailboxes"]
    ring = registry.get("bitstream_ring", {})

    # ── Collect ALL addresses and magics across both sections ──
    all_addrs: dict[int, str] = {}
    all_magics: dict[int, str] = {}

    for mb in mailboxes:
        name = mb["name"]
        addr = int(mb["address"], 16)
        if addr in all_addrs:
            fail(f"Mailbox address collision: {name} and {all_addrs[addr]} both at 0x{addr:08X}")
        all_addrs[addr] = name
        magic_s = mb.get("magic")
        if magic_s is not None:
            magic = int(magic_s, 16)
            if magic in all_magics:
                fail(f"Mailbox magic collision: {name} and {all_magics[magic]} both use 0x{magic:08X}")
            all_magics[magic] = name

    for rname, rval in ring.items():
        if rname.startswith("_"):
            continue
        addr = int(rval["address"], 16)
        if addr in all_addrs:
            fail(f"Ring address collision: {rname} and {all_addrs[addr]} both at 0x{addr:08X}")
        all_addrs[addr] = rname
        magic = int(rval["magic"], 16)
        if magic in all_magics:
            fail(f"Ring magic collision: {rname} and {all_magics[magic]} both use 0x{magic:08X}")
        all_magics[magic] = rname

    # ── Cross-check RTL constants against registry ──
    frame_store_rtl = sv_module_text(strip_comments(read(DDR_FRAME_STORE)), "ddr_frame_store")
    ddram_frame_rd_rtl = sv_module_text(strip_comments(read(DDRAM_FRAME_RD)), "ddram_frame_rd")
    mailbox_base = int(next(mb["address"] for mb in mailboxes if mb["name"] == "PLXS"), 16) - 0x100

    for mb in mailboxes:
        name = mb["name"]
        rtl_addr_param = mb.get("rtl_addr_param")
        rtl_magic_param = mb.get("rtl_magic_param")
        expected_addr = int(mb["address"], 16)

        if rtl_addr_param is None:
            continue

        # Try ddr_frame_store first, fall back to ddram_frame_rd
        ra = None
        ra_expr = None
        for rtl_src in (frame_store_rtl, ddram_frame_rd_rtl):
            m = re.search(
                rf"(?:localparam|parameter)(?:\s+\w+)?(?:\s*\[[^\]]+\])?\s+{re.escape(rtl_addr_param)}\s*=\s*([^,\n;)]+)",
                rtl_src,
            )
            if m:
                ra_expr = m.group(1).strip()
                ra = parse_num(ra_expr)
                break

        check(
            ra is not None,
            f"Mailbox map references RTL param {rtl_addr_param} for {name}, "
            "but it was not found in ddr_frame_store.sv or ddram_frame_rd.sv.",
        )
        offset = expected_addr - mailbox_base
        derived = ra_expr is not None and sv_expr_uses_doorbell_offset(ra_expr, offset)
        check(
            derived or ra == expected_addr,
            f"Mailbox map drift: {name} RTL {rtl_addr_param}={ra_expr} != "
            f"registry 0x{expected_addr:08X} or DOORBELL_PHYS+0x{offset:X}. "
            "Update docs/plx_mailbox_map.json OR the RTL — they must agree. "
            "This gate exists because the PLXA/PLXD ABI collision proved that two "
            "hand-maintained copies WILL drift.",
        )

        if rtl_magic_param is not None:
            expected_magic = int(mb["magic"], 16)
            rm = None
            for rtl_src in (frame_store_rtl, ddram_frame_rd_rtl):
                m = re.search(
                    rf"(?:localparam|parameter)(?:\s+\w+)?(?:\s*\[[^\]]+\])?\s+{re.escape(rtl_magic_param)}\s*=\s*([^,\n;)]+)",
                    rtl_src,
                )
                if m:
                    rm = parse_num(m.group(1))
                    break
            check(
                rm is not None,
                f"Mailbox map references RTL param {rtl_magic_param} for {name}, "
                "but it was not found in ddr_frame_store.sv or ddram_frame_rd.sv.",
            )
            check(
                rm == expected_magic,
                f"Mailbox map drift: {name} RTL {rtl_magic_param}=0x{rm:08X} != "
                f"registry 0x{expected_magic:08X}. Update docs/plx_mailbox_map.json OR the RTL.",
            )

    print(f"PASS mailbox map collision guard ({len(all_addrs)} addresses, {len(all_magics)} magics, 0 collisions)")


def check_ddr_bitstream_ring() -> None:
    rtl = sv_module_text(strip_comments(read(DDR_BITSTREAM_READER)), "ddr_bitstream_reader")
    spec_text = strip_comments(read(MAILBOX_ABI_SPEC))
    host = spec_text + "\n" + strip_comments(read(DDR_BITSTREAM_RING_HPP))
    fpga_spi = strip_comments(read(FPGA_SPI_CPP))
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
    err_bits = {
        "kErrTelemetrySeqShift": 32,
        "kErrUnderrunStickyBit": 45,
        "kErrOverrunStickyBit": 46,
        "kErrActiveBit": 47,
        "kErrUnderrunCountShift": 48,
        "kErrOverrunCountShift": 56,
    }
    for name, expected in err_bits.items():
        got = cpp_const(host, name)
        check(
            got == expected,
            f"DDR bitstream PLXE {name}={got}, expected {expected}. The RTL packs "
            "PLXE as seq[39:32], flags[47:45], underrun_count[55:48], "
            "overrun_count[63:56]; do not parse the old [42:40] flag positions.",
        )
    rtl_nt = norm(rtl)
    check(
        "DDRAM_DIN<={overrun_count[7:0],underrun_count[7:0],active,overrun_sticky,underrun_sticky,5'd0,telem_seq+8'd1,MAGIC_ERR}" in rtl_nt,
        "ddr_bitstream_reader no longer packs PLXE as {overrun_count[7:0], "
        "underrun_count[7:0], active, overrun_sticky, underrun_sticky, 5'd0, "
        "telem_seq, MAGIC_ERR}. Update ddr_bitstream_ring.hpp decode constants and "
        "red tests with the new producer layout.",
    )
    check(
        "decodeErrStatusWord(errRaw,status)" in norm(fpga_spi),
        "FpgaSpi::readBitstreamStatus must decode the PLXE word through the shared "
        "ddr_bitstream_ring.hpp helper. Open-coded shifts already drifted from the RTL "
        "producer once and made active/underrun/overrun flags lie.",
    )
    print("PASS DDR bitstream ring host/RTL ABI constants")


def check_status_telemetry() -> None:
    plex = sv_module_text(strip_comments(read(PLEX_SV)), "emu")
    fpga_spi = strip_comments(read(FPGA_SPI_CPP))
    status_h = strip_comments(read(STATUS_TELEMETRY_HPP))
    push_frame = strip_comments(read(PUSH_FRAME_CPP))
    set_status = strip_comments(read(SET_STATUS_CPP))
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
    status_tools = push_frame + "\n" + set_status
    check(
        "bytes_in=%u" not in status_tools and "stream_nalus=%u" in status_tools,
        "status tools must not label the post-P3 NAL-count liveness alias as bytes_in. "
        "Expose stream_nalus and bytes_in_unavailable=1 so freshness gates cannot mistake "
        "nalu=4 for four delivered bytes again.",
    )
    check(
        "frame_debug=0x%02x" in status_tools and "frame_seq=%u" in status_tools,
        "status tools must surface the DDR frame-store debug byte and doorbell token. "
        "frame_debug=0xE1 distinguishes a rejected non-YUV doorbell/harness bug from "
        "a broken delivery path.",
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
    # Vacuity / red-check: a deliberate RTL coded-width edit must disagree with the
    # host writer constants (this is the shear: ARM line_bytes vs CODED_W).
    host_stride = cpp_const(host, "kPlex480pYStrideBytes")
    rtl_stride = sv_const(rtl, "DDR_FRAME_Y_STRIDE_BYTES")
    check(
        host_stride == rtl_stride == 624,
        f"product Y stride must be 624 on both sides (host={host_stride} rtl={rtl_stride})",
    )
    rtl_fault = re.sub(
        r"(localparam\s+int\s+DDR_FRAME_CODED_WIDTH\s*=\s*)\d+",
        r"\g<1>320",
        rtl,
        count=1,
    )
    rtl_fault = re.sub(
        r"(localparam\s+int\s+DDR_FRAME_Y_STRIDE_BYTES\s*=\s*)\d+",
        r"\g<1>320",
        rtl_fault,
        count=1,
    )
    fault_coded = sv_const(rtl_fault, "DDR_FRAME_CODED_WIDTH")
    fault_stride = sv_const(rtl_fault, "DDR_FRAME_Y_STRIDE_BYTES")
    if fault_coded == cpp_const(host, "kPlex480pCodedWidth") or fault_stride == host_stride:
        fail(
            "deliberate RTL CODED_WIDTH/Y_STRIDE 624→320 fault did not diverge from host "
            f"(fault_coded={fault_coded} fault_stride={fault_stride} host_stride={host_stride})"
        )
    print("PASS DDR frame layout ARM/RTL contract")
    print(
        "PASS DDR stride parity red-check: RTL CODED_WIDTH/Y_STRIDE 624→320 diverges from host"
    )


def check_runtime_ddr_layout_literal_sweep() -> None:
    """Reject runtime reintroductions of fixed 320p/480p DDR frame addresses.

    The only acceptable sources for frame-bank stride, bank base, and doorbell
    arithmetic are the host layout helper and the RTL mirror constants. Runtime
    code must consume those helpers or derive from geometry at the point of use.
    """
    offenders = runtime_ddr_layout_literal_offenders()
    if offenders:
        fail(
            "runtime DDR frame layout literals must route through ddr_frame_layout derivation; "
            "found " + "; ".join(offenders[:8])
        )
    print("PASS runtime DDR frame layout literals are quarantined to layout derivation sources")


def tracked_product_relevant_files() -> list[Path]:
    """Return committed runtime/product files, excluding ignored worktree debris."""
    return tracked_files_under(*PRODUCT_AUDIT_ROOTS)


def runtime_ddr_layout_literal_offenders() -> list[str]:
    banned = re.compile(
        r"\b(?:0x3007_?F000|0x300F_?F000|0x3004_?0000|0x3008_?0000|"
        r"0x0008_?0000|0x0004_?0000|449280|115200)(?:u|U|ul|UL|ull|ULL)?\b",
        re.I,
    )
    allow = {
        DDR_FRAME_LAYOUT_HPP,
        DDR_FRAME_LAYOUT_SVH,
        MAILBOX_ABI_SPEC,
    }
    suffixes = {".cpp", ".hpp", ".h", ".sv", ".svh", ".v", ".py", ".sh"}
    offenders: list[str] = []
    for path in tracked_product_relevant_files():
        if not path.is_file() or path.suffix not in suffixes or path in allow:
            continue
        text = active_audit_text(path)
        for lineno, line in enumerate(text.splitlines(), 1):
            if banned.search(line):
                offenders.append(f"{path.relative_to(ROOT)}:{lineno}: {line.strip()}")
    return offenders


def check_runtime_ddr_layout_literal_ignores_untracked_debris() -> None:
    probe = ROOT / "arm/misterplexd/wgate_untracked_ddr_layout_literal_probe.cpp"
    check(not probe.exists(), f"untracked DDR layout literal probe already exists: {probe}")
    try:
        probe.write_text(
            "static constexpr unsigned kBadDdrStride = 0x80000u;\n"
            "static constexpr unsigned kBadDdrFrameBytes = 449280u;\n"
        )
        offenders = runtime_ddr_layout_literal_offenders()
        rel_probe = str(probe.relative_to(ROOT))
        check(
            not any(offender.startswith(f"{rel_probe}:") for offender in offenders),
            "runtime DDR frame layout literal scan must ignore untracked worktree debris",
        )
    finally:
        try:
            probe.unlink()
        except FileNotFoundError:
            pass
    print("PASS runtime DDR layout literal scan ignores untracked worktree debris")


def check_ddr_frame_store_yuv_read_contract() -> None:
    frame_store_source = select_default_sv_fault_branches(strip_comments(read(DDR_FRAME_STORE)))
    rtl = sv_module_text(frame_store_source, "ddr_frame_store")
    layout = strip_comments(read(DDR_FRAME_LAYOUT_SVH))
    nt = norm(rtl)

    coded_w = sv_const(layout, "DDR_FRAME_CODED_WIDTH")
    coded_h = sv_const(layout, "DDR_FRAME_CODED_HEIGHT")
    expected_y_offset = sv_const(layout, "DDR_FRAME_Y_PLANE_OFFSET")
    expected_u_offset = sv_const(layout, "DDR_FRAME_U_PLANE_OFFSET")
    expected_v_offset = sv_const(layout, "DDR_FRAME_V_PLANE_OFFSET")
    expected_y_stride = sv_const(layout, "DDR_FRAME_Y_STRIDE_BYTES")
    expected_c_stride = sv_const(layout, "DDR_FRAME_CHROMA_STRIDE_BYTES")

    def missing_requirements(text_norm: str) -> list[str]:
        required = [
            (
                "Y_LINE_QWORDS=CODED_W/8",
                "luma line fetch stride must be CODED_W/8 qwords",
            ),
            (
                "C_LINE_QWORDS=CODED_W/16",
                "chroma line fetch stride must be CODED_W/16 qwords (half-width bytes)",
            ),
            (
                "Y_PLANE_QWORDS=29'((CODED_W*CODED_H)/8)",
                "Y plane size in qwords must be coded_width*coded_height/8",
            ),
            (
                "C_PLANE_QWORDS=29'((CODED_W*CODED_H)/32)",
                "U/V plane size in qwords must be coded_width*coded_height/32",
            ),
            ("U_PLANE_BASE=Y_PLANE_QWORDS", "U read base must immediately follow Y"),
            (
                "V_PLANE_BASE=Y_PLANE_QWORDS+C_PLANE_QWORDS",
                "V read base must immediately follow U",
            ),
            (
                "u_addr=fill_bank_base+U_PLANE_BASE+fill_cy_qword+fill_qword_c",
                "U fetch address must use U_PLANE_BASE",
            ),
            (
                "v_addr=fill_bank_base+V_PLANE_BASE+fill_cy_qword+fill_qword_c",
                "V fetch address must use V_PLANE_BASE",
            ),
            (
                "chroma_addr=fill_plane_v?v_addr:u_addr",
                "chroma read address must select U while fill_plane_v=0, then V",
            ),
            (
                "line_addr=fill_is_chroma?chroma_addr:y_addr",
                "chroma fill path must issue the selected chroma address",
            ),
            # Prefetch/hit Y must follow vertical beam (rd_y_visible), never full
            # rd_visible. X-gating src_y→0 every HBlank thrashes want_y to line 0
            # and starves the beam line → left black prefix (parent median ~420 px).
            (
                "src_y_line=rd_y_visible?(display_y+CROP_TOP_L):'0",
                "line identity must track rd_y_visible (not X-gated rd_visible)",
            ),
            (
                "pref_y=WANT_Y_LINE_ONLY?src_y_line:src_y",
                "product pref_y must default to src_y_line (WANT_Y_LINE_ONLY); thrash control uses src_y",
            ),
            (
                "y_line_v2[video_slot]==Y_W'(pref_y)",
                "Y linebuf hit must match pref_y (product=src_y_line), not bare X-gated src_y",
            ),
            (
                "want_y_sys<=Y_W'(pref_y)",
                "want_y prefetcher must follow pref_y/src_y_line; src_y thrash is the left-edge class",
            ),
            # Sustained high-rate publish: same-cycle swap_req + vsync must not
            # NBA-clear swap_pending after latching a new pending_bank (playback
            # freeze while idle still animates).
            (
                "parameterbitSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1'b1",
                "product must default SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1",
            ),
            (
                "if(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC&&(swap_req_s2!=swap_req_seen))swap_pending<=1'b1;elseswap_pending<=1'b0;",
                "vsync swap must retain swap_pending when a new swap_req collides same cycle",
            ),
            # PLXD free_bank_mask: 00 while swap_pending else single free bit = ~disp.
            (
                "swap_pending_d2?2'b00:(disp_bank_d2?2'b01:2'b10)",
                "PLXD free_bank_mask must be 00 while pending else ~disp_bank",
            ),
            (
                "DDRAM_DIN<={frames_done_d2,12'd0,swap_pending_d2,disp_bank_d2,swap_pending_d2?2'b00:(disp_bank_d2?2'b01:2'b10),MAGIC_D}",
                "PLXD pack must use real frames_done (not vsync-only) + free/disp/pending",
            ),
            (
                "rd_cy=src_y_line[CODED_Y_W-1:1]",
                "chroma line lookup must halve src_y_line (same vertical beam as Y)",
            ),
            (
                "c_line_v2[video_slot]==(Y_W-1)'(rd_cy)",
                "chroma line-buffer hit must compare against the halved source Y",
            ),
            ("c_sel_r<=src_x[3:1]", "chroma byte select must halve the source X"),
            (
                "fill_cy_qword={{(30-Y_W){1'b0}},fill_cy}*C_LINE_QWORDS_W",
                "chroma DDR line address must stride by the chroma line width",
            ),
            ("u_pix=pick_byte(selected_u_q,c_sel_r)", "YUV converter U input must come from U RAM"),
            ("v_pix=pick_byte(selected_v_q,c_sel_r)", "YUV converter V input must come from V RAM"),
            ("r_calc_w=(y_ext<<<8)+(21'sd359*v_s)", "red channel must derive from V"),
            ("b_calc_w=(y_ext<<<8)+(21'sd454*u_s)", "blue channel must derive from U"),
        ]
        return [msg for needle, msg in required if needle not in text_norm]

    def enforce(text_norm: str, label: str) -> None:
        missing = missing_requirements(text_norm)
        if missing:
            fail(f"{label}: {missing[0]}")

    enforce(nt, "ddr_frame_store.sv")

    # Deliberate-fault proof: swapping the read bases in memory must make this
    # gate go red. This catches the exact symptom class where the ARM writes
    # byte-exact I420 but the RTL reads U from the V plane and V from the U plane.
    swapped = (
        nt.replace(
            "u_addr=fill_bank_base+U_PLANE_BASE+fill_cy_qword+fill_qword_c",
            "u_addr=fill_bank_base+V_PLANE_BASE+fill_cy_qword+fill_qword_c",
        )
        .replace(
            "v_addr=fill_bank_base+V_PLANE_BASE+fill_cy_qword+fill_qword_c",
            "v_addr=fill_bank_base+U_PLANE_BASE+fill_cy_qword+fill_qword_c",
        )
    )
    if not missing_requirements(swapped):
        fail("deliberately swapped U/V read bases did not make the DDR frame-store gate red")
    swapped_coeffs = (
        nt.replace(
            "r_calc_w=(y_ext<<<8)+(21'sd359*v_s)",
            "r_calc_w=(y_ext<<<8)+(21'sd359*u_s)",
        ).replace(
            "b_calc_w=(y_ext<<<8)+(21'sd454*u_s)",
            "b_calc_w=(y_ext<<<8)+(21'sd454*v_s)",
        )
    )
    if not missing_requirements(swapped_coeffs):
        fail("deliberately swapped YUV→RGB R/B chroma inputs did not make the gate red")
    bad_geometry = (
        nt.replace("rd_cy=src_y_line[CODED_Y_W-1:1]", "rd_cy=src_y_line[CODED_Y_W-2:0]")
        .replace("c_sel_r<=src_x[3:1]", "c_sel_r<=src_x[2:0]")
        .replace(
            "fill_cy_qword={{(30-Y_W){1'b0}},fill_cy}*C_LINE_QWORDS_W",
            "fill_cy_qword={{(30-Y_W){1'b0}},fill_cy}*Y_LINE_QWORDS_W",
        )
    )
    if not missing_requirements(bad_geometry):
        fail("deliberately broken chroma half-resolution geometry did not make the gate red")
    # Legacy left-edge class: want_y / hit from X-gated src_y (HEAD before src_y_line).
    thrash_want_y = (
        nt.replace("pref_y=WANT_Y_LINE_ONLY?src_y_line:src_y", "pref_y=src_y")
        .replace("want_y_sys<=Y_W'(pref_y)", "want_y_sys<=Y_W'(src_y)")
        .replace("y_line_v2[video_slot]==Y_W'(pref_y)", "y_line_v2[video_slot]==Y_W'(src_y)")
        .replace(
            "src_y_line=rd_y_visible?(display_y+CROP_TOP_L):'0",
            "src_y_line=rd_visible?(display_y+CROP_TOP_L):'0",
        )
    )
    if not missing_requirements(thrash_want_y):
        fail(
            "deliberately restored X-gated want_y/src_y thrash "
            "(left black-prefix class) did not make the DDR frame-store gate red"
        )
    drop_holds = nt.replace(
        "parameterbitSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1'b1",
        "parameterbitSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1'b0",
    ).replace(
        "if(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC&&(swap_req_s2!=swap_req_seen))swap_pending<=1'b1;elseswap_pending<=1'b0;",
        "swap_pending<=1'b0;",
    )
    if not missing_requirements(drop_holds):
        fail(
            "deliberately dropped SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC "
            "(same-cycle doorbell+vsync lost-pending class) did not make the gate red"
        )
    drop_plxd_free = nt.replace(
        "swap_pending_d2?2'b00:(disp_bank_d2?2'b01:2'b10)",
        "2'b11",
    )
    if not missing_requirements(drop_plxd_free):
        fail(
            "deliberately broken PLXD free_bank_mask packing "
            "(always both-free) did not make the gate red"
        )
    unused_module_decoy = frame_store_source.replace(
        "localparam int C_LINE_QWORDS = CODED_W / 16;",
        "localparam int C_LINE_QWORDS = FRAME_W / 16;",
        1,
    ) + "\nmodule wgate_unused_ddr_frame_store_decoy;\n  localparam int C_LINE_QWORDS = CODED_W / 16;\nendmodule\n"
    unused_module_decoy_nt = norm(sv_module_text(unused_module_decoy, "ddr_frame_store"))
    if not missing_requirements(unused_module_decoy_nt):
        fail("unused module decoy satisfied the DDR frame-store source-text gate")

    y_stride = coded_w
    c_stride = coded_w // 2
    y_offset = 0
    u_offset = coded_w * coded_h
    v_offset = u_offset + (coded_w // 2) * (coded_h // 2)
    check(
        (y_offset, u_offset, v_offset, y_stride, c_stride)
        == (
            expected_y_offset,
            expected_u_offset,
            expected_v_offset,
            expected_y_stride,
            expected_c_stride,
        ),
        "computed DDR frame-store read geometry does not match ratified 480p I420 layout: "
        f"computed Y/U/V offsets {y_offset}/{u_offset}/{v_offset}, strides "
        f"{y_stride}/{c_stride}; expected {expected_y_offset}/{expected_u_offset}/"
        f"{expected_v_offset}, strides {expected_y_stride}/{expected_c_stride}",
    )
    print(
        "PASS DDR frame-store YUV read contract "
        f"(Y={y_offset} U={u_offset} V={v_offset} strides Y={y_stride} C={c_stride}; "
        "deliberate U/V, R/B coefficient, and chroma-geometry faults go red)"
    )


def check_present_geometry_stride_contract() -> None:
    host = strip_comments(read(DDR_FRAME_LAYOUT_HPP))
    layout = strip_comments(read(DDR_FRAME_LAYOUT_SVH))
    media = strip_comments(read(MEDIA_PLAYER_CPP))
    ffmpeg_vf = strip_comments(read(FFMPEG_VF_HPP))
    fb_present = strip_comments(read(FB_PRESENT_CPP))
    frame_store = sv_module_text(
        select_default_sv_fault_branches(strip_comments(read(DDR_FRAME_STORE))),
        "ddr_frame_store",
    )
    present_core = sv_module_text(strip_comments(read(PRESENT_CORE)), "present_core")
    qsf = read(PLEX_QSF)

    host_nt = norm(host)
    media_nt = norm(media)
    ffmpeg_vf_nt = norm(ffmpeg_vf)
    fb_nt = norm(fb_present)
    frame_nt = norm(frame_store)
    present_nt = norm(present_core)
    qsf_nt = norm(qsf)

    coded_w = cpp_const(host, "kPlex480pCodedWidth")
    coded_h = cpp_const(host, "kPlex480pCodedHeight")
    display_w = cpp_const(host, "kPlex480pDisplayWidth")
    presented_w = cpp_const(host, "kPlex480pPresentedWidth")
    crop_right = cpp_const(host, "kPlex480pCropRight")
    pillar_left = cpp_const(host, "kPlex480pPillarboxLeft")
    pillar_right = cpp_const(host, "kPlex480pPillarboxRight")
    y_stride = cpp_const(host, "kPlex480pYStrideBytes")
    c_stride = cpp_const(host, "kPlex480pChromaStrideBytes")
    y_offset = cpp_const(host, "kPlex480pYPlaneOffset")
    u_offset = cpp_const(host, "kPlex480pUPlaneOffset")
    v_offset = cpp_const(host, "kPlex480pVPlaneOffset")
    y_bytes = cpp_const(host, "kPlex480pYuv420pBytes")

    check(
        (coded_w, coded_h, display_w, presented_w, crop_right, pillar_left, pillar_right)
        == (624, 480, 618, 640, 6, 11, 11),
        "480p geometry contract changed unexpectedly. If the PMS/profile target changed, "
        "update the geometry table, visual provenance, and this stride gate together.",
    )
    check(
        (y_stride, c_stride, y_offset, u_offset, v_offset, y_bytes)
        == (624, 312, 0, 299520, 374400, 449280),
        "480p I420 byte layout changed unexpectedly. The product path must declare any "
        "stride/offset change before grading distorted-video reports.",
    )

    def missing_stride_requirements(
        host_norm: str, media_norm: str, frame_norm: str, vf_norm: str
    ) -> list[str]:
        required = [
            (
                host_norm,
                "constuint64_tlineBytes=static_cast<uint64_t>(geom.coded_width.get())",
                "ARM layout must derive luma stride from coded_width (624), not display/presented width",
            ),
            (
                host_norm,
                "constuint64_tchromaLineBytes=static_cast<uint64_t>(geom.coded_width.get()/2)",
                "ARM layout must derive chroma stride from coded_width/2 (312), not cropped width/2",
            ),
            (
                host_norm,
                "constuint32_tyBytes=static_cast<uint32_t>(codedPixelCount(geom.coded_width,geom.coded_height))",
                "ARM plane offsets must use coded_width*coded_height for Y bytes",
            ),
            (
                host_norm,
                "if(width==kPlex480pPresentedWidth&&height==kPlex480pPresentedHeight)returnplex480pDdrFrameGeometry();",
                "640x480 presentation must map to the declared 624x480 coded / 618x480 display geometry",
            ),
            (
                host_norm,
                "inlineDdrFrameGeometryproductDdrFrameStoreGeometry(){returnplex480pDdrFrameGeometry();}",
                "product silicon canvas helper must alias the declared 624x480 plex480p contract",
            ),
            (
                host_norm,
                "inlineDdrFrameGeometryddrFrameGeometryForFpgaPresent(CodedWidth",
                "FPGA present path must route every decode tier through ddrFrameGeometryForFpgaPresent",
            ),
            (
                # Full body pin: decode WxH is ignored; always silicon 624 canvas.
                # Reverting this to makeDdrFrameGeometry(decodeW,decodeH) is the
                # classic ARM line_bytes=320 vs RTL CODED_W=624 shear.
                host_norm,
                "inlineDdrFrameGeometryddrFrameGeometryForFpgaPresent(CodedWidth,CodedHeight)"
                "{returnproductDdrFrameStoreGeometry();}",
                "ddrFrameGeometryForFpgaPresent must ignore DECODE and return productDdrFrameStoreGeometry (624)",
            ),
            (
                media_norm,
                "wantFpgaDdrCanvas?ddrFrameGeometryForFpgaPresent(outW_,outH_)",
                "PRESENT=fpga|both must select silicon canvas geometry, never identity-320 from DECODE",
            ),
            (
                media_norm,
                "constintrawW=ddrGeometry.coded_width.get();",
                "FFmpeg rawvideo width must be the coded stride width (624) for FPGA-presented 480p",
            ),
            (
                media_norm,
                "constintrawDisplayW=ddrGeometry.display_width.get();",
                "FFmpeg visible scale width must be the cropped display width (618)",
            ),
            (
                media_norm,
                "constFfmpegVfPlanvfPlan=buildFfmpegVideoFilter(vfReq);",
                "FFmpeg -vf must be built via buildFfmpegVideoFilter (scale policy lives in ffmpeg_vf.hpp)",
            ),
            (
                vf_norm,
                # Center inside the display window (crop_left/top is display origin in coded,
                # not a left/top-align of the scaled picture). Matches packYuv origin policy.
                'returnscaleFilterGeom(displayScale,sws_flags)+":force_original_aspect_ratio=decrease,pad="+scale+":"+padX+":"+padY+":color=black";',
                "FFmpeg must scale into display geometry then center-pad into the coded 624-pixel stride",
            ),
            (
                media_norm,
                "clearYuv420pCropPadding(frame.data(),ddrGeometry)",
                "rawvideo DDR frames must blacken coded crop padding before the frame-store reads them",
            ),
            (
                media_norm,
                "clearPlane(yuv+yBytes,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackU)",
                "U crop padding must use chroma stride coded_width/2 (312) and half-resolution crop",
            ),
            (
                media_norm,
                "clearPlane(yuv+yBytes+cW*cH,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackV)",
                "V crop padding must use chroma stride coded_width/2 (312) and half-resolution crop",
            ),
            (
                media_norm,
                "DdrPublishFrameframe{txFrame,txBytes,ddrGeometry,DdrFrameFormat::Yuv420p};ok=publishDdrFrame(frame,\"playbackDDR\",&ddrErr)",
                "rawvideo present must carry the same declared geometry that selected FFmpeg's coded stride into centralized publishDdrFrame",
            ),
            (
                frame_norm,
                "Y_LINE_QWORDS=CODED_W/8",
                "RTL luma DDR line stride must be CODED_W/8 qwords (624 bytes), not FRAME_W/8",
            ),
            (
                frame_norm,
                "C_LINE_QWORDS=CODED_W/16",
                "RTL chroma DDR line stride must be CODED_W/16 qwords (312 bytes), not display/FRAME width",
            ),
            (
                # DDR row pitch in the fill FSM — this is the reader stride that must
                # match ARM line_bytes. Default CODED_W=FRAME_W (640) would walk 640 B/line
                # while the writer lays 624 B/line → 16 px leftward creep per scanline.
                frame_norm,
                "fill_y_qword={{(29-Y_W){1'b0}},fill_y}*Y_LINE_QWORDS_W",
                "RTL DDR Y fill address must step by Y_LINE_QWORDS (CODED_W/8), never FRAME_W",
            ),
            (
                frame_norm,
                "PRESENT_END_X=X_W'(PRESENT_X+DISPLAY_W)",
                "RTL visible area must end at pillar_left + display_width, leaving the right pillar outside DDR",
            ),
            (
                frame_norm,
                "src_x=rd_visible?(display_x+CROP_LEFT_L):'0",
                "RTL source X must crop from display_x into coded coordinates exactly once",
            ),
            (
                frame_norm,
                "fill_cy_qword={{(30-Y_W){1'b0}},fill_cy}*C_LINE_QWORDS_W",
                "RTL chroma fetch address must stride by 312-byte chroma lines",
            ),
            (
                # Product path is planar YUV420p. RGB565_LINE_QWORDS must not appear in
                # the store body (kills the "640 px RGB565 vs 624 pitch" theory for DDR).
                frame_norm,
                "Y_PLANE_QWORDS=29'((CODED_W*CODED_H)/8)",
                "RTL product DDR store is YUV planar (Y plane qwords from CODED_W*CODED_H), not RGB565",
            ),
            (
                frame_norm,
                "rd_miss_now=rd_active&&rd_visible&&has_frame&&(!y_hit_now||!c_hit_now)",
                "RTL must black on linebuf miss — mid-line late-hit is the other ragged-left mechanism",
            ),
        ]
        return [msg for haystack, needle, msg in required if needle not in haystack]

    missing = missing_stride_requirements(host_nt, media_nt, frame_nt, ffmpeg_vf_nt)
    if missing:
        fail(f"present geometry/stride contract: {missing[0]}")

    def present_ddr_wiring_ok(p_nt: str) -> bool:
        return (
            ".FRAME_W(FRAME_W)" in p_nt
            and ".FRAME_H(FRAME_H)" in p_nt
            and ".CODED_W(DDR_FRAME_CODED_WIDTH)" in p_nt
            and ".DISPLAY_W(DDR_FRAME_DISPLAY_WIDTH)" in p_nt
            and ".PRESENT_X(DDR_FRAME_PILLARBOX_LEFT)" in p_nt
            and ".HPS_BANK_STRIDE_BYTES(DDR_FRAME_YUV420P_BANK_STRIDE)" in p_nt
            and ".DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS)" in p_nt
        )

    check(
        present_ddr_wiring_ok(present_nt),
        "present_core must instantiate ddr_frame_store from the shared layout params: "
        "FRAME_W=640 for scanout, CODED_W=624 for DDR stride, DISPLAY_W=618 for crop, "
        "PRESENT_X=11 for pillarbox.",
    )
    check(
        'set_global_assignment-nameVERILOG_MACRO"DDR_FRAME_STORE=1"' in qsf_nt
        and 'set_global_assignment-nameVERILOG_MACRO"FRAME_W=640"' in qsf_nt
        and 'set_global_assignment-nameVERILOG_MACRO"FRAME_H=480"' in qsf_nt,
        "Quartus build must declare DDR_FRAME_STORE with 640x480 presented scanout. "
        "A missing/changed FRAME_W silently changes the frame-store scanout geometry.",
    )
    check(
        "uPlane=yPlane+static_cast<size_t>(w)*static_cast<size_t>(h)" in fb_nt
        and "vPlane=uPlane+static_cast<size_t>(w/2)*static_cast<size_t>(h/2)" in fb_nt,
        "fb0 YUV reference blit must use the supplied coded width as stride and "
        "coded_width/2 as chroma stride.",
    )

    bad_host_presented_stride = host_nt.replace(
        "constuint64_tlineBytes=static_cast<uint64_t>(geom.coded_width.get())",
        "constuint64_tlineBytes=static_cast<uint64_t>(geom.presented_width.get())",
    )
    if not missing_stride_requirements(bad_host_presented_stride, media_nt, frame_nt, ffmpeg_vf_nt):
        fail("deliberately changed ARM luma stride 624→640 did not make the geometry gate red")
    bad_media_display_stride = media_nt.replace(
        "constintrawW=ddrGeometry.coded_width.get();",
        "constintrawW=ddrGeometry.display_width.get();",
    )
    if not missing_stride_requirements(host_nt, bad_media_display_stride, frame_nt, ffmpeg_vf_nt):
        fail("deliberately changed FFmpeg raw stride 624→618 did not make the geometry gate red")
    bad_chroma_stride = frame_nt.replace("C_LINE_QWORDS=CODED_W/16", "C_LINE_QWORDS=FRAME_W/16")
    if not missing_stride_requirements(host_nt, media_nt, bad_chroma_stride, ffmpeg_vf_nt):
        fail("deliberately changed RTL chroma stride 312→320 did not make the geometry gate red")
    bad_luma_stride_frame_w = frame_nt.replace(
        "Y_LINE_QWORDS=CODED_W/8", "Y_LINE_QWORDS=FRAME_W/8"
    )
    if not missing_stride_requirements(host_nt, media_nt, bad_luma_stride_frame_w, ffmpeg_vf_nt):
        fail(
            "deliberately changed RTL luma stride CODED_W/8→FRAME_W/8 "
            "(640 B/line reader vs 624 B writer = 16 px/line shear) did not make the gate red"
        )
    # Classic shear: FPGA-present geometry follows DECODE (320) instead of silicon 624.
    bad_fpga_present_identity = host_nt.replace(
        "inlineDdrFrameGeometryddrFrameGeometryForFpgaPresent(CodedWidth,CodedHeight)"
        "{returnproductDdrFrameStoreGeometry();}",
        "inlineDdrFrameGeometryddrFrameGeometryForFpgaPresent(CodedWidthw,CodedHeighth)"
        "{returnmakeDdrFrameGeometry(w,h);}",
    )
    if not missing_stride_requirements(bad_fpga_present_identity, media_nt, frame_nt, ffmpeg_vf_nt):
        fail(
            "deliberately reverted ddrFrameGeometryForFpgaPresent to identity-DECODE "
            "(320-wide writer vs 624 RTL) did not make the geometry gate red"
        )
    bad_media_identity = media_nt.replace(
        "wantFpgaDdrCanvas?ddrFrameGeometryForFpgaPresent(outW_,outH_)",
        "wantFpgaDdrCanvas?makeDdrFrameGeometry(outW_,outH_)",
    )
    if not missing_stride_requirements(host_nt, bad_media_identity, frame_nt, ffmpeg_vf_nt):
        fail(
            "deliberately selected identity-DECODE geometry on PRESENT=fpga "
            "did not make the geometry gate red"
        )
    # Dropping the explicit CODED_W port leaves parameter default CODED_W=FRAME_W=640
    # → reader Y pitch 640 B/line while ARM writes 624 → 16 px/line leftward creep.
    present_drop_coded = present_nt.replace(".CODED_W(DDR_FRAME_CODED_WIDTH)", "")
    if present_ddr_wiring_ok(present_drop_coded):
        fail(
            "deliberately dropping .CODED_W(DDR_FRAME_CODED_WIDTH) "
            "(default CODED_W=FRAME_W=640 shear) did not make the wiring gate red"
        )

    # Product DDR is YUV: RGB565 line-qword constant must not drive the store body.
    check(
        "RGB565_LINE_QWORDS" not in frame_nt and "DDR_FRAME_RGB565" not in frame_nt,
        "ddr_frame_store must not reference RGB565 line geometry "
        "(product path is YUV420p; 640×2 vs 624×2 RGB pitch theory does not apply)",
    )

    # Arithmetic pin: writer 624 B/line vs reader default-640 B/line = 16 B = 16 px/line.
    coded_w = cpp_const(strip_comments(read(DDR_FRAME_LAYOUT_HPP)), "kPlex480pCodedWidth")
    presented_w = cpp_const(strip_comments(read(DDR_FRAME_LAYOUT_HPP)), "kPlex480pPresentedWidth")
    check(coded_w == 624 and presented_w == 640, "coded/presented constants drifted")
    check(
        (presented_w - coded_w) == 16,
        "expected 16 px creep if reader wrongly used FRAME_W pitch against coded writer",
    )

    print(
        "PASS present geometry/stride chain is declared end-to-end "
        "(coded 624 stride, display 618 crop, presented 640 with 11px pillars, chroma stride 312)"
    )
    print(
        "PASS reader pitch is YUV CODED_W (not RGB565/FRAME_W); "
        "CODED_W port + Y_LINE_QWORDS=CODED_W/8 red-checks armed; "
        "NOTE: constant parity is BLIND to mid-line linebuf miss shear "
        "(rd_miss_now→black) — that needs sim/fit, not define-parity"
    )


def check_ddr_bank_handoff_contract() -> None:
    fpga_cpp = strip_comments(read(FPGA_SPI_CPP))
    fpga_h = strip_comments(read(FPGA_SPI_HPP))
    media = strip_comments(read(MEDIA_PLAYER_CPP))
    frame_store = sv_module_text(
        select_default_sv_fault_branches(strip_comments(read(DDR_FRAME_STORE))),
        "ddr_frame_store",
    )
    fpga_nt = norm(fpga_cpp)
    fpga_h_nt = norm(fpga_h)
    media_nt = norm(media)
    frame_nt = norm(frame_store)

    def missing_handoff_requirements(
        cpp_norm: str, h_norm: str, media_norm: str, rtl_norm: str
    ) -> list[str]:
        required = [
            (
                cpp_norm,
                "constexprintkDdrBankReuseMinUs=40000;",
                "ARM DDR writer must enforce a same-bank reuse floor of at least two vsyncs",
            ),
            (
                h_norm,
                "doublelastDdrBankDoorbellMs_[2]={-1.0,-1.0};",
                "ARM DDR writer must remember when each bank was last published",
            ),
            (
                h_norm,
                "int64_tbank_reuse_wait_us=0;",
                "DDR timing telemetry must expose any same-bank reuse wait",
            ),
            (
                media_norm,
                "ddr_bank_reuse_wait_us_p=",
                "present_profile logs must surface same-bank reuse waits by name",
            ),
            (
                media_norm,
                "prof.ddrBankReuseWaitUs+=dt.bank_reuse_wait_us;",
                "present_profile must accumulate writer-side same-bank reuse waits",
            ),
            (
                cpp_norm,
                "constdoublelastBankMs=lastDdrBankDoorbellMs_[bank];",
                "sendDdrFrame must check the selected bank's last doorbell time before copying",
            ),
            (
                cpp_norm,
                "if(sinceUs<kDdrBankReuseMinUs)",
                "sendDdrFrame must wait rather than reusing the same bank before the reuse floor",
            ),
            (
                cpp_norm,
                "timing.bank_reuse_wait_us=waitUs;",
                "same-bank reuse waits must be externally visible in DDR timing telemetry",
            ),
            (
                cpp_norm,
                "std::memcpy(ddrMap_+bankOff,payload,len);__sync_synchronize();",
                "payload writes must be fenced before any doorbell can publish the bank",
            ),
            (
                cpp_norm,
                "dw[1]=hi;__sync_synchronize();dw[0]=kDdrDoorbellMagic;__sync_synchronize();",
                "doorbell must publish the bank/format/seq token before PLXK magic so a cold "
                "mailbox cannot expose magic with a zero/old format",
            ),
            (
                cpp_norm,
                "lastDdrBankDoorbellMs_[bank]=std::chrono::duration<double,std::milli>",
                "sendDdrFrame must record the successful publish time for the bank it just rang",
            ),
            (
                rtl_norm,
                "db_token=DDRAM_DOUT[63:32]",
                "frame-store reader must capture bank/format/seq as one 32-bit token from one DDR read",
            ),
            (
                rtl_norm,
                "db_format=db_token[30:29]",
                "frame-store reader must decode format from the same token as seq/bank",
            ),
            (
                rtl_norm,
                "db_token_new=db_valid_token&&(!have_seq||(db_token!=last_seq))",
                "frame-store reader must compare the whole token, not bank and seq from separate reads",
            ),
            (
                rtl_norm,
                "pending_bank_ddr<=DDRAM_DOUT[63];",
                "frame-store reader must latch the bank bit from the same DDR word that supplied seq",
            ),
            (
                rtl_norm,
                "last_seq<=db_token;",
                "frame-store reader must store the full token it consumed, preventing bank/seq torn reads",
            ),
        ]
        return [msg for haystack, needle, msg in required if needle not in haystack]

    missing = missing_handoff_requirements(fpga_nt, fpga_h_nt, media_nt, frame_nt)
    if missing:
        fail(f"DDR bank handoff contract: {missing[0]}")

    no_reuse_wait = fpga_nt.replace(
        "if(sinceUs<kDdrBankReuseMinUs)",
        "if(false)",
    )
    if not missing_handoff_requirements(no_reuse_wait, fpga_h_nt, media_nt, frame_nt):
        fail("deliberately removed same-bank reuse wait did not make the handoff gate red")
    bad_doorbell_order = fpga_nt.replace(
        "dw[1]=hi;__sync_synchronize();dw[0]=kDdrDoorbellMagic;__sync_synchronize();",
        "dw[0]=kDdrDoorbellMagic;dw[1]=hi;__sync_synchronize();",
    )
    if not missing_handoff_requirements(bad_doorbell_order, fpga_h_nt, media_nt, frame_nt):
        fail("deliberately reordered doorbell magic before token did not make the handoff gate red")
    torn_token_reader = frame_nt.replace(
        "last_seq<=db_token;",
        "last_seq<=DDRAM_DOUT[62:32];",
    )
    if not missing_handoff_requirements(fpga_nt, fpga_h_nt, media_nt, torn_token_reader):
        fail("deliberately split bank/seq token in RTL reader did not make the handoff gate red")

    print(
        "PASS DDR bank handoff publishes fenced frames and guards same-bank reuse "
        "(PLXD bank-release ACK at 0x3007F128)"
    )


def check_plxd_liveness_degeneracy() -> None:
    """Instrument-integrity #18: ensure PLXD consumer has stale-buffer detection."""
    fpga_cpp = strip_comments(read(FPGA_SPI_CPP))
    fpga_h = strip_comments(read(FPGA_SPI_HPP))
    cpp_nt = norm(fpga_cpp)
    h_nt = norm(fpga_h)

    # Key signals of degeneracy defence in the PLXD consumer:
    required = [
        (h_nt, "plxdStaleCount_", "PLXD consumer must track consecutive stale reads"),
        (h_nt, "plxdLivenessProven_", "PLXD consumer must record whether liveness was ever proven"),
        (cpp_nt, "plxdStaleCount_", "sendDdrFrame must increment stale count when frames_done unchanged"),
        (cpp_nt, "plxdLivenessProven_=true", "sendDdrFrame must mark liveness proven on first advance"),
        (cpp_nt, "[STALE]", "sendDdrFrame must log LOUD when mailbox is stale"),
    ]
    missing = [msg for haystack, needle, msg in required if needle not in haystack]
    if missing:
        fail(f"PLXD liveness/degeneracy defence missing: {missing[0]}")

    # Red-proof: removing the stale detection must make the gate fail.
    poisoned = h_nt.replace("plxdStaleCount_", "")
    missing_poisoned = [msg for haystack, needle, msg in [
        (poisoned, "plxdStaleCount_", "PLXD consumer must track consecutive stale reads"),
    ] if needle not in haystack]
    if not missing_poisoned:
        fail("deliberately removed stale counter did not make the liveness gate red")

    print("PASS PLXD consumer has stale-buffer degeneracy defence (#18)")


def check_yuv_ddr_writer_contract() -> None:
    media = strip_comments(read(MEDIA_PLAYER_CPP))
    fb_present = strip_comments(read(FB_PRESENT_CPP))
    main_cpp = strip_comments(read(MISTERPLEXD_MAIN_CPP))
    fpga_h = strip_comments(read(FPGA_SPI_HPP))
    fpga_cpp = strip_comments(read(FPGA_SPI_CPP))
    layout_h = strip_comments(read(DDR_FRAME_LAYOUT_HPP))
    recon_h = strip_comments(read(H264_RECON_HPP))
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
        "index == 1" in fpga_cpp
        and "non-YUV frame send refused" in fpga_cpp
        and "push_frame --ddr --yuv420p" in fpga_cpp,
        "FpgaSpi::sendFileTx must refuse F1/SPI frame sends with a named non-YUV error. "
        "The YUV420p DDR contract is not enforced if callers can still silently push RGB565 "
        "through the legacy F1 ioctl path.",
    )
    check(
        "DDR_FRAME_FORMAT" in main_cpp
        and "fixed to yuv420p" in main_cpp
        and "DdrFrameFormat::Rgb565" not in main_cpp,
        "misterplexd main must not allow DDR_FRAME_FORMAT=rgb565 to reactivate the old "
        "writer. Keep any legacy config key as an ignored warning and leave production fixed "
        "to yuv420p.",
    )

    media_nt = norm(media)
    fb_nt = norm(fb_present)
    fpga_nt = norm(fpga_cpp)
    recon_nt = norm(recon_h)

    def missing_arm_yuv_requirements(
        media_norm: str, fb_norm: str, fpga_norm: str, recon_norm: str
    ) -> list[str]:
        required = [
            (
                media_norm,
                'caseRawVideoFormat::Yuv420p:return"yuv420p";',
                "FFmpeg rawvideo output must request yuv420p/I420 for DDR YUV mode",
            ),
            (
                media_norm,
                "wantYuvDdr=wantFpgaFrameStore&&ddrFrameFormat_==DdrFrameFormat::Yuv420p",
                "FPGA DDR presentation must select the YUV420p rawvideo decoder output mode",
            ),
            (
                media_norm,
                "if(wantYuvDdr){videoFmt=RawVideoFormat::Yuv420p;}",
                "DDR YUV mode must force the FFmpeg pipe format to yuv420p/I420",
            ),
            (
                media_norm,
                'args.push_back("-pix_fmt");args.push_back(ffmpegPixFmt(videoFmt));',
                "FFmpeg invocation must bind -pix_fmt to the selected yuv420p/I420 decoder output",
            ),
            (
                media_norm,
                "caseRawVideoFormat::Yuv420p:returnyuv420pFrameBytes(width,height);",
                "YUV420p frame byte count must be coded_width*coded_height*3/2",
            ),
            (
                media_norm,
                "n=::read(rfd,frame.data()+got,frameBytes-got);",
                "decoded rawvideo bytes must be read contiguously into frame.data()",
            ),
            (
                media_norm,
                "constuint8_t*txFrame=cleanFrame;",
                "DDR send must use the clean frame pointer, not a remapped chroma scratch buffer",
            ),
            (
                media_norm,
                "size_ttxBytes=frameBytes;",
                "DDR send length must remain the full contiguous yuv420p frame size",
            ),
            (
                media_norm,
                "presentCleanFrame(frame.data(),true);",
                "product playback must present the contiguous FFmpeg yuv420p pipe buffer",
            ),
            (
                media_norm,
                "clearPlane(yuv+yBytes,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackU)",
                "crop padding must treat offset yBytes as the U/Cb plane",
            ),
            (
                media_norm,
                "clearPlane(yuv+yBytes+cW*cH,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackV)",
                "crop padding must treat offset yBytes+cBytes as the V/Cr plane",
            ),
            (
                media_norm,
                "std::memcpy(yuv420p.data()+yBytes,rec.u.data(),cBytes)",
                "host recon staging must copy rec.u to the U/Cb plane at offset yBytes",
            ),
            (
                media_norm,
                "std::memcpy(yuv420p.data()+yBytes+cBytes,rec.v.data(),cBytes)",
                "host recon staging must copy rec.v to the V/Cr plane after U",
            ),
            (
                media_norm,
                "DdrPublishFrameframe{txFrame,txBytes,ddrGeometry,DdrFrameFormat::Yuv420p};ok=publishDdrFrame(frame,\"playbackDDR\",&ddrErr)",
                "product rawvideo DDR publish must pass the yuv420p frame buffer and geometry unchanged",
            ),
            (
                fpga_norm,
                "DdrPublishFrameframe{yuv420p,len,geometry,DdrFrameFormat::Yuv420p};returnpublishDdrFrame(frame,bank)",
                "sendYuv420pFrameDdr must wrap the yuv420p pointer and geometry without plane remap",
            ),
            (
                fpga_norm,
                "std::memcpy(ddrMap_+bankOff,payload,len)",
                "DDR writer must copy the contiguous Y,U,V payload into the bank without plane remap",
            ),
            (
                fb_norm,
                "uPlane=yPlane+static_cast<size_t>(w)*static_cast<size_t>(h)",
                "fb0 reference blit must locate U immediately after Y",
            ),
            (
                fb_norm,
                "vPlane=uPlane+static_cast<size_t>(w/2)*static_cast<size_t>(h/2)",
                "fb0 reference blit must locate V immediately after U",
            ),
            (
                fb_norm,
                "pixel::yuvToRgb(yRow[x],uRow[x/2],vRow[x/2],r,g,b)",
                "fb0 reference blit must feed yuvToRgb as Y,U,V",
            ),
            (
                recon_norm,
                "uint8_t*planes[2]={out.u.data(),out.v.data()}",
                "host H.264 recon chroma component order must be U/Cb then V/Cr",
            ),
            (
                recon_norm,
                "int16_tdcU[2][2],dcV[2][2]",
                "host H.264 recon must keep first/second chroma DC blocks as U then V",
            ),
            (
                recon_norm,
                "int16_t(*dcs[2])[2][2]={&dcU,&dcV}",
                "host H.264 recon must add chroma residuals to U then V planes",
            ),
        ]
        return [msg for haystack, needle, msg in required if needle not in haystack]

    missing = missing_arm_yuv_requirements(media_nt, fb_nt, fpga_nt, recon_nt)
    if missing:
        fail(f"ARM YUV420 DDR plane contract: {missing[0]}")

    swapped_media = (
        media_nt.replace(
            "std::memcpy(yuv420p.data()+yBytes,rec.u.data(),cBytes)",
            "std::memcpy(yuv420p.data()+yBytes,rec.v.data(),cBytes)",
        )
        .replace(
            "std::memcpy(yuv420p.data()+yBytes+cBytes,rec.v.data(),cBytes)",
            "std::memcpy(yuv420p.data()+yBytes+cBytes,rec.u.data(),cBytes)",
        )
        .replace(
            "clearPlane(yuv+yBytes,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackU)",
            "clearPlane(yuv+yBytes,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackV)",
        )
        .replace(
            "clearPlane(yuv+yBytes+cW*cH,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackV)",
            "clearPlane(yuv+yBytes+cW*cH,cW,cW,cH,g.crop_left/2,g.crop_right/2,g.crop_top/2,g.crop_bottom/2,kYuv420BlackU)",
        )
    )
    if not missing_arm_yuv_requirements(swapped_media, fb_nt, fpga_nt, recon_nt):
        fail("deliberately swapped ARM U/V staging did not make the YUV420 DDR plane gate red")
    remapped_fpga = fpga_nt.replace(
        "returnsendDdrFrame(yuv420p,len,bank)",
        "returnsendDdrFrame(remapYuv420pForDdr(yuv420p),len,bank)",
    ).replace(
        "std::memcpy(ddrMap_+bankOff,payload,len)",
        "copyYv12PlanesToDdr(ddrMap_+bankOff,payload,len)",
    )
    if not missing_arm_yuv_requirements(media_nt, fb_nt, remapped_fpga, recon_nt):
        fail("deliberately remapped rawvideo DDR payload did not make the YUV420 DDR plane gate red")
    print(
        "PASS ARM DDR writer keeps FFmpeg yuv420p/I420 order "
        "(Y then U/Cb then V/Cr) through the product DDR path"
    )

    compact_media = norm(media)
    check(
        "renderIdleYuv420p" in media
        and "DdrPublishFrameframe{yuv.data(),yuv.size(),g,DdrFrameFormat::Yuv420p};ok=publishDdrFrame(frame,\"idleDDR\",&ddrErr)" in compact_media,
        "MediaPlayer::paintIdle must send the rendered logo/screensaver through the YUV420p "
        "DDR path. A hard-coded black I420 payload clears stale video but makes the selectable "
        "FPGA idle logo/screensaver disappear under PRESENT=fpga.",
    )

    # Silent PRESENT=fb0 default froze core HDMI idle (user ×2). Product default is fpga;
    # initPresent must open FPGA for every non-none PRESENT (fb0 alone is not enough).
    main_cpp = read(ROOT / "arm/misterplexd/main.cpp")
    media_hpp = read(ROOT / "arm/misterplexd/media_player.hpp")
    check(
        'std::string presentMode = "fpga"' in main_cpp
        and 'std::string presentMode_ = "fpga"' in media_hpp
        and 'std::string presentMode = "fb0"' not in main_cpp
        and 'std::string presentMode_ = "fb0"' not in media_hpp,
        "misterplexd PRESENT default must be fpga (not fb0). fb0 skipped fpga_.open() and "
        "froze the selectable idle screen on the last latched DDR frame.",
    )
    check(
        "wantFpga = true" in media or "const bool wantFpga = true" in media,
        "initPresent must always open the FPGA path for non-none PRESENT so idle/OSD can "
        "repaint the core frame store even when conf says PRESENT=fb0.",
    )
    check(
        "ERROR FPGA SPI unavailable" in media
        and "ERROR idle cannot open FPGA" in media,
        "Missing FPGA present path must log ERROR (silence was the defect).",
    )
    check(
        "sendRgb24Frame(buf.data(),w,h,/*F1*/1)" not in compact_media
        and "sendRgb24Frame(buf.data(),w,h,1)" not in compact_media
        and "sendRgb565Bytes(txFrame,txBytes,/*F1*/1)" not in compact_media
        and "sendRgb565Bytes(txFrame,txBytes,1)" not in compact_media
        and "useDdrF1_=false" not in compact_media
        and "RGB F1 fallback" not in media,
        "media_player.cpp still has an RGB/SPI F1 fallback or disables future DDR attempts "
        "after a failure. That can hide a DDR YUV420p refusal and re-create the frozen-screen "
        "measurement failure; F1 product presentation must fail loudly and keep reporting DDR "
        "failure instead.",
    )
    idle_publish = (
        "DdrPublishFrameframe{yuv.data(),yuv.size(),g,DdrFrameFormat::Yuv420p};"
        "ok=publishDdrFrame(frame,\"idleDDR\",&ddrErr)"
    )
    idle_black_payload_patterns = [
        "memset(yuv.data(),kYuv420BlackY,yBytes)",
        "memset(yuv.data(),0,yuv.size())",
        "std::fill(yuv.begin(),yuv.end(),0)",
        "std::fill(yuv.begin(),yuv.end(),kYuv420BlackY)",
        "std::fill_n(yuv.data(),yuv.size(),0)",
    ]
    for pat in idle_black_payload_patterns:
        check(
            pat not in compact_media,
            "MediaPlayer::paintIdle still constructs or overwrites an all-black DDR idle "
            "payload. That is only valid for IDLE_SCREEN=black; logo/screensaver modes must "
            "preserve the idle renderer.",
        )
    black_fill_idle = compact_media.replace(
        idle_publish,
        "std::fill(yuv.begin(),yuv.end(),0);" + idle_publish,
    )
    if not any(pat in black_fill_idle for pat in idle_black_payload_patterns):
        fail("deliberately black-filled idle DDR payload did not make the idle-renderer gate red")
    tooling = "\n".join(
        [
            strip_comments(read(VALIDATE_PLAYBACK_HW_SH)),
            strip_comments(read(TEST_DDR_FRAME_SH)),
            strip_comments(read(TEST_FPGA_PUSH_SH)),
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
    check(
        "push_frame --index 1" not in tooling and "plex_test_320x240.rgb565" not in tooling,
        "Hardware helpers/docs still exercise the retired RGB565 SPI F1 frame path. That path "
        "must not be used as a product fallback or hardware gate; use push_frame --ddr "
        "--yuv420p.",
    )
    push_frame = strip_comments(read(PUSH_FRAME_CPP))
    gen_edge = read(GEN_EDGE_MARKERS_PY)
    check(
        "non-YUV frame send refused" in push_frame
        and "F1 frame-store path is DDR YUV420p only" in push_frame
        and "usage: push_frame --ddr" in push_frame
        and "push_frame [--index 1]" not in push_frame,
        "push_frame must make the F1 format contract executable: default/legacy F1 sends and "
        "--rgb24 must fail with a named non-YUV refusal, not silently push RGB.",
    )
    check(
        'default="yuv420p"' in gen_edge and 'default="rgb24"' not in gen_edge,
        "gen_edge_markers.py must default to the frame-store-safe YUV420p fixture. A default "
        "RGB24 fixture is too easy to feed into the DDR push path during hardware triage.",
    )
    forbidden_repo_patterns = [
        re.compile(r"sendRgb(?:24|565)FrameDdr"),
        re.compile(r"sendRgb24Frame\(buf\.data\(\),[^\n;]*(?:/\*F1\*/\s*)?1\)"),
        re.compile(r"sendRgb565Bytes\(txFrame,[^\n;]*(?:/\*F1\*/\s*)?1\)"),
        re.compile(r"--ddr\s+--rgb24"),
        re.compile(r"push_frame\s+--ddr[^\n]*\.rgb565"),
        re.compile(r"push_frame\s+--index\s+1"),
        re.compile(r"SPI F1 fallback"),
        re.compile(r"FFmpeg RGB F1 fallback"),
        re.compile(r'default="rgb24"'),
        re.compile(r"--format\s+rgb565"),
        re.compile(r"DdrFrameFormat::Rgb565"),
    ]
    allowed_paths = {Path("tests/unit/test_rtl_invariants.py")}

    def forbidden_ddr_rgb_offenders() -> list[str]:
        # Source-text sweep only. Binary assets under tools/ (e.g. .npz digit
        # templates) are tracked product files but must not be UTF-8-decoded —
        # a UnicodeDecodeError here is a gate crash, not a product finding.
        text_suffixes = {
            ".cpp", ".c", ".hpp", ".h", ".sv", ".svh", ".v", ".py", ".sh", ".md",
            ".txt", ".cmake", ".mk", ".json", ".yml", ".yaml", ".toml",
        }
        offenders: list[str] = []
        for path in tracked_product_and_doc_files():
            if not path.is_file():
                continue
            rel = path.relative_to(ROOT)
            if rel in allowed_paths:
                continue
            if path.suffix.lower() not in text_suffixes:
                continue
            text = read(path) if path.suffix == ".md" else active_audit_text(path)
            for lineno, line in enumerate(text.splitlines(), 1):
                for pat in forbidden_repo_patterns:
                    if pat.search(line):
                        offenders.append(f"{rel}:{lineno}: {pat.pattern!r}: {line.strip()}")
        return offenders

    for offender in forbidden_ddr_rgb_offenders():
        check(
            False,
            f"{offender} still contains forbidden DDR RGB/YUV migration pattern. "
            "DDR frame-store entrypoints and docs must be YUV420p-only; RGB helpers are "
            "allowed only outside DDR contexts.",
        )

    rgb_debris = ROOT / "arm/misterplexd/wgate_untracked_rgb_fallback_probe.cpp"
    check(not rgb_debris.exists(), f"untracked DDR RGB probe already exists: {rgb_debris}")
    try:
        rgb_debris.write_text("void probe(){ sendRgb24Frame(buf.data(), w, h, 1); }\n")
        rel_probe = str(rgb_debris.relative_to(ROOT))
        check(
            not any(offender.startswith(f"{rel_probe}:") for offender in forbidden_ddr_rgb_offenders()),
            "forbidden DDR RGB migration sweep must ignore untracked worktree debris",
        )
    finally:
        try:
            rgb_debris.unlink()
        except FileNotFoundError:
            pass
    set_status = strip_comments(read(SET_STATUS_CPP))
    input_mailbox = strip_comments(read(INPUT_MAILBOX_HPP))
    fpga_status_sources = "\n".join([fpga_h, fpga_cpp, push_frame, set_status, input_mailbox])
    check(
        "readFrameStoreStatus" in fpga_status_sources
        and "frame_debug=0x%02x" in fpga_status_sources
        and "frame_status=absent" in fpga_status_sources
        and "PLXF mailbox absent/unwritten" in fpga_status_sources
        and "frame store refused non-YUV doorbell (0xE1)" in fpga_status_sources,
        "Frame-store debug 0xE1 must be first-class in FpgaSpi status tooling. "
        "Status output must include frame_debug=0x.., name a missing/unwritten PLXF mailbox "
        "as frame_status=absent, and print the human-readable non-YUV doorbell refusal, "
        "matching the visual provenance gate fields.",
    )
    print("PASS ARM DDR writer uses product yuv420p frame-store path only")


def check_present_path_degradation_contract() -> None:
    media = strip_comments(read(MEDIA_PLAYER_CPP))
    fb_present = strip_comments(read(FB_PRESENT_CPP))
    status_sources = "\n".join(
        [
            strip_comments(read(FPGA_SPI_CPP)),
            strip_comments(read(PUSH_FRAME_CPP)),
            strip_comments(read(SET_STATUS_CPP)),
            strip_comments(read(INPUT_MAILBOX_HPP)),
        ]
    )

    media_nt = norm(media)
    fb_nt = norm(fb_present)
    status_nt = norm(status_sources)

    def present_degradation_violations(
        media_norm: str, fb_norm: str, fpga_norm: str
    ) -> list[str]:
        violations: list[str] = []
        media_joined = media_norm.replace('""', "")
        fpga_joined = fpga_norm.replace('""', "")
        forbidden = [
            (
                "useDdrF1_=false",
                "F1 DDR failures must not latch-disable future DDR attempts; keep retrying so "
                "PLXF/frame_status remains observable at the point of failure",
            ),
            (
                "if(!ok)ok=",
                "present path must not try X and quietly assign ok from an alternate sender; "
                "fallbacks must be removed or logged/statused before any alternate mechanism",
            ),
            (
                "sendRgb24Frame(buf.data(),w,h,1)",
                "idle paint must not fall back to legacy RGB/SPI F1; frame store F1 is DDR "
                "YUV420p-only",
            ),
            (
                "sendRgb24Frame(buf.data(),w,h,/*F1*/1)",
                "idle paint must not fall back to legacy RGB/SPI F1; frame store F1 is DDR "
                "YUV420p-only",
            ),
            (
                "sendRgb565Bytes(txFrame,txBytes,1)",
                "rawvideo presentation must not fall back to legacy RGB565/SPI F1 after a DDR "
                "failure",
            ),
            (
                "sendRgb565Bytes(txFrame,txBytes,/*F1*/1)",
                "rawvideo presentation must not fall back to legacy RGB565/SPI F1 after a DDR "
                "failure",
            ),
        ]
        violations.extend(msg for needle, msg in forbidden if needle in media_joined)

        required_media = [
            (
                'log("media:idlefb0blitfailed");',
                "idle fb0 blit failure must be logged; a silent idle-present failure looks like "
                "a screensaver regression",
            ),
            (
                'log("media:idlepaintDDRfailed(willretryonre-probe):"+(ddrErr.empty()?fpga_.lastError():ddrErr));',
                "idle DDR failure must name DDR and the re-probe recovery path",
            ),
            (
                'log("media:reconYUV420DDRF1unavailable:"+(ddrErr.empty()?fpga_.lastError():ddrErr));',
                "STREAM recon DDR failure must log the named DDR/YUV failure and keep retrying",
            ),
            (
                'log("media:non-YUVF1framerefusedbeforesend;framestorerequiresDDRYUV420p");',
                "rawvideo non-YUV F1 attempts must be refused before send with a named reason",
            ),
            (
                'log("media:DDRYUV420pF1unavailable:"+(ddrErr.empty()?fpga_.lastError():ddrErr));',
                "rawvideo DDR failure must be externally visible instead of falling back to a "
                "different present path",
            ),
            (
                'log("media:fpgaframe_tx:"+(ddrErr.empty()?fpga_.lastError():ddrErr));',
                "rawvideo frame_tx errors must surface the low-level frame-store status "
                "(including frame_status=absent or frame_debug=0xE1)",
            ),
            (
                'log("ERRORmedia:reconF1REFUSED:frame-storerequiresMB-alignedresolution<="+',
                "geometry mismatch in STREAM recon must be a LOUD refusal (not a quiet skip), "
                "because a silent skip is indistinguishable from frozen screen",
            ),
            (
                'log("media:blitfailedfmt="+std::string(ffmpegPixFmt(videoFmt)));',
                "fb0 present failures must be logged; changing bpp/geometry must not silently "
                "erase the reference surface",
            ),
        ]
        violations.extend(msg for needle, msg in required_media if needle not in media_joined)

        for m in re.finditer(r"catch\s*\([^)]*\)\s*\{([^{}]*)\}", media_joined):
            if "log(" not in m.group(1):
                violations.append(
                    "present thread catch blocks must log before continuing or stopping; "
                    "exceptions cannot silently degrade playback"
                )

        required_fpga = [
            (
                'setErr("non-YUVframesendrefused:SPIF1RGBframepathisdisabled;useDDRYUV420p(sendYuv420pFrameDdr/push_frame--ddr--yuv420p)");',
                "low-level F1/SPI frame sends must fail at point of use with a named non-YUV "
                "refusal",
            ),
            (
                'frameStoreStatusSuffix()',
                "DDR send failures must append PLXF/frame_status details so absent/0xE1 is "
                "visible to operators",
            ),
            (
                'frame_status=absent',
                "unwritten PLXF mailbox must surface as frame_status=absent, not as a generic "
                "present failure",
            ),
            (
                'framestorestatusunavailable(PLXFmailboxabsent/unwritten)',
                "PLXF absent/unwritten must have a human-legible diagnostic string",
            ),
            (
                'framestorerefusednon-YUVdoorbell(0xE1)',
                "PLXF frame_debug 0xE1 must be named as non-YUV doorbell refusal",
            ),
        ]
        violations.extend(msg for needle, msg in required_fpga if needle not in fpga_joined)

        if "returnfalse;" not in fb_norm:
            violations.append("fb_present must return false on unsupported/failed blits")
        return violations

    missing = present_degradation_violations(media_nt, fb_nt, status_nt)
    if missing:
        fail(f"ARM present-path degradation contract: {missing[0]}")

    rgb_fallback_media = media_nt.replace(
        'log("media:idlepaintDDRfailed(willretryonre-probe):"+(ddrErr.empty()?fpga_.lastError():ddrErr));',
        "ok=fpga_.sendRgb24Frame(buf.data(),w,h,1);",
    )
    if not present_degradation_violations(rgb_fallback_media, fb_nt, status_nt):
        fail("deliberately reintroduced idle RGB/SPI F1 fallback did not make the gate red")

    latched_disable_media = media_nt.replace(
        'log("media:reconYUV420DDRF1unavailable:"+(ddrErr.empty()?fpga_.lastError():ddrErr));',
        'useDdrF1_=false;',
    )
    if not present_degradation_violations(latched_disable_media, fb_nt, status_nt):
        fail("deliberately reintroduced one-shot DDR disable did not make the gate red")

    silent_ddr_media = media_nt.replace(
        'log("media:DDRYUV420pF1unavailable:"+(ddrErr.empty()?fpga_.lastError():ddrErr));',
        "",
    )
    if not present_degradation_violations(silent_ddr_media, fb_nt, status_nt):
        fail("deliberately silenced rawvideo DDR failure did not make the gate red")

    print("PASS ARM present path has no silent fallback/degradation without named status")



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


def check_h264_quartus_subset() -> None:
    spec = importlib.util.spec_from_file_location("check_quartus_sv_subset", QUARTUS_SV_GUARD)
    check(spec is not None and spec.loader is not None, "Quartus SV subset guard script missing")
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    errors = []
    for rtl in (H264_DPB_RTL, H264_DEBLOCK_RTL):
        errors.extend(guard.check_file(rtl))
    check(
        not errors,
        "H.264 RTL uses constructs Quartus rejected while Verilator accepted:\n"
        + "\n".join(f"  {err}" for err in errors),
    )
    print("PASS H.264 Quartus SV subset guard")


def main() -> int:
    check_source_text_matcher_hardening()
    check_present_core()
    check_phase_a_surface()
    check_plex_reset_domains()
    check_quartus_syntax_tripwires()
    check_async_fifo_write_full_no_comb_loop()
    check_frame_store_cdc_contract()
    check_mailboxes()
    check_mailbox_map_collisions()
    check_ddr_bitstream_ring()
    check_status_telemetry()
    check_ddr_frame_layout_contract()
    check_runtime_ddr_layout_literal_sweep()
    check_runtime_ddr_layout_literal_ignores_untracked_debris()
    check_ddr_frame_store_yuv_read_contract()
    check_present_geometry_stride_contract()
    check_ddr_bank_handoff_contract()
    check_plxd_liveness_degeneracy()
    check_yuv_ddr_writer_contract()
    check_present_path_degradation_contract()
    check_ddr_bitstream_product_path()
    check_h264_quartus_subset()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
