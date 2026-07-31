#!/usr/bin/env bash
# Mutation-verify scripts/check_core_conf_geometry.sh in both directions.
# Fixtures only — never touches the live device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_core_conf_geometry.sh"
MAP="$ROOT/assets/core_geometry_map.tsv"
WORK="$ROOT/build/core-conf-geometry-gate"
KNOWN_MD5="41adb98c7a630b541091c22ce291be68"
UNKNOWN_MD5="0123456789abcdef0123456789abcdef"

rm -rf "$WORK"
mkdir -p "$WORK/match" "$WORK/mismatch" "$WORK/unknown" "$WORK/absent_log" "$WORK/absent_decode"

chmod +x "$GATE"

# --- fixtures ---
printf '%s\n' "$KNOWN_MD5" >"$WORK/match/core.md5"
cat >"$WORK/match/misterplexd.log" <<'LOG'
** WARNING: connection is not using a post-quantum key exchange algorithm.
misterplexd: MATCH_SOURCE_HZ=off SOURCE_FPS=auto (cadence/OSD path; switchres TODO)
misterplexd: OSD_CONTROL=0
misterplexd: running name=MiSTerPlex id=misterplex-dev port=3005 pms=http://YOUR-PLEX-SERVER:32400 servers=1 decode=320x240 decode_source=default weak=320x240@1000k present=fb0 auto_next=1 subs=off
LOG

printf '%s\n' "$KNOWN_MD5" >"$WORK/mismatch/core.md5"
# The fault that shipped: conf DECODE=624x480 adopted while core is 320x240.
cat >"$WORK/mismatch/misterplexd.log" <<'LOG'
misterplexd: running name=MiSTerPlex id=x port=3005 pms=(unset) servers=0 decode=624x480 weak=640x480@2500k present=fpga auto_next=1 subs=off
LOG

printf '%s\n' "$UNKNOWN_MD5" >"$WORK/unknown/core.md5"
cat >"$WORK/unknown/misterplexd.log" <<'LOG'
misterplexd: running name=MiSTerPlex id=x port=3005 pms=(unset) servers=0 decode=320x240 weak=320x240@1000k present=fb0 auto_next=1 subs=off
LOG

printf '%s\n' "$KNOWN_MD5" >"$WORK/absent_log/core.md5"
# no misterplexd.log

printf '%s\n' "$KNOWN_MD5" >"$WORK/absent_decode/core.md5"
cat >"$WORK/absent_decode/misterplexd.log" <<'LOG'
misterplexd: OSD_CONTROL=0
misterplexd: DDR_MEM_SYNC=1 DDR_MEM_FLUSH=0
# running line never printed (crash before adopt)
LOG

run_case() {
  local label="$1" want_rc="$2" dir="$3"
  local out rc
  set +e
  out=$(FIXTURE_DIR="$dir" CORE_GEOMETRY_MAP="$MAP" "$GATE" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s|^|  |"
  if [[ "$rc" -ne "$want_rc" ]]; then
    echo "FAIL test_core_conf_geometry_gate: $label rc=$rc want=$want_rc" >&2
    exit 1
  fi
  echo "OK $label rc=$rc"
}

echo "=== mutation: PASS matched 320x240 core + adopted decode=320x240 ==="
run_case "match" 0 "$WORK/match"
grep -q "source=adopted-running-line" <<<"$(FIXTURE_DIR="$WORK/match" "$GATE" 2>&1)" || {
  echo "FAIL: gate must state adopted-running-line is source of truth" >&2
  exit 1
}

echo "=== mutation: FAIL known core + adopted decode=624x480 ==="
run_case "mismatch" 1 "$WORK/mismatch"
set +e
mm_out=$(FIXTURE_DIR="$WORK/mismatch" CORE_GEOMETRY_MAP="$MAP" "$GATE" 2>&1)
set -e
grep -q "geometry mismatch" <<<"$mm_out" || {
  echo "FAIL: mismatch must explain geometry mismatch" >&2
  exit 1
}
grep -q "624x480" <<<"$mm_out" || {
  echo "FAIL: mismatch output must quote adopted 624x480" >&2
  exit 1
}

echo "=== mutation: SKIP-NOT-PASS unknown core md5 ==="
run_case "unknown" 77 "$WORK/unknown"
set +e
u_out=$(FIXTURE_DIR="$WORK/unknown" CORE_GEOMETRY_MAP="$MAP" "$GATE" 2>&1)
set -e
grep -q "SKIP-NOT-PASS" <<<"$u_out" || {
  echo "FAIL: unknown core must print SKIP-NOT-PASS" >&2
  exit 1
}

echo "=== mutation: SKIP-NOT-PASS absent adopted log ==="
run_case "absent_log" 77 "$WORK/absent_log"

echo "=== mutation: SKIP-NOT-PASS log without running/decode line ==="
run_case "absent_decode" 77 "$WORK/absent_decode"

# Map must list the known v0.3.0 core — otherwise the PASS case is vacuous.
grep -q "$KNOWN_MD5" "$MAP" || {
  echo "FAIL: assets/core_geometry_map.tsv missing known v0.3.0 md5" >&2
  exit 1
}

# SPI daily + DDR product cores must be mapped (soft-skip is NOT deploy evidence).
SPI_MD5=dfebf2bfd08dd70b473b587dd7e81848
DDR_MD5=c5382bee73cecdee8220b811e529c297
for m in "$SPI_MD5" "$DDR_MD5"; do
  g=$(awk -v m="$m" 'BEGIN{IGNORECASE=1} $1==m {print $2; exit}' "$MAP")
  if [[ "$g" != "320x240" ]]; then
    echo "FAIL: map must list $m → 320x240 (got '${g:-missing}')" >&2
    exit 1
  fi
done
echo "OK map lists SPI dfebf2bf + DDR c5382bee → 320x240"

# Direct PASS on newly mapped cores (not only v0.3.0).
for m in "$SPI_MD5" "$DDR_MD5"; do
  set +e
  mapped_out=$(CORE_MD5="$m" ADOPTED_LOG="$WORK/match/misterplexd.log" "$GATE" 2>&1)
  mapped_rc=$?
  set -e
  if [[ "$mapped_rc" -ne 0 ]]; then
    echo "FAIL mapped core $m with decode=320x240 rc=$mapped_rc" >&2
    printf '%s\n' "$mapped_out" >&2
    exit 1
  fi
  echo "OK mapped core $m PASS rc=0"
done

# RED: mapped SPI/DDR core + wrong adopted decode must FAIL (not skip).
printf '%s\n' "$SPI_MD5" >"$WORK/mismatch/core.md5"
set +e
spi_mm=$(FIXTURE_DIR="$WORK/mismatch" CORE_GEOMETRY_MAP="$MAP" "$GATE" 2>&1)
spi_mm_rc=$?
set -e
if [[ "$spi_mm_rc" -ne 1 ]]; then
  echo "FAIL SPI mapped mismatch want rc=1 got $spi_mm_rc" >&2
  printf '%s\n' "$spi_mm" >&2
  exit 1
fi
echo "OK SPI mapped mismatch rc=1 (red-before-green)"
printf '%s\n' "$DDR_MD5" >"$WORK/mismatch/core.md5"
set +e
ddr_mm=$(FIXTURE_DIR="$WORK/mismatch" CORE_GEOMETRY_MAP="$MAP" "$GATE" 2>&1)
ddr_mm_rc=$?
set -e
if [[ "$ddr_mm_rc" -ne 1 ]]; then
  echo "FAIL DDR mapped mismatch want rc=1 got $ddr_mm_rc" >&2
  printf '%s\n' "$ddr_mm" >&2
  exit 1
fi
echo "OK DDR mapped mismatch rc=1 (red-before-green)"
# restore unknown for cleanliness
printf '%s\n' "$UNKNOWN_MD5" >"$WORK/unknown/core.md5"

# Direct argv form (deploy hooks use this)
set +e
direct_out=$(CORE_MD5="$KNOWN_MD5" ADOPTED_LOG="$WORK/match/misterplexd.log" "$GATE" 2>&1)
direct_rc=$?
set -e
if [[ "$direct_rc" -ne 0 ]]; then
  echo "FAIL direct env form rc=$direct_rc" >&2
  printf '%s\n' "$direct_out" >&2
  exit 1
fi
echo "OK direct env form rc=0"

# Prove gate refuses to treat conf file as truth even if present beside log
printf 'DECODE=624x480\nPRESENT=fpga\nSTREAM=1\n' >"$WORK/match/misterplex.conf"
set +e
conf_lie=$(FIXTURE_DIR="$WORK/match" "$GATE" 2>&1)
conf_rc=$?
set -e
if [[ "$conf_rc" -ne 0 ]]; then
  echo "FAIL: conf lie must not affect gate when adopted log says 320x240 (rc=$conf_rc)" >&2
  printf '%s\n' "$conf_lie" >&2
  exit 1
fi
echo "OK conf-file lie ignored (adopted log wins) rc=0"

echo "test_core_conf_geometry_gate: OK (match=0 mismatch=1 unknown/absent=77; adopted-log SoT)"
exit 0
