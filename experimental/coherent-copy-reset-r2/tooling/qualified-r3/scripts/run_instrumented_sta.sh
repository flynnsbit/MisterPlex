#!/bin/sh
set -eu
work=$1
reporter=$work/reporter
out=$work/output
for entry in "$out"/* "$out"/.[!.]* "$out"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
        echo "REFUSED: instrumented timing destination is not empty" >&2
        exit 1
    fi
done
sdk_image=$(cat "$reporter/sdk-image.id") || exit 1
cp output_files/Plex.sta.rpt "$out/Plex.sta.rpt"
cp output_files/Plex.sta.rpt "$out/Plex.compile-produced.sta.rpt"
cp output_files/Plex.fit.rpt "$out/Plex.fit.rpt"
cp output_files/Plex.map.rpt "$out/Plex.map.rpt"
cp output_files/Plex.map.rpt "$out/Plex.compiled-sources.rpt"
sdk_rc=0
python3 "$reporter/quartus_timing_sdk.py" --report "$out/Plex.compiled-sources.rpt" --image-id "$sdk_image" --output "$out/sdk-catalog.json" >"$out/sdk-catalog.log" 2>&1 || sdk_rc=$?
printf '%s\n' "$sdk_rc" >"$out/sdk-catalog.exit"
if [ "$sdk_rc" -ne 0 ]; then cat "$out/sdk-catalog.log"; exit "$sdk_rc"; fi
sha256sum output_files/Plex.rbf >"$out/rbf.before.sha256"
cp output_files/Plex.rbf "$out/Plex.rbf"
report_rc=0
quartus_sta -t "$reporter/timing.tcl" "$out" >"$out/reporter.log" 2>&1 || report_rc=$?
printf '%s\n' "$report_rc" >"$out/reporter.exit"
if [ "$report_rc" -ne 0 ]; then cat "$out/reporter.log"; exit "$report_rc"; fi
identity=$(cat "$reporter/observation.id") || exit 1
completion=$(cat "$out/observer.complete") || exit 1
if [ "$completion" != "misterplex.timing-observer.v2:$identity" ]; then
    echo "REFUSED: timing observation did not complete" >&2
    exit 1
fi
diagnostic_rc=0
grep -Ei '^[[:space:]]*(Error([[:space:]]*\([0-9]+\))?[[:space:]]*:|Critical Warning[[:space:]]*\(332008\)[[:space:]]*:|MPX_OBSERVER_FAILURE)|Read_sdc failed' "$out/reporter.log" || diagnostic_rc=$?
if [ "$diagnostic_rc" -eq 0 ]; then
    echo "REFUSED: failed/unreadable timing observation diagnostics" >&2
    exit 1
elif [ "$diagnostic_rc" -ne 1 ]; then
    echo "REFUSED: diagnostic grep failed" >&2
    exit "$diagnostic_rc"
fi
sha256sum output_files/Plex.rbf >"$out/rbf.after.sha256"
if ! cmp -s "$out/rbf.before.sha256" "$out/rbf.after.sha256"; then
    echo "REFUSED: timing reporter changed Plex.rbf" >&2
    exit 1
fi
