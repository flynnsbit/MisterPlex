#!/usr/bin/env bash
# Static proof: under DDR_FRAME_STORE, decode_stub cannot drive product pixels;
# PRODUCT_NO_STUB scaffolding exists; research path keeps the instance.
# Rule 0: fail hard on missing evidence. Red-before-green via temp strip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PC="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
PX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
SP="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
DOC="$ROOT/docs/phase3-decode.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

[[ -f "$PC" && -f "$PX" && -f "$SP" && -f "$QSF" ]] || fail "missing RTL/QSF"

# --- 1) present_core: DDR branch does not wire fs_wr into ddr_frame_store -----
python3 - "$PC" <<'PY' || exit 1
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="ignore")
# Find the DDR_FRAME_STORE block that instantiates ddr_frame_store (not the port ifdef).
found = False
for m in re.finditer(r"`ifdef\s+DDR_FRAME_STORE\b", text):
    start = m.end()
    depth = 1
    i = start
    else_at = None
    end_at = None
    while i < len(text) and depth:
        mm = re.search(r"`(ifdef|ifndef|elsif|else|endif)\b", text[i:])
        if not mm:
            break
        tok = mm.group(1)
        pos = i + mm.start()
        if tok in ("ifdef", "ifndef"):
            depth += 1
        elif tok == "elsif":
            if depth == 1 and else_at is None:
                else_at = pos  # treat as branch split
        elif tok == "else":
            if depth == 1 and else_at is None:
                else_at = pos
        elif tok == "endif":
            if depth == 1:
                end_at = pos
            depth -= 1
        i = i + mm.end()
    if else_at is None or end_at is None:
        continue
    ddr = text[start:else_at]
    legacy = text[else_at:end_at]
    if "ddr_frame_store" not in ddr:
        continue
    found = True
    if not re.search(r"assign\s+fs_wr_ready\s*=\s*1'b1", ddr):
        print("FAIL: DDR branch must tie fs_wr_ready=1 (no SPI wr path)", file=sys.stderr)
        sys.exit(1)
    if re.search(r"\.wr_en\s*\(\s*fs_wr_en\s*\)", ddr):
        print("FAIL: DDR branch still maps .wr_en(fs_wr_en)", file=sys.stderr)
        sys.exit(1)
    if re.search(r"\.swap_banks\s*\(\s*fs_swap\s*\)", ddr):
        print("FAIL: DDR branch maps swap_banks(fs_swap)", file=sys.stderr)
        sys.exit(1)
    if not re.search(r"\.wr_en\s*\(\s*fs_wr_en\s*\)", legacy):
        print("FAIL: legacy frame_store lost .wr_en(fs_wr_en)", file=sys.stderr)
        sys.exit(1)
    print("present_core DDR branch: fs_wr disconnected from ddr_frame_store")
    break
if not found:
    print("FAIL: no DDR_FRAME_STORE block containing ddr_frame_store", file=sys.stderr)
    sys.exit(1)
PY
pass "present_core DDR fs_wr disconnect"

# Exact consumer count: fs_wr_en only as port + legacy .wr_en (shipping else not compiled)
python3 - "$PC" <<'PY2' || exit 1
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="ignore")
# all fs_wr_en mentions
hits = [(i+1, line.rstrip()) for i, line in enumerate(text.splitlines()) if "fs_wr_en" in line]
if len(hits) != 2:
    print(f"FAIL: expected exactly 2 fs_wr_en lines (port + legacy map), got {len(hits)}:", hits, file=sys.stderr)
    sys.exit(1)
if "input" not in hits[0][1]:
    print("FAIL: first fs_wr_en is not the port", hits[0], file=sys.stderr); sys.exit(1)
if not re.search(r"\.wr_en\s*\(\s*fs_wr_en\s*\)", hits[1][1]):
    print("FAIL: second fs_wr_en is not .wr_en(fs_wr_en)", hits[1], file=sys.stderr); sys.exit(1)
print(f"fs_wr_en consumers: port L{hits[0][0]} + legacy map L{hits[1][0]} only")
PY2
pass "fs_wr_en exactly port+legacy (else-only consumer)"


# --- 2) Plex.sv: ddr_swap / ddr_wr tied 0 under DDR_FRAME_STORE --------------
python3 - "$PX" <<'PY' || exit 1
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="ignore")
if not re.search(r"assign\s+ddr_wr_en\s*=\s*1'b0", text):
    print("FAIL: assign ddr_wr_en=0 missing", file=sys.stderr); sys.exit(1)
if not re.search(r"assign\s+ddr_swap\s*=\s*1'b0", text):
    print("FAIL: assign ddr_swap=0 missing", file=sys.stderr); sys.exit(1)
# Must sit under a DDR_FRAME_STORE ifdef (not global always-on)
ok = False
for m in re.finditer(r"`ifdef\s+DDR_FRAME_STORE\b([\s\S]*?)(?:`else|`endif)", text):
    blk = m.group(1)
    if re.search(r"assign\s+ddr_swap\s*=\s*1'b0", blk) and re.search(
        r"assign\s+ddr_wr_en\s*=\s*1'b0", blk
    ):
        ok = True
        break
if not ok:
    print("FAIL: ddr_swap/ddr_wr_en ties not inside DDR_FRAME_STORE block", file=sys.stderr)
    sys.exit(1)
if not re.search(r"f1_swap\s*\|\s*ddr_swap", text):
    print("FAIL: host_owns_fs latch source missing", file=sys.stderr); sys.exit(1)
if not re.search(r"stub_allow\s*=\s*~host_owns_fs", text):
    print("FAIL: stub_allow formula missing", file=sys.stderr); sys.exit(1)
if "(* keep = 1 *)" not in text or "_keep_hybrid_product" not in text:
    print("FAIL: _keep_hybrid_product keep missing", file=sys.stderr); sys.exit(1)
print("Plex.sv: ddr_swap tied 0; host_owns_fs/stub_allow/_keep present")
PY
pass "Plex.sv DDR host_owns / ddr_swap ties"

# --- 3) PRODUCT_NO_STUB scaffolding in stream_path ---------------------------
grep -q 'PRODUCT_NO_STUB' "$SP" || fail "stream_path.sv missing PRODUCT_NO_STUB"
grep -q '`ifndef PRODUCT_NO_STUB' "$SP" || fail "missing \`ifndef PRODUCT_NO_STUB"
grep -q 'decode_stub' "$SP" || fail "decode_stub instance missing (research path)"
# else branch must zero product_recon_ok and fs_wr_en
python3 - "$SP" <<'PY' || exit 1
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="ignore")
m = re.search(r"`ifndef\s+PRODUCT_NO_STUB\b([\s\S]*?)`else([\s\S]*?)`endif", text)
if not m:
    print("FAIL: PRODUCT_NO_STUB ifndef/else/endif block not found", file=sys.stderr)
    sys.exit(1)
keep, drop = m.group(1), m.group(2)
if "decode_stub" not in keep:
    print("FAIL: decode_stub not in research (`ifndef`) branch", file=sys.stderr)
    sys.exit(1)
if "decode_stub" in drop:
    print("FAIL: decode_stub still in PRODUCT_NO_STUB else branch", file=sys.stderr)
    sys.exit(1)
for pat in [r"assign\s+product_recon_ok\s*=\s*1'b0", r"assign\s+fs_wr_en\s*=\s*1'b0",
            r"assign\s+fs_swap\s*=\s*1'b0", r"assign\s+stub_busy\s*=\s*1'b0"]:
    if not re.search(pat, drop):
        print(f"FAIL: else branch missing {pat}", file=sys.stderr)
        sys.exit(1)
print("PRODUCT_NO_STUB scaffolding OK")
PY
pass "PRODUCT_NO_STUB stream_path scaffolding"

# --- 4) QSF: macro documented but not enabled by default ---------------------
grep -q 'PRODUCT_NO_STUB' "$QSF" || fail "Plex.qsf missing PRODUCT_NO_STUB comment"
if grep -E '^set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB' "$QSF" >/dev/null; then
  # Intentional product fit: ALLOW_PRODUCT_NO_STUB_ACTIVE=1 (parent-granted slot).
  if [[ "${ALLOW_PRODUCT_NO_STUB_ACTIVE:-0}" == "1" ]]; then
    pass "QSF PRODUCT_NO_STUB ACTIVE (ALLOW_PRODUCT_NO_STUB_ACTIVE=1 fit mode)"
  else
    fail "PRODUCT_NO_STUB is ACTIVE in QSF — product default must stay commented until fit grant (or set ALLOW_PRODUCT_NO_STUB_ACTIVE=1)"
  fi
else
  grep -q '# set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"' "$QSF" \
    || fail "commented PRODUCT_NO_STUB assignment missing from QSF"
  pass "QSF PRODUCT_NO_STUB commented (not default-on)"
fi

# --- 5) Doc anchors + banned withdrawn claims --------------------------------
grep -q 'PRODUCT_NO_STUB' "$DOC" || fail "docs/phase3-decode.md missing PRODUCT_NO_STUB section"
grep -q 'physically unconnected\|no consumer' "$DOC" \
  || fail "doc missing stronger unconnected-fs_wr claim"
grep -q 'inert gate\|dead logic' "$DOC" \
  || fail "doc must call host_owns_fs/stub_allow dead/inert under DDR_FRAME_STORE"
grep -q 'Method rule' "$DOC" || fail "doc missing hierarchy Method rule"
grep -q 'first-macroblock residual probe\|First MB' "$DOC" \
  || fail "doc missing first-MB residual probe framing"
grep -q '8fdf440f' "$DOC" && grep -q 'fit-t7b-prog480' "$DOC" \
  || fail "doc must cite 8fdf440f with fit-t7b-prog480 path"
# Withdrawn absolute-CAVLC-absence: fail if a line asserts it without probe/scope framing
if grep -Ein 'no CAVLC entropy decode in fabric|there is no CAVLC' "$DOC"   | grep -Eiv 'withdrawn|probe|do not|never proves|equating|trap'; then
  fail "doc still claims absolute CAVLC absence (withdrawn — use scope/probe framing)"
fi
if grep -Eiq 'first ARM DDR swap latches host_owns|ARM pushes a DDR frame.*host_owns_fs' "$DOC"; then
  fail "doc still has withdrawn host_owns_fs-on-DDR-swap mechanism"
fi
if grep -Eiq 'RAM at 84% is the binding constraint|Free M10K today is \*\*88\*\* — binding' "$DOC"; then
  fail "doc still slogans RAM blocks as the sole binding constraint"
fi
grep -q '84% of blocks but only 53% of bits\|84% of blocks but only 53%' "$DOC" \
  || fail "doc missing M10K packing (84% blocks / 53% bits) finding"
pass "phase3-decode.md corrected dark-silicon + probe framing"

# --- 6) Red-before-green: stripping scaffolding must fail --------------------
TMP="$ROOT/.agent-work/w-fit-1/rb_g_product_no_stub_$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
cp "$SP" "$TMP/stream_path.sv"
# Remove the macro guard markers only in the copy and re-run check #3 logic
sed -i 's/PRODUCT_NO_STUB/PRODUCT_NO_STUB_GONE/g' "$TMP/stream_path.sv"
if python3 - "$TMP/stream_path.sv" <<'PY' 2>/dev/null
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="ignore")
m = re.search(r"`ifndef\s+PRODUCT_NO_STUB\b([\s\S]*?)`else([\s\S]*?)`endif", text)
sys.exit(0 if m else 1)
PY
then
  fail "red-before-green: expected scaffolding check to FAIL after strip"
fi
pass "red-before-green: scaffolding absence fails"

echo "PASS test_product_no_stub_dark_silicon"
exit 0
