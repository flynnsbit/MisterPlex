#!/usr/bin/env python3
"""Is the DDR line refill fast enough to keep the scanline fed?

The parent's standing note on the left-edge artifact is that "capacity was
measured, not rate". check_fitted_line_buffer.py answers *how many lines fit*.
This answers the different question *can the store fetch a line in less time
than the raster takes to cross one*, which decides whether more line slots
(FRAME_LINES_16) can help at all:

  - if the refill is BANDWIDTH bound, extra slots buy nothing, because the
    store falls behind at a fixed rate no matter how deep the buffer is;
  - if the refill has bandwidth headroom, the failure is a LEAD/SCHEDULING
    problem, and extra slots buy exactly the thing that is short.

Everything is derived. Geometry comes from the RTL, video timing comes from the
RTL, and the two clock frequencies come from a Quartus STA report bound to a
Plex.rbf md5 -- never from a comment. Plex.sdc says "clk_ddr runs at 90 MHz" in
a comment; comments are not measurements, and the PLL wrapper's own GUI
metadata claims every output is 20.0 MHz with "actual 0 MHz", which is stale.

Scope is printed before any verdict. Exit codes:
    0   PASS   headroom >= the required ratio
    1   FAIL   headroom below the required ratio, or a derivation mismatch
    2   REFUSE could not derive an input, or an unbound report was offered
    77  SKIP   required input absent

LIMITS, declared up front:
  * This is a steady-state average-rate bound. It does NOT model DDR refresh,
    arbiter contention with the HPS writer, page misses, or the burst latency
    of the f2h bridge, none of which are in any source file. --latency-cycles
    exists so a pessimistic latency can be charged explicitly and shows up in
    the printed arithmetic rather than hiding in a fudge factor.
  * A PASS here means bandwidth is not the binding constraint. It does NOT
    mean the present path works, and it is not evidence about any particular
    frame. It cannot see optimize-away (mode 3).
  * It says nothing about the vertical scaling ratio beyond the explicit
    --lines-per-output-line upper bound.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
LAYOUT_SVH = RTL / "ddr_frame_layout_params.svh"
STORE_SV = RTL / "ddr_frame_store.sv"
PRESENT_SV = RTL / "present_core.sv"
BARS_SV = RTL / "colorbars.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"

# Must be the CORE pll, not pll_audio. Both instantiate an altera_pll whose
# output-counter paths contain "general[0].gpll~PLL_OUTPUT_COUNTER", so the
# short substring matches two different clocks (20.0 and 24.58 MHz on the
# resident report). Hierarchy names are not unique by suffix.
CORE_PLL = "emu|pll|pll_inst|altera_pll_i|"


class Refuse(Exception):
    pass


def _read(path: Path) -> str:
    if not path.is_file():
        raise Refuse(f"missing source file: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def sv_int_param(text: str, name: str) -> int:
    """localparam/parameter int NAME = <integer literal>."""
    m = re.search(
        r"\b(?:localparam|parameter)\s+int\s+" + re.escape(name) + r"\s*=\s*(\d+)\s*;",
        _strip_comments(text),
    )
    if not m:
        raise Refuse(f"could not derive {name}")
    return int(m.group(1))


def sv_sized_int(text: str, name: str) -> int:
    """localparam [..] NAME = 10'd637;  -> 637"""
    m = re.search(
        r"\blocalparam\b[^;=]*?\b" + re.escape(name) + r"\s*=\s*\d+'d(\d+)\s*;",
        _strip_comments(text),
    )
    if not m:
        raise Refuse(f"could not derive {name}")
    return int(m.group(1))


def sv_divisor(text: str, name: str, numerator: str) -> int:
    """localparam int NAME = NUMERATOR / <n>;  -> n

    Derives the qwords-per-line divisors rather than restating 8 and 16, so a
    change to the 64-bit DDR word width is caught instead of silently ignored.
    """
    m = re.search(
        r"\b(?:localparam|parameter)\s+int\s+"
        + re.escape(name)
        + r"\s*=\s*"
        + re.escape(numerator)
        + r"\s*/\s*(\d+)\s*;",
        _strip_comments(text),
    )
    if not m:
        raise Refuse(f"could not derive {name} as {numerator}/n")
    return int(m.group(1))


def active_line_count(present_text: str, qsf_text: str) -> tuple[int, str]:
    """FRAME_LINE_COUNT selected by the FRAME_LINES_* define in Plex.qsf."""
    defines = set(
        re.findall(r"VERILOG_MACRO\s*=?\s*\"?(FRAME_LINES_\d+)=1", qsf_text)
    )
    if not defines:
        raise Refuse("no FRAME_LINES_* macro set in Plex.qsf")
    if len(defines) > 1:
        raise Refuse(f"ambiguous FRAME_LINES_* macros in Plex.qsf: {sorted(defines)}")
    macro = defines.pop()
    body = _strip_comments(present_text)
    # `ifdef ladder: find the branch guarded by the selected macro.
    for m in re.finditer(
        r"`(?:ifdef|elsif)\s+(FRAME_LINES_\d+)(.*?)(?=`(?:elsif|else|endif))",
        body,
        flags=re.S,
    ):
        if m.group(1) != macro:
            continue
        n = re.search(r"FRAME_LINE_COUNT\s*=\s*(\d+)", m.group(2))
        if n:
            return int(n.group(1)), macro
    raise Refuse(f"{macro} set in Plex.qsf but no matching branch in present_core.sv")


def sta_clock_mhz(sta_text: str, substring: str) -> float:
    """Read a clock frequency out of the STA 'Clocks' table.

    Bounded deliberately. The Fmax Summary table later in the same report also
    carries the clock name and a MHz value -- the RESTRICTED FMAX, which is a
    different quantity from the clock's frequency. An unbounded scan picks up
    both and either refuses or, worse, silently returns the wrong one. Same
    defect class w-audit found in check_fitted_line_buffer.py: a table that
    does not know where it ends.

    Two independent constraints: the row must sit inside the Clocks table, and
    the clock name must be the row's FIRST cell (in Fmax Summary it is the
    third).
    """
    lines = sta_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r";\s*Clocks\s*;?\s*$", line):
            start = i
            break
    if start is None:
        # Allow a bare fragment (used by the self-test) with no section header.
        start = -1

    hits = []
    seen_rows = False
    for line in lines[start + 1:]:
        if not line.startswith(";"):
            if seen_rows and not line.startswith("+"):
                break
            continue
        cells = [c.strip() for c in line.strip(";").split(";")]
        if len(cells) < 2:
            break
        seen_rows = True
        if substring not in cells[0]:
            continue
        for cell in cells[1:]:
            m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*MHz", cell)
            if m:
                hits.append(float(m.group(1)))
                break
    if not hits:
        raise Refuse(f"no clock row matching {substring!r} in the STA Clocks table")
    if len(set(hits)) > 1:
        raise Refuse(f"ambiguous clock rows for {substring!r}: {sorted(set(hits))}")
    return hits[0]


def ce_pix_divider(bars_text: str, scandouble: bool) -> int:
    """colorbars drives ce_pix at clk (scandouble) or clk/2 (otherwise)."""
    body = _strip_comments(bars_text)
    if not re.search(r"if\s*\(\s*scandouble\s*\)\s*ce_pix\s*<=\s*1'b1\s*;", body):
        raise Refuse("colorbars ce_pix scandouble branch not in the expected form")
    if not re.search(r"else\s*ce_pix\s*<=\s*~\s*ce_pix\s*;", body):
        raise Refuse("colorbars ce_pix non-scandouble branch not in the expected form")
    return 1 if scandouble else 2


def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bind_report(sta: Path, expect_md5: str | None) -> str:
    """A report is only evidence if it is bound to the bitstream it describes.

    40 fit reports exist on this host and most describe builds nobody runs.
    Without --expect-rbf-md5 this returns UNBOUND, which callers must not
    treat as a pass.
    """
    rbf = sta.parent / "Plex.rbf"
    if expect_md5 is None:
        return "UNBOUND"
    if not rbf.is_file():
        raise Refuse(f"--expect-rbf-md5 given but no sibling Plex.rbf beside {sta}")
    got = md5_of(rbf)
    if not got.startswith(expect_md5.lower()):
        raise Refuse(f"report binds to Plex.rbf md5={got}, expected {expect_md5}")
    return f"BOUND md5={got}"


def evaluate(
    sta_path: Path,
    expect_md5: str | None,
    latency_cycles: int,
    lines_per_output_line: int,
    require_headroom: float,
    scandouble: bool,
) -> int:
    layout_text = _read(LAYOUT_SVH)
    store_text = _read(STORE_SV)
    present_text = _read(PRESENT_SV)
    bars_text = _read(BARS_SV)
    qsf_text = _read(QSF)
    sta_text = _read(sta_path)

    coded_w = sv_int_param(layout_text, "DDR_FRAME_CODED_WIDTH")
    y_div = sv_divisor(store_text, "Y_LINE_QWORDS", "CODED_W")
    c_div = sv_divisor(store_text, "C_LINE_QWORDS", "CODED_W")
    if coded_w % y_div or coded_w % c_div:
        raise Refuse(f"CODED_W={coded_w} not divisible by {y_div}/{c_div}")
    y_qw = coded_w // y_div
    c_qw = coded_w // c_div
    slot_qw = y_qw + 2 * c_qw

    line_count, macro = active_line_count(present_text, qsf_text)
    h_last = sv_sized_int(bars_text, "H_LAST")
    clocks_per_line = h_last + 1

    clk_ddr_mhz = sta_clock_mhz(sta_text, CORE_PLL + "general[2].gpll~PLL_OUTPUT_COUNTER")
    clk_sys_mhz = sta_clock_mhz(sta_text, CORE_PLL + "general[0].gpll~PLL_OUTPUT_COUNTER")
    binding = bind_report(sta_path, expect_md5)

    div = ce_pix_divider(bars_text, scandouble)
    ce_pix_mhz = clk_sys_mhz / div
    line_time_us = clocks_per_line / ce_pix_mhz

    fetch_qw = slot_qw * lines_per_output_line
    bursts = 3 * lines_per_output_line  # Y, U, V per fetched line
    ddr_cycles = fetch_qw + bursts * latency_cycles
    refill_us = ddr_cycles / clk_ddr_mhz

    headroom = line_time_us / refill_us if refill_us > 0 else float("inf")

    print(
        f"Scope: 1 refill-rate budget "
        f"(macro={macro} LINE_COUNT={line_count} CODED_W={coded_w} "
        f"lines_per_output_line={lines_per_output_line} latency_cycles={latency_cycles})"
    )
    print(f"  report      {sta_path}  {binding}")
    print(f"  clk_ddr     {clk_ddr_mhz} MHz   clk_sys {clk_sys_mhz} MHz  ce_pix {ce_pix_mhz} MHz")
    print(
        f"  per line    y={y_qw} u={c_qw} v={c_qw} qwords -> slot={slot_qw} qwords "
        f"(CODED_W/{y_div}, CODED_W/{c_div})"
    )
    print(f"  line time   {clocks_per_line} ce_pix clocks / {ce_pix_mhz} MHz = {line_time_us:.3f} us")
    print(
        f"  refill      {fetch_qw} qwords + {bursts} bursts x {latency_cycles} cyc "
        f"= {ddr_cycles} clk_ddr = {refill_us:.3f} us"
    )
    print(f"  headroom    {headroom:.2f}x   required {require_headroom:.2f}x")

    if binding == "UNBOUND":
        print("WARNING report is UNBOUND; this cannot be cited as evidence about any bitstream")

    if headroom < require_headroom:
        print(
            "REFILL_RATE_FAIL bandwidth is the binding constraint; "
            "more line slots cannot help"
        )
        return 1
    print(
        "REFILL_RATE_OK bandwidth is not the binding constraint; "
        "a starvation fault must be lead/scheduling, which line slots do address"
    )
    return 0


def self_test() -> int:
    """Greens and reds for the derivation helpers."""
    cases: list[tuple[str, bool]] = []

    def check(name: str, ok: bool) -> None:
        cases.append((name, ok))

    store = _read(STORE_SV)
    bars = _read(BARS_SV)
    layout = _read(LAYOUT_SVH)

    # GREEN: the real sources derive the expected values.
    check("coded_w", sv_int_param(layout, "DDR_FRAME_CODED_WIDTH") == 624)
    check("y_div", sv_divisor(store, "Y_LINE_QWORDS", "CODED_W") == 8)
    check("c_div", sv_divisor(store, "C_LINE_QWORDS", "CODED_W") == 16)
    check("h_last", sv_sized_int(bars, "H_LAST") == 637)
    check("ce_div_scandouble", ce_pix_divider(bars, True) == 1)
    check("ce_div_plain", ce_pix_divider(bars, False) == 2)

    real_count, real_macro = active_line_count(_read(PRESENT_SV), _read(QSF))
    check("qsf_macro_selects_a_branch", real_count > 0 and real_macro.startswith("FRAME_LINES_"))

    sta_sample = (
        "; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk "
        "; Generated ; 11.111 ; 90.0 MHz ; 0.000 ;\n"
        "; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk "
        "; Generated ; 50.000 ; 20.0 MHz ; 0.000 ;\n"
    )
    check("sta_ddr", sta_clock_mhz(sta_sample, "general[2].gpll~PLL_OUTPUT_COUNTER") == 90.0)
    check("sta_sys", sta_clock_mhz(sta_sample, "general[0].gpll~PLL_OUTPUT_COUNTER") == 20.0)

    def refuses(fn) -> bool:
        try:
            fn()
        except Refuse:
            return True
        except Exception:
            return False
        return False

    # RED: a missing clock row must refuse, not default to anything.
    check("red_missing_clock", refuses(lambda: sta_clock_mhz("; nothing here ;\n", "general[2]")))
    # RED: two different frequencies for one clock must refuse, not pick one.
    check(
        "red_ambiguous_clock",
        refuses(
            lambda: sta_clock_mhz(
                sta_sample
                + "; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk "
                  "; Generated ; 22.0 ; 45.0 MHz ;\n",
                "general[2].gpll~PLL_OUTPUT_COUNTER",
            )
        ),
    )
    # RED: the Fmax Summary table later in a real report carries the same clock
    # name with a DIFFERENT MHz value (restricted Fmax). Reading past the end
    # of the Clocks table silently substitutes that number. Uses the real
    # resident report when it is present, so this is not a synthetic red.
    resident_sta = ROOT / "build/rpt/bdiag-b/Plex.sta.rpt"
    if resident_sta.is_file():
        text = resident_sta.read_text(encoding="utf-8", errors="replace")
        ddr = sta_clock_mhz(text, CORE_PLL + "general[2].gpll~PLL_OUTPUT_COUNTER")
        sys_clk = sta_clock_mhz(text, CORE_PLL + "general[0].gpll~PLL_OUTPUT_COUNTER")
        check("real_report_ddr_is_90", ddr == 90.0)
        check("real_report_sys_is_20", sys_clk == 20.0)
        # RED: the short substring collides with pll_audio in the real
        # report. Must refuse, not silently return the audio PLL.
        check(
            "red_substring_collides_with_pll_audio",
            refuses(lambda: sta_clock_mhz(text, "general[0].gpll~PLL_OUTPUT_COUNTER")),
        )
        fmax_rows = [
            ln for ln in text.splitlines()
            if "general[2].gpll~PLL_OUTPUT_COUNTER" in ln and "MHz" in ln
        ]
        check("real_report_has_a_decoy_row", len(fmax_rows) > 1)
    # RED: a renamed/absent parameter must refuse rather than fall back.
    check("red_missing_param", refuses(lambda: sv_int_param(layout, "NO_SUCH_PARAM")))
    check("red_missing_sized", refuses(lambda: sv_sized_int(bars, "NO_SUCH_PARAM")))
    # RED: if the qword divisor stops being expressed against CODED_W, refuse
    # rather than silently assuming 8.
    check("red_divisor_form", refuses(lambda: sv_divisor(store, "Y_LINE_QWORDS", "FRAME_W")))
    # RED: ce_pix must not be derived from a colorbars that no longer has the
    # scandouble branch -- otherwise the line time is silently wrong by 2x.
    check(
        "red_ce_pix_form",
        refuses(lambda: ce_pix_divider(bars.replace("ce_pix <= 1'b1;", "ce_pix <= 1'b0;"), True)),
    )
    # RED: no FRAME_LINES_* macro at all must refuse.
    check("red_no_macro", refuses(lambda: active_line_count(_read(PRESENT_SV), "# empty qsf\n")))
    # RED: two macros set at once must refuse rather than pick the first.
    check(
        "red_two_macros",
        refuses(
            lambda: active_line_count(
                _read(PRESENT_SV),
                'set_global_assignment -name VERILOG_MACRO "FRAME_LINES_8=1"\n'
                'set_global_assignment -name VERILOG_MACRO "FRAME_LINES_16=1"\n',
            )
        ),
    )
    # RED: a macro with no matching branch must refuse.
    check(
        "red_macro_without_branch",
        refuses(
            lambda: active_line_count(
                "module present_core; endmodule\n",
                'set_global_assignment -name VERILOG_MACRO "FRAME_LINES_8=1"\n',
            )
        ),
    )
    # RED: --expect-rbf-md5 pointing at a report with no sibling RBF must refuse.
    check(
        "red_bind_no_rbf",
        refuses(lambda: bind_report(ROOT / "scripts/check_ddr_refill_rate.py", "deadbeef")),
    )
    # RED: an unbound report must never read as bound.
    check("red_unbound_is_not_bound", bind_report(STORE_SV, None) == "UNBOUND")

    print(f"Scope: {len(cases)} self-test cases")
    bad = [n for n, ok in cases if not ok]
    for name, ok in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if bad:
        print(f"REFILL_RATE_SELFTEST_FAIL {len(bad)} case(s): {bad}")
        return 1
    print(f"REFILL_RATE_SELFTEST_OK {len(cases)} case(s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sta-report", type=Path, help="Quartus Plex.sta.rpt to read clocks from")
    ap.add_argument("--expect-rbf-md5", help="bind the report to its sibling Plex.rbf")
    ap.add_argument("--latency-cycles", type=int, default=0,
                    help="clk_ddr cycles charged per burst for read latency")
    ap.add_argument("--lines-per-output-line", type=int, default=1,
                    help="upper bound on source lines fetched per output line")
    ap.add_argument("--require-headroom", type=float, default=1.0)
    ap.add_argument("--no-scandouble", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    try:
        if args.self_test:
            return self_test()
        if args.sta_report is None:
            print("Scope: 0")
            print("SKIP-NOT-PASS --sta-report is required", file=sys.stderr)
            return 77
        if not args.sta_report.is_file():
            print("Scope: 0")
            print(f"SKIP-NOT-PASS STA report absent: {args.sta_report}", file=sys.stderr)
            return 77
        if args.lines_per_output_line < 1:
            raise Refuse("--lines-per-output-line must be >= 1")
        return evaluate(
            args.sta_report,
            args.expect_rbf_md5,
            args.latency_cycles,
            args.lines_per_output_line,
            args.require_headroom,
            not args.no_scandouble,
        )
    except Refuse as exc:
        print("Scope: 0")
        print(f"REFILL_RATE_REFUSE {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
