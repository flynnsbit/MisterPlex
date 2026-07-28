#!/usr/bin/env bash
# Permanent regression cases for the four gate defects w-audit demonstrated.
#
# w-audit (gpt-5.5) proved that source-level reachability checking has both
# false-reachable and false-unreachable blind spots.  Two of the four defects
# are things the decode-core seam gate is the right place to catch, because
# both are ways for the product decoder to be "proven present" while being
# absent from the actual design:
#
#   M1  instantiation inside a disabled `if (0)` generate  -> not instantiated
#   M3  RTL file tracked in git but absent from files.qip  -> not compiled
#
# This test mutates tracked RTL, asserts the gate goes red, and restores.  It
# fails if any mutation is silently tolerated.  Every green here ships with the
# red that proves it is load bearing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

SP="fpga/Plex_MiSTer/rtl/stream_path.sv"
QIP="fpga/Plex_MiSTer/files.qip"
GATE="scripts/check_decode_core_seam.py"
WORK="build/w-decode-o5/audit-reds"
mkdir -p "$WORK" || exit 1

if [ ! -f "$SP" ] || [ ! -f "$QIP" ] || [ ! -f "$GATE" ]; then
    echo "FAIL decode-core seam audit reds: missing $SP, $QIP or $GATE" >&2
    exit 1
fi

# House rule, mechanized: never edit sources under a live compile.  This test
# deliberately mutates tracked RTL, so if a Quartus fit is reading THIS tree the
# mutation would corrupt the fit.  Refuse loudly (rc=1) rather than skip -- a
# skip is not a pass, and a silent skip here would hide a corrupted fit.
for _pid_dir in /proc/[0-9]*; do
    _exe="$(readlink "$_pid_dir/exe" 2>/dev/null)" || continue
    case "$_exe" in
        *quartus*) ;;
        *) continue ;;
    esac
    _cwd="$(readlink "$_pid_dir/cwd" 2>/dev/null)" || continue
    if [ "$_cwd" = "$ROOT" ]; then
        echo "FAIL decode-core seam audit reds: a Quartus fit is running in $ROOT;" >&2
        echo "  this test mutates tracked RTL and would corrupt that fit. Refusing." >&2
        exit 1
    fi
done

cp "$SP" "$WORK/stream_path.orig" || exit 1
cp "$QIP" "$WORK/files.qip.orig" || exit 1

restore() {
    cp "$WORK/stream_path.orig" "$SP"
    cp "$WORK/files.qip.orig" "$QIP"
}
trap restore EXIT INT TERM

fails=0
checks=0

# Never read an exit code through a pipe: redirect, then read $? directly.
run_gate() {
    python3 "$GATE" >"$WORK/gate.log" 2>&1
    echo $?
}

expect() {
    local label="$1" want_rc="$2" want_msg="$3"
    local rc
    rc="$(run_gate)"
    checks=$((checks + 1))
    if [ "$rc" != "$want_rc" ]; then
        echo "FAIL decode-core seam audit reds: $label rc=$rc want=$want_rc" >&2
        sed -n '1,6p' "$WORK/gate.log" >&2
        fails=$((fails + 1))
        return
    fi
    if [ -n "$want_msg" ] && ! grep -qF -- "$want_msg" "$WORK/gate.log"; then
        echo "FAIL decode-core seam audit reds: $label rc ok but missing message: $want_msg" >&2
        sed -n '1,6p' "$WORK/gate.log" >&2
        fails=$((fails + 1))
        return
    fi
    if [ -n "${4:-}" ]; then
        python3 "$ROOT/tests/unit/expected_red.py" "$4" "$rc" \
            <"$WORK/gate.log" >"$WORK/manifest.log" 2>&1
        local mrc=$?
        if [ "$mrc" -ne 0 ]; then
            echo "FAIL decode-core seam audit reds: $label not machine-checked" >&2
            cat "$WORK/manifest.log" >&2
            fails=$((fails + 1))
            return
        fi
        cat "$WORK/manifest.log"
    fi
    echo "RED OK: $label (rc=$rc)"
}

wrap_core_in_generate() {
    COND="$1" python3 - "$SP" <<'PY'
import os, sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
anchor = "h264_decode_core #("
i = text.index(anchor)
line_start = text.rfind("\n", 0, i) + 1
text = text[:line_start] + f"generate if ({os.environ['COND']}) begin : gen_audit\n" + text[line_start:]
j = text.index("\n\t);", text.index("product_decode_core"))
path.write_text(text[: j + 4] + "\nend endgenerate\n" + text[j + 4 :], encoding="utf-8")
PY
}

# Baseline: the unmutated tree must be green, or the reds below prove nothing.
expect "baseline unmutated tree is green" 0 "DECODE_CORE_SEAM_OK"

# --- M1: disabled generate -------------------------------------------------
restore
wrap_core_in_generate "0" || exit 1
expect "M1a core inside disabled generate if (0)" 1 "disabled generate" decode_core_dead_generate

restore
wrap_core_in_generate "1'b0" || exit 1
expect "M1b core inside disabled generate if (1'b0)" 1 "disabled generate"

# Control: a live generate must NOT trip the guard, or it is a false positive
# that would block legitimate conditional structure.
restore
wrap_core_in_generate "1" || exit 1
expect "M1-control core inside live generate if (1) stays green" 0 "DECODE_CORE_SEAM_OK"

# --- M1c: the product decode root moves without updating the gate ----------
restore
sed -i 's/) product_decode_core (/) not_the_core (/' "$SP" || exit 1
expect "M1c product decode root renamed away" 1 "does not instantiate"

# --- M3: module tracked in git but absent from the Quartus file list -------
# This is the defect w-audit called the worst: reachability says the module is
# present, but it is not compiled into the design, so it cannot be in the
# bitstream.  h264_dpb.sv is the highest-value case -- it holds the whole
# motion-compensation subsystem, so a single missing qip line deletes all of it.
restore
sed -i '/h264_dpb\.sv/d' "$QIP" || exit 1
expect "M3 core-subtree file dropped from files.qip" 1 "CORE_MODULE_NOT_IN_QIP" decode_core_module_not_in_qip

restore
expect "restored tree is green again" 0 "DECODE_CORE_SEAM_OK"

if [ "$fails" -ne 0 ]; then
    echo "FAIL decode-core seam audit reds: $fails/$checks checks failed" >&2
    exit 1
fi

echo "DECODE_CORE_SEAM_AUDIT_REDS_OK checks=$checks mutations=M1a,M1b,M1c,M3 control=live_generate"
exit 0
