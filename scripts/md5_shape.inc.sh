# md5_shape.inc.sh — shared shape assert for captured digests.
# Source from gate/deploy scripts. Never fuzzy-trim a contaminated value to pass.
#
# Historic: bash $(...) strips trailing newlines so
#   echo "V2_MD5=$v2_md5"  +  set +e
# printed V2_MD5=<32hex>set +e (parent 2026-07-31). Shape reject catches it.

# assert_md5_shape NAME VALUE
#   empty → return 0 (caller decides NO-DATA vs required)
#   MISSING → return 0
#   exactly 32 lowercase hex → return 0
#   anything else (glue, prefix8, whitespace) → return 1 + FAIL line on stdout
assert_md5_shape() {
  local name="$1" val="$2"
  case "$val" in
    *[[:space:]]*|*+*|*\;*|*'set '*|*'$'*)
      echo "FAIL $name shape got='$val' (probe capture contaminated — not pure md5)"
      return 1
      ;;
  esac
  if [ -z "$val" ] || [ "$val" = "MISSING" ]; then
    return 0
  fi
  if printf '%s' "$val" | grep -Eq '^[0-9a-f]{32}$'; then
    return 0
  fi
  echo "FAIL $name shape got='$val' (want exactly 32 hex chars or MISSING; len=${#val})"
  return 1
}

# require_md5_shape NAME VALUE — empty is also FAIL (required field)
require_md5_shape() {
  local name="$1" val="$2"
  if [ -z "$val" ]; then
    echo "NO-DATA $name empty (not a mismatch — probe returned nothing)"
    return 4
  fi
  assert_md5_shape "$name" "$val"
}
