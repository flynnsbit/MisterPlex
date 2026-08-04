#!/usr/bin/env python3
"""Raster/clock consistency gate — 720p24 exact-rate product path.

Defect class (observed 2026-08-04, not speculative):
  (a) RECIPE/RTL DRIFT: recipe.svh vs present_core hard-coded H_TOTAL disagreed.
  (b) FALSE-GREEN RATE BAND: FPS_PASS accepted 242 (defect) and rejected 240 (exact 24).
  (c) ILLEGAL PLL: 29.7 MHz on shared integer-N VCO with 20/90 — Fitter died pre-place.

Checks:
  1. SINGLE SOURCE OF TRUTH — product H/V/FPS/Hz live in recipe.svh; consumers match.
  2. STALE-VALUE — retired 720p24 29.7 / illegal compact-H1650@24; CEA60 1650 allowed.
  3. ARITHMETIC — H*V*FPS == Hz exactly for every named recipe pack + product.
  4. PLL REALISABILITY — shared integer-N with 20/90/(optional SDRAM) inside CV VCO/PFD.
  5. RATE-BAND SANITY — acceptance band must include exact target fps_x10.

Exit: 0 PASS, 1 FAIL, 2 usage. Soft-skip (77) is never used — absence is FAIL.
--self-test runs assembled fixtures (pos+neg); fixtures are NOT stored as literals
that would become definition sites for scanners.
"""
from __future__ import annotations

import argparse
import math
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RECIPE = ROOT / "fpga/Plex_MiSTer/rtl/misterplex_clk_pix_recipe.svh"
DEFAULT_PLL = ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v"
DEFAULT_PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
DEFAULT_CLKSTAT = ROOT / "fpga/Plex_MiSTer/rtl/plex_clk_status.sv"
DEFAULT_QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
DEFAULT_SDC = ROOT / "fpga/Plex_MiSTer/Plex_clk_pix.sdc"

REF_HZ = 50_000_000
VCO_MIN = 600_000_000
VCO_MAX = 1_600_000_000
PFD_MIN = 5_000_000
CLK_SYS_HZ = 20_000_000
CLK_DDR_HZ = 90_000_000
SDRAM_142_HZ = 142_000_000

# Retired product-720p24 values (illegal on shared integer-N with 20/90).
RETIRED_PIX_HZ = 29_700_000
RETIRED_PIX_MHZ_STRS = (
    "29.700000 MHz",
    "29.700 MHz",
    "29.7 MHz",
)
# Compact H@24 that paired with illegal 29.7 (CEA60 still legitimately uses 1650@60).
RETIRED_COMPACT24_H = 1650


@dataclass
class Finding:
    check: str
    path: str
    detail: str


@dataclass
class RecipePack:
    name: str
    h: int | None = None
    v: int | None = None
    fps: int | None = None
    hz: int | None = None


@dataclass
class TreeModel:
    recipe_text: str
    pll_text: str
    present_text: str
    clkstat_text: str
    qsf_text: str
    sdc_text: str
    recipe_path: str = "recipe.svh"
    pll_path: str = "pll_0002.v"
    present_path: str = "present_core.sv"
    clkstat_path: str = "plex_clk_status.sv"
    qsf_path: str = "Plex.qsf"
    sdc_path: str = "Plex_clk_pix.sdc"
    findings: list[Finding] = field(default_factory=list)

    def fail(self, check: str, path: str, detail: str) -> None:
        self.findings.append(Finding(check, path, detail))


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def strip_sv_comments(text: str) -> str:
    """Remove // and /* */ comments so scanners do not treat docs as definitions."""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                break
            i = j + 2
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def strip_hash_comments(text: str) -> str:
    lines = []
    for ln in text.splitlines():
        if ln.lstrip().startswith("#"):
            continue
        if "#" in ln:
            # keep code before # (QSF / TCL)
            lines.append(ln.split("#", 1)[0])
        else:
            lines.append(ln)
    return "\n".join(lines)


def parse_localparam_ints(text: str) -> dict[str, int]:
    code = strip_sv_comments(text)
    out: dict[str, int] = {}
    # localparam int NAME = 123;  or 123_456; or expression of prior names (one level)
    for m in re.finditer(
        r"localparam\s+int\s+(\w+)\s*=\s*([^;]+);",
        code,
    ):
        name, expr = m.group(1), m.group(2).strip()
        val = eval_int_expr(expr, out)
        if val is not None:
            out[name] = val
    return out


def eval_int_expr(expr: str, env: dict[str, int]) -> int | None:
    expr = expr.strip()
    if re.fullmatch(r"[0-9_]+", expr):
        return int(expr.replace("_", ""))
    # bare name
    if re.fullmatch(r"[A-Za-z_]\w*", expr):
        return env.get(expr)
    # simple NAME or INT only — no operators needed beyond that for recipe
    return None


def active_qsf_macros(qsf_text: str) -> dict[str, str]:
    macros: dict[str, str] = {}
    for ln in qsf_text.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        m = re.search(r'VeRILOG_MACRO\s+"([^"=]+)(?:=([^"]*))?"', s, re.I)
        if not m:
            m = re.search(r"VERILOG_MACRO\s+\"([^\"=]+)(?:=([^\"]*))?\"", s)
        if m:
            macros[m.group(1)] = m.group(2) if m.group(2) is not None else "1"
    return macros


def parse_mhz_string(s: str) -> int | None:
    m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*MHz", s, re.I)
    if not m:
        return None
    return int(round(float(m.group(1)) * 1_000_000))


def extract_define_mhz(pll_text: str, name: str) -> int | None:
    code = strip_sv_comments(pll_text)
    m = re.search(rf'`define\s+{re.escape(name)}\s+"([^"]+)"', code)
    if not m:
        return None
    return parse_mhz_string(m.group(1))


def extract_mp_beam_totals(present_text: str) -> tuple[int | None, int | None, str]:
    """H_TOTAL/V_TOTAL on present_beam_ppc under PRESENT_MULTI_PIXEL."""
    code = strip_sv_comments(present_text)
    # Prefer the multi-pixel beam instance
    m = re.search(
        r"present_beam_ppc\s*#\s*\((.*?)\)\s*u_mp_beam",
        code,
        re.S,
    )
    if not m:
        # fallback: any present_beam_ppc with H_TOTAL
        m = re.search(r"present_beam_ppc\s*#\s*\((.*?)\)\s*\w+", code, re.S)
        if not m:
            return None, None, "present_beam_ppc instance not found"
    block = m.group(1)
    hm = re.search(r"\.H_TOTAL\s*\(\s*([0-9_]+|`?\w+)\s*\)", block)
    vm = re.search(r"\.V_TOTAL\s*\(\s*([0-9_]+|`?\w+)\s*\)", block)
    def tok(t: str | None) -> int | None:
        if t is None:
            return None
        t = t.strip()
        if re.fullmatch(r"[0-9_]+", t):
            return int(t.replace("_", ""))
        return None  # symbolic — resolved elsewhere

    return tok(hm.group(1) if hm else None), tok(vm.group(1) if vm else None), block[:200]


def extract_fps_band(clkstat_text: str) -> tuple[int | None, int | None]:
    code = strip_sv_comments(clkstat_text)
    lo = re.search(r"localparam\s+int\s+FPS_PASS_LO\s*=\s*([0-9_]+)\s*;", code)
    hi = re.search(r"localparam\s+int\s+FPS_PASS_HI\s*=\s*([0-9_]+)\s*;", code)
    if not lo or not hi:
        return None, None
    return int(lo.group(1).replace("_", "")), int(hi.group(1).replace("_", ""))


def gcd(a: int, b: int) -> int:
    while b:
        a, b = b, a % b
    return abs(a)


def lcm(a: int, b: int) -> int:
    return abs(a // gcd(a, b) * b) if a and b else 0


def pll_shared_integer_n_ok(
    out_hz: list[int],
    ref_hz: int = REF_HZ,
    vco_min: int = VCO_MIN,
    vco_max: int = VCO_MAX,
    pfd_min: int = PFD_MIN,
) -> tuple[bool, str]:
    """True if some integer-N M/N and integer C_i realise all outputs on one VCO."""
    if not out_hz:
        return False, "no outputs"
    # VCO must be multiple of each fout → multiple of lcm(fouts)
    # Work in Hz integers.
    g = 0
    for f in out_hz:
        if f <= 0:
            return False, f"non-positive fout {f}"
        g = f if g == 0 else gcd(g, f)
    # Search N such that PFD=ref/N >= pfd_min and N divides ref (integer PFD preferred)
    max_n = ref_hz // pfd_min
    candidates: list[str] = []
    for n in range(1, max_n + 1):
        if ref_hz % n != 0:
            continue
        pfd = ref_hz // n
        if pfd < pfd_min:
            continue
        # VCO = pfd * M; must be multiple of each fout
        # M loop: vco in range
        m_lo = (vco_min + pfd - 1) // pfd
        m_hi = vco_max // pfd
        for m in range(m_lo, m_hi + 1):
            vco = pfd * m
            if vco < vco_min or vco > vco_max:
                continue
            ok = True
            cs: list[int] = []
            for f in out_hz:
                if vco % f != 0:
                    ok = False
                    break
                cs.append(vco // f)
            if ok:
                return True, f"OK VCO={vco} PFD={pfd} M={m} N={n} C={cs}"
            candidates.append(f"VCO={vco} miss")
    # Also report lcm-based impossibility
    try:
        L = out_hz[0]
        for f in out_hz[1:]:
            L = lcm(L, f)
            if L > vco_max * 4:
                break
        return False, (
            f"no integer-N solution in VCO[{vco_min},{vco_max}] PFD>={pfd_min}; "
            f"lcm_out≈{L} outs={out_hz}"
        )
    except Exception as exc:  # noqa: BLE001
        return False, f"pll search failed: {exc}"


def fps_x10_exact(h: int, v: int, hz: int) -> int | None:
    """Return 10*fps if hz/(h*v) is exact to 0.1 fps quanta (integer fps_x10)."""
    den = h * v
    if den <= 0:
        return None
    # fps_x10 = 10*hz/den — require exact integer
    num = 10 * hz
    if num % den != 0:
        # allow if within 0.05 of an integer after true division? Prefer exact.
        val = num / den
        r = int(round(val))
        if abs(val - r) < 1e-9:
            return r
        return None
    return num // den


def build_packs(lp: dict[str, int]) -> dict[str, RecipePack]:
    packs: dict[str, RecipePack] = {}
    # COMPACT
    packs["COMPACT"] = RecipePack(
        "COMPACT",
        lp.get("MISTERPLEX_CLKPIX_COMPACT_H"),
        lp.get("MISTERPLEX_CLKPIX_COMPACT_V"),
        lp.get("MISTERPLEX_CLKPIX_COMPACT_FPS") or lp.get("MISTERPLEX_CLKPIX_FPS_24"),
        lp.get("MISTERPLEX_CLKPIX_COMPACT_HZ"),
    )
    if "MISTERPLEX_CLKPIX_EXACT24_H" in lp or "MISTERPLEX_CLKPIX_EXACT24_HZ" in lp:
        packs["EXACT24"] = RecipePack(
            "EXACT24",
            lp.get("MISTERPLEX_CLKPIX_EXACT24_H"),
            lp.get("MISTERPLEX_CLKPIX_EXACT24_V"),
            lp.get("MISTERPLEX_CLKPIX_EXACT24_FPS") or 24,
            lp.get("MISTERPLEX_CLKPIX_EXACT24_HZ"),
        )
    packs["CEA24"] = RecipePack(
        "CEA24",
        lp.get("MISTERPLEX_CLKPIX_CEA24_H"),
        lp.get("MISTERPLEX_CLKPIX_CEA24_V"),
        lp.get("MISTERPLEX_CLKPIX_CEA24_FPS") or 24,
        lp.get("MISTERPLEX_CLKPIX_CEA24_HZ"),
    )
    packs["CEA60"] = RecipePack(
        "CEA60",
        lp.get("MISTERPLEX_CLKPIX_CEA60_H"),
        lp.get("MISTERPLEX_CLKPIX_CEA60_V"),
        lp.get("MISTERPLEX_CLKPIX_CEA60_FPS") or 60,
        lp.get("MISTERPLEX_CLKPIX_CEA60_HZ"),
    )
    return packs


def product_pack(lp: dict[str, int], packs: dict[str, RecipePack]) -> RecipePack:
    """Resolve which pack is product when PRESENT_CLK_PIX_PLL (no 74_25 / CEA24)."""
    prod_hz = lp.get("MISTERPLEX_CLKPIX_PRODUCT_HZ") or lp.get("MISTERPLEX_CLKPIX_COMPACT_HZ")
    # Prefer EXACT24 if PRODUCT points at it or COMPACT was retargeted to exact-24 numbers
    if "EXACT24" in packs and packs["EXACT24"].hz is not None and prod_hz == packs["EXACT24"].hz:
        p = packs["EXACT24"]
        return RecipePack("PRODUCT", p.h, p.v, p.fps or 24, p.hz)
    c = packs.get("COMPACT")
    if c and c.hz is not None and prod_hz == c.hz:
        return RecipePack("PRODUCT", c.h, c.v, c.fps or 24, c.hz)
    # PRODUCT_HZ alone
    return RecipePack(
        "PRODUCT",
        lp.get("MISTERPLEX_CLKPIX_COMPACT_H") or lp.get("MISTERPLEX_CLKPIX_CEA_H"),
        lp.get("MISTERPLEX_CLKPIX_COMPACT_V") or lp.get("MISTERPLEX_CLKPIX_CEA_V"),
        24,
        prod_hz,
    )


def check_arithmetic(tree: TreeModel, packs: dict[str, RecipePack], product: RecipePack) -> None:
    for name, p in list(packs.items()) + [("PRODUCT", product)]:
        if p.h is None or p.v is None or p.fps is None or p.hz is None:
            # incomplete packs (e.g. missing optional) — skip if all none
            if all(x is None for x in (p.h, p.v, p.hz)):
                continue
            tree.fail(
                "ARITHMETIC",
                tree.recipe_path,
                f"{name}: incomplete pack h={p.h} v={p.v} fps={p.fps} hz={p.hz}",
            )
            continue
        got = p.h * p.v * p.fps
        if got != p.hz:
            tree.fail(
                "ARITHMETIC",
                tree.recipe_path,
                f"{name}: {p.h}*{p.v}*{p.fps}={got} != hz={p.hz}",
            )
        else:
            print(f"OK ARITHMETIC {name}: {p.h}*{p.v}*{p.fps}={p.hz}")


def check_single_sot(tree: TreeModel, product: RecipePack, lp: dict[str, int]) -> None:
    if product.h is None or product.v is None or product.hz is None:
        tree.fail("SOT", tree.recipe_path, "product pack missing H/V/Hz in recipe")
        return
    # Recipe must define product numbers (SoT)
    print(
        f"OK SOT recipe product H={product.h} V={product.v} Hz={product.hz} "
        f"(pack={product.name})"
    )
    # present_core multi beam must match product H/V when numeric
    bh, bv, _ = extract_mp_beam_totals(tree.present_text)
    if bh is None and bv is None:
        tree.fail("SOT", tree.present_path, "could not parse present_beam_ppc H_TOTAL/V_TOTAL")
        return
    if bh is not None and bh != product.h:
        tree.fail(
            "SOT",
            tree.present_path,
            f"present_beam_ppc H_TOTAL={bh} != recipe product H={product.h} "
            f"(recipe/RTL drift defect class)",
        )
    elif bh is not None:
        print(f"OK SOT present_core H_TOTAL={bh} matches recipe")
    if bv is not None and bv != product.v:
        tree.fail(
            "SOT",
            tree.present_path,
            f"present_beam_ppc V_TOTAL={bv} != recipe product V={product.v}",
        )
    elif bv is not None:
        print(f"OK SOT present_core V_TOTAL={bv} matches recipe")

    # PLL default pix string (non-74_25 branch) must match product Hz
    # Read `define MISTERPLEX_CLK_PIX_PLL_FREQ in the else of 74_25
    code = strip_sv_comments(tree.pll_text)
    # Split on PRESENT_CLK_PIX_74_25 ifdef for default define
    default_mhz = None
    # Prefer define not under 74_25 / CEA24
    for m in re.finditer(
        r'`define\s+MISTERPLEX_CLK_PIX_PLL_FREQ\s+"([^"]+)"',
        code,
    ):
        default_mhz = m.group(1)
    # If multiple, last wins in simple files; better: take define after `else of 74_25
    m_blk = re.search(
        r"`ifdef\s+PRESENT_CLK_PIX_74_25.*?`else\s*`define\s+MISTERPLEX_CLK_PIX_PLL_FREQ\s+\"([^\"]+)\"",
        code,
        re.S,
    )
    if m_blk:
        default_mhz = m_blk.group(1)
    # CEA24 nested?
    m_blk2 = re.search(
        r"`ifndef\s+PRESENT_CLK_PIX_CEA24\s*`define\s+MISTERPLEX_CLK_PIX_PLL_FREQ\s+\"([^\"]+)\"",
        code,
        re.S,
    )
    if m_blk2:
        default_mhz = m_blk2.group(1)
    if default_mhz is None:
        tree.fail("SOT", tree.pll_path, "MISTERPLEX_CLK_PIX_PLL_FREQ define not found")
    else:
        pll_hz = parse_mhz_string(default_mhz)
        if pll_hz is None:
            tree.fail("SOT", tree.pll_path, f"unparseable PLL pix freq {default_mhz!r}")
        elif pll_hz != product.hz:
            tree.fail(
                "SOT",
                tree.pll_path,
                f"PLL default pix {default_mhz} ({pll_hz}) != recipe product Hz={product.hz}",
            )
        else:
            print(f"OK SOT pll default pix {default_mhz} matches recipe product Hz")


def check_stale(tree: TreeModel, product: RecipePack, packs: dict[str, RecipePack]) -> None:
    """Fail retired 720p24 values used as product; allow CEA60 1650."""
    # Product must not be retired 29.7
    if product.hz == RETIRED_PIX_HZ:
        tree.fail(
            "STALE",
            tree.recipe_path,
            f"product Hz={product.hz} is retired illegal 29.7 MHz compact-24",
        )
    if product.h == RETIRED_COMPACT24_H and (product.fps or 24) == 24 and product.hz != packs.get("CEA60", RecipePack("x")).hz:
        # 1650@24 is retired compact-24 (CEA60 is 1650@60)
        if product.hz in (RETIRED_PIX_HZ, 30_000_000) or (
            product.hz is not None and product.h is not None and product.v is not None
            and product.h * product.v * 24 == product.hz
            and product.h == 1650
        ):
            # Exact 1650*750*24=29.7 is stale; 30 MHz @1650 is PLL-legal but NOT exact-24
            # Parent decision: product is 1600x750@28.8. Flag 1650@24 product as stale for exact-24 gate.
            tree.fail(
                "STALE",
                tree.recipe_path,
                f"product H_TOTAL={product.h} @24 is retired compact-24 geometry "
                f"(exact-24 product is H=1600); hz={product.hz}",
            )

    # Code-scan (comments stripped) for retired pix string/Hz as definitions
    for label, text, path, stripper in (
        ("pll", tree.pll_text, tree.pll_path, strip_sv_comments),
        ("present", tree.present_text, tree.present_path, strip_sv_comments),
        ("recipe", tree.recipe_text, tree.recipe_path, strip_sv_comments),
        ("sdc", tree.sdc_text, tree.sdc_path, strip_hash_comments),
        ("qsf", tree.qsf_text, tree.qsf_path, strip_hash_comments),
        ("clkstat", tree.clkstat_text, tree.clkstat_path, strip_sv_comments),
    ):
        code = stripper(text)
        # Retired Hz literals in code
        if re.search(r"\b29_700_000\b|\b29700000\b", code):
            # Allow CEA-related false positives? 29700000 only means 29.7
            # Allow if only on the right-hand side of a deliberately named RETIRED constant? still fail.
            tree.fail(
                "STALE",
                path,
                f"{label}: code contains retired 29.7 Hz literal (29_700_000/29700000)",
            )
        for s in RETIRED_PIX_MHZ_STRS:
            if s in code:
                tree.fail(
                    "STALE",
                    path,
                    f"{label}: code contains retired pix string {s!r}",
                )

    # present_core numeric H_TOTAL(1650) under multi beam is stale for exact-24 product
    bh, bv, _ = extract_mp_beam_totals(tree.present_text)
    if bh == RETIRED_COMPACT24_H:
        # Allowed only if product is CEA60 (not 24) — product is 24 path
        tree.fail(
            "STALE",
            tree.present_path,
            "present_beam_ppc H_TOTAL=1650 is retired for product 720p24 "
            "(legitimate as CEA60 VIC4 only — see positive control)",
        )

    # Positive evidence path for CEA60 1650: recipe must still carry CEA60_H=1650
    cea60 = packs.get("CEA60")
    if cea60 and cea60.h == 1650 and cea60.hz == 74_250_000:
        print("OK STALE_ALLOW CEA60 H=1650 @ 74.25e6 (legitimate VIC4 — not flagged as product)")
    elif cea60 and cea60.h == 1650:
        print(f"OK STALE_ALLOW CEA60 H=1650 hz={cea60.hz}")
    else:
        tree.fail(
            "STALE",
            tree.recipe_path,
            "CEA60 pack missing legitimate H=1650 (positive-control anchor absent)",
        )


def check_pll(tree: TreeModel, product: RecipePack) -> None:
    if product.hz is None:
        tree.fail("PLL", tree.recipe_path, "product Hz missing — cannot test PLL")
        return
    macros = active_qsf_macros(tree.qsf_text)
    outs = [CLK_SYS_HZ, CLK_DDR_HZ, product.hz]
    ok, msg = pll_shared_integer_n_ok(outs)
    if not ok:
        tree.fail(
            "PLL",
            tree.pll_path,
            f"shared integer-N unrealisable for outs MHz "
            f"{[o/1e6 for o in outs]}: {msg}",
        )
    else:
        print(f"OK PLL {{20,90,pix={product.hz/1e6}}} {msg}")

    # SDRAM 142 hazard
    sdram_macro = "SDRAM_CLK_142" in macros
    ddr_store = "DDR_FRAME_STORE" in macros
    if sdram_macro and not ddr_store:
        outs_s = [CLK_SYS_HZ, CLK_DDR_HZ, SDRAM_142_HZ, product.hz]
        ok_s, msg_s = pll_shared_integer_n_ok(outs_s)
        if not ok_s:
            tree.fail(
                "PLL",
                tree.qsf_path,
                f"SDRAM_CLK_142 live without DDR_FRAME_STORE prune: "
                f"shared PLL unrealisable {msg_s}",
            )
        else:
            print(f"OK PLL with live SDRAM142 {msg_s}")
    elif sdram_macro and ddr_store:
        # Standing hazard: if SDRAM re-enabled, lcm blows up
        outs_s = [CLK_SYS_HZ, CLK_DDR_HZ, SDRAM_142_HZ, product.hz]
        ok_s, msg_s = pll_shared_integer_n_ok(outs_s)
        if ok_s:
            print(f"OK PLL SDRAM142+pix unexpectedly realisable: {msg_s}")
        else:
            print(
                "OK PLL_HAZARD_RECORDED: SDRAM_CLK_142 + DDR_FRAME_STORE prune path; "
                f"if SDRAM goes live, shared PLL fails: {msg_s}"
            )
        # Do not fail — parent documents prune. Fail only if someone claims live SDRAM.
    # Retired 29.7 must be unrealisable with 20/90 (control)
    ok_bad, msg_bad = pll_shared_integer_n_ok([CLK_SYS_HZ, CLK_DDR_HZ, RETIRED_PIX_HZ])
    if ok_bad:
        tree.fail(
            "PLL",
            tree.pll_path,
            f"internal control: 29.7 with 20/90 unexpectedly realisable: {msg_bad}",
        )
    else:
        print(f"OK PLL control: 29.7+20+90 unrealisable ({msg_bad[:80]}…)")


def check_rate_band(tree: TreeModel, product: RecipePack) -> None:
    lo, hi = extract_fps_band(tree.clkstat_text)
    if lo is None or hi is None:
        # Band only required when plex_clk_status defines a pass window
        if "FPS_PASS_LO" in strip_sv_comments(tree.clkstat_text):
            tree.fail("RATE_BAND", tree.clkstat_path, "FPS_PASS_LO present but unparsed")
        else:
            print("OK RATE_BAND skipped (no FPS_PASS_* in clk_status)")
        return
    if lo > hi:
        tree.fail("RATE_BAND", tree.clkstat_path, f"FPS_PASS_LO={lo} > HI={hi}")
        return
    if product.h is None or product.v is None or product.hz is None:
        tree.fail("RATE_BAND", tree.recipe_path, "product incomplete for band check")
        return
    t = fps_x10_exact(product.h, product.v, product.hz)
    if t is None:
        # non-integer fps_x10 — compute floor/ceil and require band cover true rate*10
        true = 10.0 * product.hz / (product.h * product.v)
        t_lo = int(math.floor(true + 1e-12))
        t_hi = int(math.ceil(true - 1e-12))
        if hi < t_lo or lo > t_hi:
            tree.fail(
                "RATE_BAND",
                tree.clkstat_path,
                f"band [{lo},{hi}] excludes true fps_x10≈{true:.4f}",
            )
            return
        t = int(round(true))
        print(f"OK RATE_BAND non-integer true={true:.6f} rounded_t={t} band=[{lo},{hi}]")
    if not (lo <= t <= hi):
        tree.fail(
            "RATE_BAND",
            tree.clkstat_path,
            f"band FPS_PASS=[{lo},{hi}] excludes exact target fps_x10={t} "
            f"(H={product.h} V={product.v} Hz={product.hz})",
        )
        return
    # General offset trap: band must not be entirely on one side of target with
    # a closer integer outside — equivalent to requiring inclusion (done).
    # Additional: width-bounded preference — if an integer w in [lo,hi] is farther
    # from true fps than target, fine; if target excluded already failed.
    # Defect twin: lo=241 hi=244 t=240 → caught above.
    print(f"OK RATE_BAND target fps_x10={t} inside [{lo},{hi}]")

    # If band accepts some integer and target is exact-24 (t=240), ensure we didn't
    # only accept a shifted island — already OK.
    # Generalise wrong-rate preference: center of band should be within half-width of T
    center = 0.5 * (lo + hi)
    half = 0.5 * (hi - lo)
    if abs(center - t) > half + 1e-9:
        tree.fail(
            "RATE_BAND",
            tree.clkstat_path,
            f"band center {center} farther than half-width {half} from target {t}",
        )


def run_tree(tree: TreeModel) -> int:
    lp = parse_localparam_ints(tree.recipe_text)
    if not lp:
        tree.fail("SOT", tree.recipe_path, "no localparam ints parsed from recipe")
    packs = build_packs(lp)
    product = product_pack(lp, packs)

    print(
        f"RASTER_CLOCK_GATE product_hz={product.hz} H={product.h} V={product.v} "
        f"fps={product.fps}"
    )
    check_arithmetic(tree, packs, product)
    check_single_sot(tree, product, lp)
    check_stale(tree, product, packs)
    check_pll(tree, product)
    check_rate_band(tree, product)

    if tree.findings:
        print("RASTER_CLOCK_REJECTED(exit=1):", file=sys.stderr)
        for f in tree.findings:
            print(f"  [{f.check}] {f.path}: {f.detail}", file=sys.stderr)
        return 1
    print("PASS raster_clock_consistency: SOT+stale+arith+pll+rate_band")
    return 0


# --- Fixture assembly (runtime only; no retired literals stored as live SoT in repo tests) ---

def _jz(*parts: str) -> str:
    return "\n".join(parts) + "\n"


def fixture_recipe_good() -> str:
    # Exact-24 product 1600x750 @ 28.8e6; CEA60 keeps legitimate 1650
    h = 1600
    v = 750
    fps = 24
    hz = h * v * fps
    assert hz == 28_800_000
    cea60_h = 1650
    cea60_v = 750
    cea60_fps = 60
    cea60_hz = cea60_h * cea60_v * cea60_fps
    return _jz(
        "// fixture recipe GOOD exact-24",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_H     = {h};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_V     = {v};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = {fps};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = {hz};",
        f"localparam int MISTERPLEX_CLKPIX_EXACT24_H     = {h};",
        f"localparam int MISTERPLEX_CLKPIX_EXACT24_V     = {v};",
        f"localparam int MISTERPLEX_CLKPIX_EXACT24_HZ    = {hz};",
        "localparam int MISTERPLEX_CLKPIX_CEA24_H       = 3300;",
        "localparam int MISTERPLEX_CLKPIX_CEA24_V       = 750;",
        "localparam int MISTERPLEX_CLKPIX_CEA24_FPS     = 24;",
        "localparam int MISTERPLEX_CLKPIX_CEA24_HZ      = 59400000;",
        f"localparam int MISTERPLEX_CLKPIX_CEA60_H       = {cea60_h};",
        f"localparam int MISTERPLEX_CLKPIX_CEA60_V       = {cea60_v};",
        f"localparam int MISTERPLEX_CLKPIX_CEA60_HZ      = {cea60_hz};",
        f"localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = {hz};",
        "localparam int MISTERPLEX_CLKPIX_FPS_24        = 24;",
    )


def fixture_recipe_bad_297() -> str:
    # Assemble retired values without keeping them as repo SoT
    h = 1600 + 50  # 1650
    v = 750
    fps = 24
    hz = h * v * fps  # 29700000
    return _jz(
        "// fixture recipe BAD retired compact-24",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_H     = {h};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_V     = {v};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = {fps};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = {hz};",
        "localparam int MISTERPLEX_CLKPIX_CEA60_H       = 1650;",
        "localparam int MISTERPLEX_CLKPIX_CEA60_V       = 750;",
        "localparam int MISTERPLEX_CLKPIX_CEA60_HZ      = 74250000;",
        f"localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = {hz};",
    )


def fixture_pll(pix_mhz: str) -> str:
    return _jz(
        '`ifdef PRESENT_CLK_PIX_74_25',
        '`define MISTERPLEX_CLK_PIX_PLL_FREQ "74.250000 MHz"',
        "`else",
        f'`define MISTERPLEX_CLK_PIX_PLL_FREQ "{pix_mhz}"',
        "`endif",
        "altera_pll #(",
        '.output_clock_frequency0("20.000000 MHz"),',
        '.output_clock_frequency2("90.000000 MHz"),',
        ".output_clock_frequency3(`MISTERPLEX_CLK_PIX_PLL_FREQ),",
        ")",
    )


def fixture_present(h: int, v: int) -> str:
    return _jz(
        "`ifdef PRESENT_MULTI_PIXEL",
        "present_beam_ppc #(",
        ".PX_PER_CLK(2),",
        ".H_DE(1280),",
        f".H_TOTAL({h}),",
        ".V_ACTIVE(720),",
        f".V_TOTAL({v}),",
        ") u_mp_beam (",
        ".clk(clk)",
        ");",
        "`endif",
    )


def fixture_clkstat(lo: int, hi: int) -> str:
    return _jz(
        f"localparam int FPS_PASS_LO = {lo};",
        f"localparam int FPS_PASS_HI = {hi};",
        "wire fps_ok_w = (fx10_w >= 8'(FPS_PASS_LO)) && (fx10_w <= 8'(FPS_PASS_HI));",
    )


def fixture_qsf(ddr_store: bool = True, sdram142: bool = True) -> str:
    lines = [
        'set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"',
        'set_global_assignment -name VERILOG_MACRO "PRESENT_MULTI_PIXEL=1"',
    ]
    if sdram142:
        lines.append('set_global_assignment -name VERILOG_MACRO "SDRAM_CLK_142=1"')
    if ddr_store:
        lines.append('set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"')
    return _jz(*lines)


def fixture_sdc_good() -> str:
    return _jz(
        "# clk_pix product rate",
        "# general[3] pix domain",
        "set_clock_groups -asynchronous -group {pix} -group {sys ddr}",
    )


def run_self_test() -> int:
    print("EXECUTED check_raster_clock_consistency --self-test")
    fails: list[str] = []

    def expect(label: str, tree: TreeModel, want_rc: int, must_have: list[str] | None = None) -> None:
        # isolate findings
        tree.findings.clear()
        rc = run_tree(tree)
        print(f"SELFTEST {label}: rc={rc} want={want_rc}")
        if rc != want_rc:
            fails.append(f"{label}: rc={rc} want={want_rc} findings={[f.detail for f in tree.findings]}")
            return
        if must_have:
            blob = " ".join(f.detail for f in tree.findings) + " " + " ".join(
                f.check for f in tree.findings
            )
            for token in must_have:
                if token not in blob and rc != 0:
                    # on pass, must_have is N/A
                    fails.append(f"{label}: missing token {token!r} in findings")
        if want_rc != 0 and must_have:
            blob = "\n".join(f"[{f.check}] {f.detail}" for f in tree.findings)
            for token in must_have:
                if token not in blob:
                    fails.append(f"{label}: expected finding token {token!r} in:\n{blob}")

    # GOOD tree: exact-24 28.8 / 1600x750, band includes 240, CEA60 1650 present
    good = TreeModel(
        recipe_text=fixture_recipe_good(),
        pll_text=fixture_pll("28.800000 MHz"),
        present_text=fixture_present(1600, 750),
        clkstat_text=fixture_clkstat(238, 242),
        qsf_text=fixture_qsf(True, True),
        sdc_text=fixture_sdc_good(),
        recipe_path="fixture/recipe_good.svh",
        pll_path="fixture/pll_good.v",
        present_path="fixture/present_good.sv",
        clkstat_path="fixture/clkstat_good.sv",
        qsf_path="fixture/qsf_good.qsf",
        sdc_path="fixture/sdc_good.sdc",
    )
    expect("POS_exact24_tree", good, 0)

    # NEG: arithmetic broken (H*V*FPS != hz) via present mismatch + recipe corrupt
    bad_arith_recipe = fixture_recipe_good().replace(
        "localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = 28800000;",
        "localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = 28800001;",
    ).replace(
        "localparam int MISTERPLEX_CLKPIX_EXACT24_HZ    = 28800000;",
        "localparam int MISTERPLEX_CLKPIX_EXACT24_HZ    = 28800001;",
    ).replace(
        "localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = 28800000;",
        "localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = 28800001;",
    )
    bad_arith = TreeModel(
        recipe_text=bad_arith_recipe,
        pll_text=fixture_pll("28.800001 MHz"),
        present_text=fixture_present(1600, 750),
        clkstat_text=fixture_clkstat(238, 242),
        qsf_text=fixture_qsf(),
        sdc_text=fixture_sdc_good(),
    )
    expect("NEG_arithmetic", bad_arith, 1, must_have=["ARITHMETIC"])

    # NEG: SOT drift present H != recipe H
    drift = TreeModel(
        recipe_text=fixture_recipe_good(),
        pll_text=fixture_pll("28.800000 MHz"),
        present_text=fixture_present(1650, 750),  # drift
        clkstat_text=fixture_clkstat(238, 242),
        qsf_text=fixture_qsf(),
        sdc_text=fixture_sdc_good(),
        present_path="fixture/present_drift.sv",
    )
    expect("NEG_sot_drift", drift, 1, must_have=["SOT"])

    # NEG: stale 29.7 product recipe
    stale = TreeModel(
        recipe_text=fixture_recipe_bad_297(),
        pll_text=fixture_pll("29.700000 MHz"),
        present_text=fixture_present(1650, 750),
        clkstat_text=fixture_clkstat(241, 244),
        qsf_text=fixture_qsf(),
        sdc_text=fixture_sdc_good(),
        recipe_path="fixture/recipe_stale.svh",
        pll_path="fixture/pll_stale.v",
        present_path="fixture/present_stale.sv",
    )
    expect("NEG_stale_297", stale, 1, must_have=["STALE"])

    # POS control for 1650: good tree already has CEA60_H=1650 and must PASS
    # (explicit secondary assertion)
    cea_lp = parse_localparam_ints(fixture_recipe_good())
    if cea_lp.get("MISTERPLEX_CLKPIX_CEA60_H") != 1650:
        fails.append("POS_cea60_1650: fixture recipe lost CEA60 H=1650")
    else:
        print("OK SELFTEST POS_cea60_1650 anchor present in good fixture")

    # NEG: rate band excludes exact 24 (240) but accepts 242
    bad_band = TreeModel(
        recipe_text=fixture_recipe_good(),
        pll_text=fixture_pll("28.800000 MHz"),
        present_text=fixture_present(1600, 750),
        clkstat_text=fixture_clkstat(241, 244),
        qsf_text=fixture_qsf(),
        sdc_text=fixture_sdc_good(),
        clkstat_path="fixture/clkstat_badband.sv",
    )
    expect("NEG_rate_band_excludes_240", bad_band, 1, must_have=["RATE_BAND"])

    # NEG: PLL unrealisable — force product hz that cannot share VCO with 20/90
    # e.g. 29.7 already; use recipe claiming 29700000 but wait STALE also fires.
    # Use 23 MHz nonsense exact pack: H=2300 V=500 fps=20 → 23e6? 2300*500*20=23e6
    # Simpler: keep good geometry but pll/recipe hz = 23_000_000 with H*V*fps patched
    h, v, fps = 1600, 750, 24
    bad_hz = 23_000_000
    bad_pll_recipe = _jz(
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_H     = {h};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_V     = {v};",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = {fps};",
        # deliberately break arith AND pll — split: fix arith with fake fps?
        # For pure PLL: use H,V,fps matching hz: 2000*575*20 = 23e6
        "localparam int MISTERPLEX_CLKPIX_COMPACT_H     = 2000;",
        "localparam int MISTERPLEX_CLKPIX_COMPACT_V     = 575;",
        "localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = 20;",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = {bad_hz};",
        "localparam int MISTERPLEX_CLKPIX_CEA60_H       = 1650;",
        "localparam int MISTERPLEX_CLKPIX_CEA60_V       = 750;",
        "localparam int MISTERPLEX_CLKPIX_CEA60_HZ      = 74250000;",
        f"localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = {bad_hz};",
    )
    # Note: duplicate localparam — parser last wins. Rebuild cleanly:
    bad_pll_recipe = _jz(
        "localparam int MISTERPLEX_CLKPIX_COMPACT_H     = 2000;",
        "localparam int MISTERPLEX_CLKPIX_COMPACT_V     = 575;",
        "localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = 20;",
        f"localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = {bad_hz};",
        "localparam int MISTERPLEX_CLKPIX_CEA60_H       = 1650;",
        "localparam int MISTERPLEX_CLKPIX_CEA60_V       = 750;",
        "localparam int MISTERPLEX_CLKPIX_CEA60_HZ      = 74250000;",
        f"localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = {bad_hz};",
    )
    bad_pll = TreeModel(
        recipe_text=bad_pll_recipe,
        pll_text=fixture_pll("23.000000 MHz"),
        present_text=fixture_present(2000, 575),
        clkstat_text=fixture_clkstat(199, 201),
        qsf_text=fixture_qsf(),
        sdc_text=fixture_sdc_good(),
    )
    expect("NEG_pll_unrealisable", bad_pll, 1, must_have=["PLL"])

    # NEG: live SDRAM142 without prune + pix that makes lcm impossible
    # 20,90,142,28.8 — should fail
    live_sdram = TreeModel(
        recipe_text=fixture_recipe_good(),
        pll_text=fixture_pll("28.800000 MHz"),
        present_text=fixture_present(1600, 750),
        clkstat_text=fixture_clkstat(238, 242),
        qsf_text=fixture_qsf(ddr_store=False, sdram142=True),
        sdc_text=fixture_sdc_good(),
        qsf_path="fixture/qsf_live_sdram.qsf",
    )
    expect("NEG_sdram142_live", live_sdram, 1, must_have=["PLL"])

    if fails:
        print("SELFTEST_REJECTED(exit=1):", file=sys.stderr)
        for f in fails:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("PASS raster_clock_consistency self-test: all POS/NEG controls")
    return 0


def load_live(args: argparse.Namespace) -> TreeModel:
    paths = {
        "recipe": Path(args.recipe),
        "pll": Path(args.pll),
        "present": Path(args.present),
        "clkstat": Path(args.clkstat),
        "qsf": Path(args.qsf),
        "sdc": Path(args.sdc),
    }
    missing = [str(p) for p in paths.values() if not p.exists()]
    if missing:
        print("RASTER_CLOCK_REJECTED(exit=1): missing inputs:", file=sys.stderr)
        for m in missing:
            print(f"  {m}", file=sys.stderr)
        raise SystemExit(1)
    return TreeModel(
        recipe_text=read_text(paths["recipe"]),
        pll_text=read_text(paths["pll"]),
        present_text=read_text(paths["present"]),
        clkstat_text=read_text(paths["clkstat"]),
        qsf_text=read_text(paths["qsf"]),
        sdc_text=read_text(paths["sdc"]),
        recipe_path=str(paths["recipe"].relative_to(ROOT)) if paths["recipe"].is_relative_to(ROOT) else str(paths["recipe"]),
        pll_path=str(paths["pll"].relative_to(ROOT)) if paths["pll"].is_relative_to(ROOT) else str(paths["pll"]),
        present_path=str(paths["present"].relative_to(ROOT)) if paths["present"].is_relative_to(ROOT) else str(paths["present"]),
        clkstat_path=str(paths["clkstat"].relative_to(ROOT)) if paths["clkstat"].is_relative_to(ROOT) else str(paths["clkstat"]),
        qsf_path=str(paths["qsf"].relative_to(ROOT)) if paths["qsf"].is_relative_to(ROOT) else str(paths["qsf"]),
        sdc_path=str(paths["sdc"].relative_to(ROOT)) if paths["sdc"].is_relative_to(ROOT) else str(paths["sdc"]),
    )


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true", help="run assembled POS/NEG fixtures")
    ap.add_argument("--recipe", type=Path, default=DEFAULT_RECIPE)
    ap.add_argument("--pll", type=Path, default=DEFAULT_PLL)
    ap.add_argument("--present", type=Path, default=DEFAULT_PRESENT)
    ap.add_argument("--clkstat", type=Path, default=DEFAULT_CLKSTAT)
    ap.add_argument("--qsf", type=Path, default=DEFAULT_QSF)
    ap.add_argument("--sdc", type=Path, default=DEFAULT_SDC)
    args = ap.parse_args(argv[1:])
    if args.self_test:
        return run_self_test()
    print("EXECUTED check_raster_clock_consistency live-tree")
    tree = load_live(args)
    return run_tree(tree)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
