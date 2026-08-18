# Source-only POSIX helpers: live Plex.rbf md5 → daemon bin + glass tag.
# Used by scripts/misterplex_core_watch.sh and tests/unit/test_core_watch_pairs.sh.
# Do not exec this file.

# Known glass tags (3rd pairs column): true480 | l4 | crt240p15 | crt480i
# Aliases: L4/720p24 → l4; 480p → true480. Missing/unknown → true480.

rbf_pair_default_glass() {
  printf '%s\n' true480
}

rbf_pair_normalize_glass() {
  t=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | tr -d '\r\n\t ')
  case "$t" in
    true480|480p) printf '%s\n' true480 ;;
    l4|720p24) printf '%s\n' l4 ;;
    crt240p15) printf '%s\n' crt240p15 ;;
    crt480i) printf '%s\n' crt480i ;;
    *) printf '%s\n' true480 ;;
  esac
}

# Strip path / .rbf like Main's CORENAME / RBFNAME, then match Plex / Plex_* / Plex-*.
# Plex_240p15, Plex_480i, Plex_15k, Plex_720p24 are Plex cores.
rbf_pair_is_plex_name() {
  name=$(printf '%s' "${1:-}" | tr -d '\000\r\n')
  name=$(printf '%s' "$name" | sed 's|.*/||; s|\.rbf$||; s|\.RBF$||')
  case "$name" in
    [Pp]lex|[Pp]lex_*|[Pp]lex-* ) return 0 ;;
    *) return 1 ;;
  esac
}

rbf_pair_write_glass() {
  dest=${2:-/tmp/misterplex-live-glass}
  printf '%s\n' "${1:-true480}" >"$dest"
}

# rbf_pair_lookup <pairs_file> <md5> <default_bin>
# Sets: rbf_pair_bin, rbf_pair_glass, rbf_pair_hit (1 if md5 row found).
# Glass comes from column 3. Missing/unknown tag → true480, except the
# shipping 720p24 md5 on a 2-col line still pins l4 (v0.7.0 field pairs).
rbf_pair_lookup() {
  pairs=${1:-}
  sum=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z' | tr -d '\r\n\t ')
  default_bin=${3:-}
  rbf_pair_bin=$default_bin
  rbf_pair_glass=true480
  rbf_pair_hit=0
  [ -n "$sum" ] || return 0
  [ -f "$pairs" ] || return 0
  bin=$(awk -v s="$sum" '$1==s && $1 !~ /^#/ {print $2; exit}' "$pairs" | tr -d '\r')
  tag=$(awk -v s="$sum" '$1==s && $1 !~ /^#/ {print $3; exit}' "$pairs" | tr -d '\r')
  if [ -z "${bin:-}" ]; then
    return 0
  fi
  rbf_pair_hit=1
  rbf_pair_bin=$bin
  if [ -n "${tag:-}" ]; then
    rbf_pair_glass=$(rbf_pair_normalize_glass "$tag")
  elif [ "$sum" = "03f1b95ac67a568f24193234ea8cb072" ]; then
    rbf_pair_glass=l4
  else
    rbf_pair_glass=true480
  fi
}
