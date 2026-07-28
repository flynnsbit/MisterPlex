#!/usr/bin/env python3
"""On-chip block-RAM budget gate for product RTL.

Reachability proves a module is in the graph.  files.qip proves its file is
handed to Quartus.  post-fit hierarchy proves it survived synthesis.  None of
them catch an array that is compiled, instantiated, and *arithmetically
impossible* -- declared larger than the device has memory to hold.

Measured case that motivated this gate: decode_stub declares

    localparam int DPB_FRAME_BYTES = WIDTH * HEIGHT + 2 * ((WIDTH/2) * (HEIGHT/2));
    (* ram_style = "block" *) reg [7:0] dpb_mem [0:2*DPB_FRAME_BYTES-1];

With the geometry the Quartus project actually sets (Plex.qsf: FRAME_W=640,
FRAME_H=480) that is 921,600 bytes = 7,372,800 bits, which is 1.30x the entire
M10K capacity of the 5CSEBA6 (553 x 10,240 = 5,662,720 bits).  w-fit-o5 measured
the fitted design giving decode_stub 256 M10K = 262,144 bytes -- 28% of the
declared array.  The remainder was not implemented.  Every gate we own was green
while the diagnostic frame store was silently a fraction of its declared size.

SCOPE / KNOWN LIMITS (stated up front, as w-audit rightly demands):
  * It is source-level arithmetic, not a fit report.  `make post-fit-hierarchy`
    and the fit resource summary remain the real oracles.
  * Parameter propagation is approximated: a module parameter named WIDTH,
    HEIGHT, FRAME_W or FRAME_H is evaluated using the Plex.qsf geometry macros,
    because that is how the product instantiates them.  Other parameters use
    their in-file defaults.  An array whose size depends on some other
    overridden parameter will be measured at its default, not its instantiated,
    size.
  * It only sees arrays it can evaluate; anything it cannot evaluate is
    reported as UNEVALUATED rather than silently passing.
  * Only files listed in files.qip are considered, since anything else is not
    in the design at all.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPGA = ROOT / "fpga" / "Plex_MiSTer"
QIP = FPGA / "files.qip"
QSF = FPGA / "Plex.qsf"
MANIFEST = FPGA / "rtl" / "onchip_ram_budget.txt"

# Cyclone V 5CSEBA6U23I7 (DE10-Nano): 553 M10K blocks of 10,240 bits.
DEVICE_M10K = 553
M10K_BITS = 10240
DEVICE_BITS = DEVICE_M10K * M10K_BITS

ARRAY = re.compile(
    r"(?P<attr>\(\*[^*]*?ram_?style[^*]*?\*\)\s*)?"
    r"\b(?:reg|logic)\s+(?:signed\s+)?"
    r"(?P<width>\[[^\]]+\]\s*)?"
    r"(?P<name>\w+)\s*"
    r"(?P<depth>\[[^;]+\])\s*;"
)


def fail(msg: str) -> int:
    print(f"ONCHIP_RAM_BUDGET_FAIL: {msg}", file=sys.stderr)
    return 1


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda m: " " if "ram_style" not in m.group(0) else m.group(0), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def qsf_geometry() -> dict[str, int]:
    geom: dict[str, int] = {}
    if QSF.exists():
        for name, value in re.findall(
            r'VERILOG_MACRO\s+"(\w+)=(\d+)"', QSF.read_text(encoding="utf-8")
        ):
            if name in ("FRAME_W", "FRAME_H"):
                geom[name] = int(value)
    return geom


def qip_files() -> list[Path]:
    if not QIP.exists():
        return []
    out = []
    for rel in re.findall(r"[\w./-]+\.s?v", QIP.read_text(encoding="utf-8")):
        p = FPGA / rel
        if p.exists():
            out.append(p)
    return out


def evaluate(expr: str, env: dict[str, int]) -> int | None:
    expr = re.sub(r"`(\w+)", r"\1", expr).strip()
    expr = re.sub(r"\b\d+'[sSbBhHdDoO]*([0-9a-fA-F_]+)", r"\1", expr)
    if not expr or not re.fullmatch(r"[\w\s()*+\-/<>]+", expr):
        return None
    try:
        value = eval(expr.replace("/", "//"), {"__builtins__": {}}, dict(env))  # noqa: S307
    except Exception:
        return None
    return value if isinstance(value, int) else None


def balanced_value(text: str, at: int) -> str:
    """Read a parameter value from `at` up to a depth-0 `;`, `,` or `)`."""
    depth, out = 0, []
    for ch in text[at:]:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            if depth == 0:
                break
            depth -= 1
        elif ch in ";," and depth == 0:
            break
        out.append(ch)
    return "".join(out)


def module_defs(files: list[Path]) -> tuple[dict[str, str], dict[str, str]]:
    bodies: dict[str, str] = {}
    headers: dict[str, str] = {}
    for path in files:
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        for m in re.finditer(r"^\s*module\s+(\w+)(.*?)^endmodule", text, re.M | re.S):
            name, body = m.group(1), m.group(2)
            bodies.setdefault(name, body)
            headers.setdefault(name, path.name)
    return bodies, headers


def param_defaults(body: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in re.finditer(r"\b(?:localparam|parameter)\s+(?:int|bit|logic|reg|integer|unsigned)?\s*(?:\[[^\]]*\]\s*)?(\w+)\s*=", body):
        out[m.group(1)] = balanced_value(body, m.end())
    return out


def resolve_env(body: str, overrides: dict[str, int]) -> dict[str, int]:
    env = dict(overrides)
    decls = param_defaults(body)
    for _ in range(4):
        for name, raw in decls.items():
            if name in overrides:
                continue
            value = evaluate(raw, env)
            if value is not None:
                env[name] = value
    return env


INSTANCE = re.compile(
    r"\b(\w+)\s*(#\s*\((?:[^()]|\([^()]*\))*\))?\s*\\?(\w+)\s*\(",
    re.S,
)


def instances(body: str, known: set[str]) -> list[tuple[str, str]]:
    out = []
    for m in INSTANCE.finditer(body):
        mod, params, inst = m.group(1), m.group(2) or "", m.group(3)
        if mod in known and mod != inst:
            out.append((mod, params))
    return out


def span(expr: str, env: dict[str, int]) -> int | None:
    expr = expr.strip().strip("[]").strip()
    if ":" not in expr:
        return None
    hi, lo = expr.split(":", 1)
    a, b = evaluate(hi, env), evaluate(lo, env)
    if a is None or b is None:
        return None
    return abs(a - b) + 1


def arrays_in(body: str, env: dict[str, int]) -> list[tuple[str, int, bool, bool]]:
    """(name, bits, is_block_ram, evaluated)"""
    found = []
    for m in ARRAY.finditer(body):
        depth = span(m.group("depth"), env)
        width = span(m.group("width"), env) if m.group("width") else 1
        blk = bool(m.group("attr"))
        if depth is None or width is None:
            found.append((m.group("name"), 0, blk, False))
            continue
        found.append((m.group("name"), width * depth, blk, True))
    return found


def parse_manifest() -> dict[str, str]:
    allowed: dict[str, str] = {}
    if not MANIFEST.exists():
        return allowed
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        m = re.match(r"^([^:\s]+:[^:\s]+):\s*(.*)$", line)
        if not m:
            continue
        allowed[m.group(1)] = m.group(2).strip()
    return allowed


def main() -> int:
    geom = qsf_geometry()
    if "FRAME_W" not in geom or "FRAME_H" not in geom:
        return fail(
            "could not read FRAME_W/FRAME_H VERILOG_MACRO from Plex.qsf; "
            "the budget cannot be computed against the geometry the product fits"
        )

    files = qip_files()
    if not files:
        return fail(f"no product files resolved from {QIP.relative_to(ROOT)}")

    bodies, owner = module_defs(files)
    if "emu" not in bodies:
        return fail("top module `emu` not found among files.qip sources")

    oversized: list[tuple[str, int]] = []
    unevaluated: list[str] = []
    measured: dict[str, int] = {}
    total_block_bits = 0

    # Walk from the top with real parameter propagation: a module parameter is
    # only frame-sized if the product actually instantiates it that way.
    top_env = {"FRAME_W": geom["FRAME_W"], "FRAME_H": geom["FRAME_H"]}
    seen: set[tuple[str, tuple]] = set()
    stack = [("emu", top_env)]
    while stack:
        mod, overrides = stack.pop()
        key = (mod, tuple(sorted(overrides.items())))
        if key in seen:
            continue
        seen.add(key)
        body = bodies.get(mod)
        if body is None:
            continue
        env = resolve_env(body, overrides)

        for name, bits, blk, ok in arrays_in(body, env):
            ident = f"{owner.get(mod, mod)}:{name}"
            if not ok:
                if blk:
                    unevaluated.append(ident)
                continue
            if bits < 4096:
                continue
            if bits > measured.get(ident, 0):
                measured[ident] = bits
            if blk:
                total_block_bits += bits
            if bits > DEVICE_BITS and ident not in [o[0] for o in oversized]:
                oversized.append((ident, bits))

        for child, params in instances(body, set(bodies)):
            child_over: dict[str, int] = {}
            for pm in re.finditer(r"\.\s*(\w+)\s*\(", params):
                value = evaluate(balanced_value(params, pm.end()), env)
                if value is not None:
                    child_over[pm.group(1)] = value
            stack.append((child, child_over))

    allowed = parse_manifest()
    bad = False

    for key, bits in sorted(oversized):
        if key in allowed:
            print(
                f"ONCHIP_RAM_BUDGET_KNOWN {key} {bits:,} bits "
                f"({bits / DEVICE_BITS:.2f}x device) -- {allowed[key]}"
            )
            continue
        print(
            f"ONCHIP_RAM_ARRAY_EXCEEDS_DEVICE {key} declares {bits:,} bits = "
            f"{bits / DEVICE_BITS:.2f}x the whole device M10K "
            f"({DEVICE_BITS:,} bits); it cannot be implemented on-chip",
            file=sys.stderr,
        )
        bad = True

    for key in sorted(allowed):
        if key not in dict(oversized):
            print(
                f"STALE_ONCHIP_RAM_BUDGET_ENTRY {key} is declared over-budget but "
                "no longer measures that way; remove it from the manifest",
                file=sys.stderr,
            )
            bad = True

    for key in sorted(set(unevaluated)):
        print(
            f"UNEVALUATED_BLOCK_RAM {key} has a ram_style array whose size could "
            "not be evaluated; it is NOT covered by this budget",
            file=sys.stderr,
        )
        bad = True

    if bad:
        return fail(
            "product RTL declares on-chip memory that cannot exist in this device"
        )

    print(
        "ONCHIP_RAM_BUDGET_OK "
        f"frame={geom['FRAME_W']}x{geom['FRAME_H']} files={len(files)} "
        f"arrays_measured={len(measured)} block_ram_bits={total_block_bits:,} "
        f"device_bits={DEVICE_BITS:,} known_over_budget={len(allowed)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
