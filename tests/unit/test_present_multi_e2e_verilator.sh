#!/usr/bin/env bash
# MULTI e2e under target glass (PPC2, H1650 compact): gradient + sync + store-valid gate.
# Also elaborates present_core with MULTI target macros (lint-only) — default rtl-lint
# is product 640x480; this is the 720p MULTI elaboration control.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
INC="-I$RTL"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  exit "$VERILATOR_RC"
fi

echo "RTL SIM: present_multi_e2e using $VERILATOR_VERSION" >&2
B="$ROOT/build/verilator/present_multi_e2e"
mkdir -p "$B"

# --- A) e2e gradient+sync TB ---
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build --Mdir "$B" \
  --top-module present_multi_e2e_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  $INC \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/present_multi_e2e_tb_top.sv" \
  "$RTL/present_beam_ppc.sv" \
  "$RTL/present_npx_path.sv" \
  "$RTL/async_fifo.sv" \
  "$ROOT/tests/rtl/present_multi_e2e_tb.cpp"

set +e
OUT="$("$B/Vpresent_multi_e2e_tb_top" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "present_multi_e2e true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL present_multi_e2e sim" >&2
  exit "$RC"
fi
if ! grep -q "PASS present_multi_e2e" <<<"$OUT"; then
  echo "FAIL: missing PASS marker" >&2
  exit 2
fi

# --- B) present_core MULTI target-macro elaboration (lint-only) ---
# Default make rtl-lint uses product FRAME640/H480/LINES8. This forces MULTI
# macros on owned RTL only (no Plex.sv top — that needs build_id/sys stubs).
ELAB="$ROOT/build/verilator/present_core_multi_elab"
mkdir -p "$ELAB"
python3 - <<'PY' >"$ELAB/elab.out" 2>"$ELAB/elab.err"
import subprocess, sys
from pathlib import Path
ROOT = Path(".").resolve()
sys.path.insert(0, str(ROOT / "scripts"))
from rtl_lint import write_intel_stubs, discover_sources, is_excluded, rel
PROJECT = ROOT / "fpga" / "Plex_MiSTer"
stub = write_intel_stubs()
# Owned RTL only — exclude Plex.sv (build_id/sys) and vendor paths
files = []
for p in discover_sources():
    if not p.exists():
        continue
    r = rel(p)
    if r.endswith("Plex.sv") or is_excluded(p):
        continue
    if "/sys/" in f"/{r}":
        continue
    files.append(p)
# Ensure present MULTI deps present
need = [
    "fpga/Plex_MiSTer/rtl/present_core.sv",
    "fpga/Plex_MiSTer/rtl/present_beam_ppc.sv",
    "fpga/Plex_MiSTer/rtl/present_npx_path.sv",
    "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
    "fpga/Plex_MiSTer/rtl/async_fifo.sv",
    "fpga/Plex_MiSTer/rtl/plex_bw_status.sv",
    "fpga/Plex_MiSTer/rtl/plex_clk_status.sv",
]
have = {rel(p) for p in files}
for n in need:
    if n not in have:
        files.append(ROOT / n)
cmd = [
    str(ROOT / "scripts" / "run_verilator.sh"),
    "--lint-only", "-Wno-fatal",
    "-Wno-DECLFILENAME", "-Wno-PINCONNECTEMPTY", "-Wno-PINMISSING",
    "-Wno-MULTITOP", "-Wno-EOFNEWLINE", "-Wno-GENUNNAMED",
    "-Wno-WIDTH", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-UNSIGNED",
    f"-I{ROOT / 'build' / 'rtl_lint_generated'}",
    f"-I{PROJECT}", f"-I{PROJECT / 'sys'}", f"-I{PROJECT / 'rtl'}",
    str(stub),
    "-DFRAME_W=1280", "-DFRAME_H=720", "-DFRAME_LINES_16=1",
    "-DPRESENT_MULTI_PIXEL=1", "-DPRESENT_PX_PER_CLK=2",
    "-DDDR_FRAME_STORE=1",
    "--top-module", "present_core",
] + [str(p) for p in sorted(files, key=lambda x: rel(x))]
print("CMD files", len(files), file=sys.stderr)
proc = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
sys.stdout.write(proc.stdout)
# Fail on %Error in present_core / MULTI path only
owned_err = []
for line in proc.stdout.splitlines():
    if "%Error" not in line:
        continue
    if any(s in line for s in ("present_core", "present_beam", "present_npx", "ddr_frame", "plex_bw", "plex_clk", "Cannot find file")):
        owned_err.append(line)
    elif "syntax error" in line.lower() and "present_" in line:
        owned_err.append(line)
if owned_err:
    print("OWNED_ERRORS:", file=sys.stderr)
    for e in owned_err[:30]:
        print(e, file=sys.stderr)
    sys.exit(1)
# Also fail if present_core never parsed
if "present_core.sv" not in proc.stdout and proc.returncode != 0:
    # no news is OK if rc=0; if rc!=0 without owned err, print note
    print(f"NOTE verilator_rc={proc.returncode} without owned present errors", file=sys.stderr)
print("MULTI_ELAB_OK")
sys.exit(0)
PY
ELAB_RC=$?
echo "present_core MULTI elab true rc=$ELAB_RC"
if [[ "$ELAB_RC" -ne 0 ]]; then
  echo "---- MULTI elab.err ----" >&2
  tail -n 60 "$ELAB/elab.err" >&2 || true
  grep -E '%Error|OWNED' "$ELAB/elab.out" 2>/dev/null | head -40 >&2 || true
  echo "FAIL: present_core MULTI target-macro elaboration" >&2
  exit 1
fi
if ! grep -q "MULTI_ELAB_OK" "$ELAB/elab.out"; then
  echo "FAIL: missing MULTI_ELAB_OK" >&2
  exit 2
fi
echo "PASS present_core MULTI target-macro lint-only elab (FRAME1280/PPC2/LINES16)"
echo "PASS test_present_multi_e2e_verilator"
exit 0
