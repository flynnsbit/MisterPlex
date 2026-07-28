#!/usr/bin/env bash
# Regression: `git ls-files` emits an unmerged path once per stage (1/2/3).
#
# Observed live on w-decode-o5 while merging origin/w-cast-play-state: the
# reachability checker parsed fpga/Plex_MiSTer/rtl/h264_decode_core.sv twice and
# reported
#     RTL_MODULE_INSTANTIATION_FAIL: duplicate module h264_decode_core:
#       fpga/Plex_MiSTer/rtl/h264_decode_core.sv and fpga/Plex_MiSTer/rtl/h264_decode_core.sv
# naming the SAME path on both sides. That is a false red: there is exactly one
# `module h264_decode_core` in the tree. A false red on the trunk proof is not
# harmless -- it is the one measurement the fleet is now required to cite, so a
# checker that cannot survive a mid-merge tree will be worked around instead.
#
# This test recreates the condition deterministically with a `git` shim that
# duplicates `ls-files` output, so it does not depend on the tree being mid-merge.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root" || exit 1

work="$root/build/unmerged-paths-proof"
mkdir -p "$work/bin" || exit 1

# Shim: pass everything through to the real git, but emit each `ls-files` line
# three times -- exactly what an unresolved merge looks like to a caller.
real_git="$(command -v git)"
if [ -z "$real_git" ]; then
    echo "SKIP: git not found"
    exit 77
fi

cat > "$work/bin/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "ls-files" ]; then
        "$real_git" "\$@" | awk '{ print; print; print }'
        exit \${PIPESTATUS[0]}
    fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$work/bin/git" || exit 1

fail=0

# Control: the shim really does duplicate.
n=$(PATH="$work/bin:$PATH" git ls-files -- fpga/Plex_MiSTer/rtl 2>/dev/null | wc -l)
m=$("$real_git" ls-files -- fpga/Plex_MiSTer/rtl 2>/dev/null | wc -l)
if [ "$n" -le "$m" ]; then
    echo "FAIL control: shim did not duplicate ls-files output ($n vs $m)"
    fail=1
else
    echo "ok control: shim duplicates ls-files ($m -> $n)"
fi

# The trunk proof must survive a tree whose index has unmerged entries.
out="$work/trunk.txt"
PATH="$work/bin:$PATH" python3 scripts/check_rtl_module_instantiations.py \
    --root emu --require h264_decode_core > "$out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: trunk proof rc=$rc with duplicated ls-files output (false red)"
    sed -n '1,6p' "$out"
    fail=1
else
    echo "ok: trunk proof rc=0 despite duplicated ls-files output"
fi

if grep -q "duplicate module" "$out" 2>/dev/null; then
    echo "FAIL: checker reported a phantom duplicate module"
    fail=1
fi

# A genuine duplicate must still be caught: same module name in two files.
dup="fpga/Plex_MiSTer/rtl/zz_dup_probe_h264_decode_core.sv"
printf 'module h264_decode_core;\nendmodule\n' > "$root/$dup" || exit 1
"$real_git" add -N "$dup" >/dev/null 2>&1
python3 scripts/check_rtl_module_instantiations.py --root emu \
    --require h264_decode_core > "$work/dup.txt" 2>&1
drc=$?
"$real_git" rm -q --cached --force "$dup" >/dev/null 2>&1
mv -f "$root/$dup" "$work/zz_dup_probe.sv.bak" 2>/dev/null

if [ "$drc" -eq 0 ]; then
    echo "FAIL red-proof: a real duplicate module across two files passed (rc=0)"
    fail=1
elif grep -q "duplicate module h264_decode_core" "$work/dup.txt"; then
    echo "ok red-proof: a real cross-file duplicate is still rejected rc=$drc"
else
    echo "FAIL red-proof: rejected rc=$drc but not for the duplicate reason"
    sed -n '1,4p' "$work/dup.txt"
    fail=1
fi

# Restore proof: tree is clean again.
python3 scripts/check_rtl_module_instantiations.py --root emu \
    --require h264_decode_core > "$work/restore.txt" 2>&1
rrc=$?
if [ "$rrc" -ne 0 ]; then
    echo "FAIL restore: trunk proof rc=$rrc after probe removal"
    sed -n '1,4p' "$work/restore.txt"
    fail=1
else
    echo "ok restore: trunk proof rc=0"
fi

if [ "$fail" -ne 0 ]; then
    echo "RTL_UNMERGED_PATH_GUARD_FAIL"
    exit 1
fi
echo "RTL_UNMERGED_PATH_GUARD_OK"
exit 0
