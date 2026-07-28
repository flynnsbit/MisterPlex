#!/usr/bin/env bash
# Build-identity gate: the CONF_STR V entry (the only build id a user can read
# off the MiSTer OSD sidebar) must be derived from the fitted sources, must not
# be a hand-maintained constant, and must be traceable back from a deployed RBF.
#
# Every green below ships with the red that proves it can fail.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/scripts/gen_build_stamp.py"
PROV="$ROOT/scripts/rbf_provenance.py"
TCL="$ROOT/fpga/Plex_MiSTer/sys/build_id.tcl"
TOP="$ROOT/fpga/Plex_MiSTer/Plex.sv"
FIT="$ROOT/scripts/build_rbf_remote.sh"
WORK="$ROOT/build/build_identity_gate"
FAILED=0

echo "Scope: build-identity contract for the OSD sidebar V entry. Checks that BUILD_ID is generated (never a checked-in constant), that its SRC half is a digest of the exact fit inputs so it cannot silently go stale, that a missing git identity is refused by the fit path, and that an RBF md5 resolves to a BUILD_ID through the provenance ledger. It does NOT execute the Quartus Tcl (no tclsh in this lab), does not run a fit, and does not prove the string is rendered on screen — tests/hw/test_osd_build_identity.sh owns the pixel proof."

fail() {
    echo "FAIL build-identity: $*"
    FAILED=1
}
ok() { echo "OK $*"; }

rm -rf "$WORK"
mkdir -p "$WORK/proj/rtl" "$WORK/proj/output_files"

# --- 1. BUILD_ID must not be a checked-in constant -------------------------
if grep -RIn --include='*.sv' --include='*.v' --include='*.svh' --include='*.qsf' \
        -E '^[^/]*`define[[:space:]]+BUILD_ID' "$ROOT/fpga" >/dev/null 2>&1; then
    fail "BUILD_ID is defined by a tracked source file; it must only come from the generated build_id.v"
else
    ok "BUILD_ID has no checked-in \`define (generated only)"
fi

if [ -f "$ROOT/fpga/Plex_MiSTer/build_id.v" ] &&
   git -C "$ROOT" ls-files --error-unmatch fpga/Plex_MiSTer/build_id.v >/dev/null 2>&1; then
    fail "build_id.v is tracked in git; a committed identity outlives the source it claims"
else
    ok "build_id.v is not tracked in git"
fi

if git -C "$ROOT" ls-files --error-unmatch fpga/Plex_MiSTer/build_id_stamp.txt >/dev/null 2>&1; then
    fail "build_id_stamp.txt is tracked in git; the stamp must be regenerated per fit"
else
    ok "build_id_stamp.txt is not tracked in git"
fi

grep -q 'V,v",`BUILD_ID' "$TOP" \
    && ok "CONF_STR V entry uses \`BUILD_ID" \
    || fail "CONF_STR V entry does not use \`BUILD_ID ($TOP)"
grep -q '`include "build_id.v"' "$TOP" \
    && ok "Plex.sv includes the generated build_id.v" \
    || fail "Plex.sv does not include build_id.v"
grep -q 'build_id_stamp.txt' "$TCL" \
    && ok "build_id.tcl consumes build_id_stamp.txt" \
    || fail "build_id.tcl ignores build_id_stamp.txt (remote fits would stamp nogit)"
grep -q 'gen_build_stamp.py' "$FIT" \
    && ok "remote fit generates the stamp before rsync" \
    || fail "build_rbf_remote.sh does not generate the build stamp"
grep -q 'nogit' "$FIT" \
    && ok "remote fit refuses a nogit BUILD_ID" \
    || fail "build_rbf_remote.sh does not refuse a nogit BUILD_ID"

# --- 2. SRC must track the fit inputs --------------------------------------
cp "$ROOT/fpga/Plex_MiSTer/Plex.qsf" "$WORK/proj/Plex.qsf"
printf 'module a; endmodule\n' >"$WORK/proj/rtl/a.sv"
printf 'stale output\n' >"$WORK/proj/output_files/Plex.rbf"

src_of() {
    python3 "$GEN" --project "$WORK/proj" --repo "$ROOT" --print-only --json 2>/dev/null |
        sed -n 's/.*"SRC": "\([0-9a-f]*\)".*/\1/p'
}

SRC_A="$(src_of)"
[ -n "$SRC_A" ] || fail "could not compute SRC for the synthetic project"

printf 'stale output changed\n' >"$WORK/proj/output_files/Plex.rbf"
SRC_OUT="$(src_of)"
if [ "$SRC_A" = "$SRC_OUT" ]; then
    ok "SRC ignores Quartus outputs (output_files/) — $SRC_A"
else
    fail "SRC changed when only a Quartus output changed ($SRC_A -> $SRC_OUT)"
fi

printf 'module a; wire x; endmodule\n' >"$WORK/proj/rtl/a.sv"
SRC_B="$(src_of)"
if [ "$SRC_A" != "$SRC_B" ]; then
    ok "RED OK: editing a fitted RTL file changes SRC ($SRC_A -> $SRC_B)"
else
    fail "SRC did not change after editing a fitted RTL file; the id would lie about the bitstream"
fi

printf 'module a; endmodule\n' >"$WORK/proj/rtl/a.sv"
SRC_C="$(src_of)"
if [ "$SRC_A" = "$SRC_C" ]; then
    ok "SRC is reproducible for identical inputs"
else
    fail "SRC is not reproducible for identical inputs ($SRC_A vs $SRC_C)"
fi

# --- 3. a missing git identity must be refused, not silently stamped -------
GITLESS="$WORK/gitless"
mkdir -p "$GITLESS"
OUT="$(python3 "$GEN" --project "$WORK/proj" --repo "$GITLESS" --print-only --require-git 2>&1)"
RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'git-identity-unavailable'; then
    ok "RED OK: --require-git rejects a tree with no git identity (rc=$RC)"
else
    fail "--require-git accepted a tree with no git identity (rc=$RC): $OUT"
fi

OUT="$(python3 "$GEN" --project "$WORK/proj" --repo "$GITLESS" --print-only 2>&1)"
if printf '%s' "$OUT" | grep -q 'git=nogit'; then
    ok "without --require-git the fallback is visibly 'nogit' (never a fake commit)"
else
    fail "fallback identity is not reported as nogit: $OUT"
fi

# --- 4. provenance ledger round trip ---------------------------------------
LEDGER="$WORK/ledger.jsonl"
RBF="$WORK/fake.rbf"
head -c 4096 /dev/urandom >"$RBF"
MD5="$(md5sum "$RBF" | awk '{print $1}')"

python3 "$PROV" --ledger "$LEDGER" record --rbf "$RBF" --build-id "260728-deadbeef-abc123" \
    --git deadbeef --slot testslot >"$WORK/record.log" 2>&1
[ $? -eq 0 ] && ok "provenance record wrote an entry" || fail "provenance record failed: $(cat "$WORK/record.log")"

python3 "$PROV" --ledger "$LEDGER" resolve --rbf "$RBF" >"$WORK/resolve.log" 2>&1
if [ $? -eq 0 ] && grep -q "build_id=260728-deadbeef-abc123" "$WORK/resolve.log"; then
    ok "provenance resolve maps an RBF md5 back to its BUILD_ID"
else
    fail "provenance resolve did not return the recorded BUILD_ID: $(cat "$WORK/resolve.log")"
fi

python3 "$PROV" --ledger "$LEDGER" resolve --md5 00000000000000000000000000000000 \
    >"$WORK/resolve_unknown.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ] && grep -q 'untraceable-bitstream' "$WORK/resolve_unknown.log"; then
    ok "RED OK: an unknown RBF md5 is an untraceable-bitstream FAIL (rc=$RC)"
else
    fail "unknown RBF md5 did not fail (rc=$RC)"
fi

python3 "$PROV" --ledger "$LEDGER" resolve --rbf "$RBF" --expect-build-id wrong-id \
    >"$WORK/resolve_mismatch.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ] && grep -q 'build-id-mismatch' "$WORK/resolve_mismatch.log"; then
    ok "RED OK: a BUILD_ID mismatch fails (rc=$RC)"
else
    fail "BUILD_ID mismatch did not fail (rc=$RC)"
fi

printf 'flip one byte\n' >>"$RBF"
python3 "$PROV" --ledger "$LEDGER" resolve --rbf "$RBF" >"$WORK/resolve_edited.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    ok "RED OK: editing the RBF makes it untraceable again (rc=$RC)"
else
    fail "an edited RBF still resolved (rc=$RC)"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "BUILD_IDENTITY_RESULT=PASS"
    exit 0
fi
echo "BUILD_IDENTITY_RESULT=FAIL"
exit 1
