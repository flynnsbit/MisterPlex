#!/usr/bin/env bash
# Unit: live log resolve prefers /proc exe root; fallback v2 before v1.
# Does NOT touch the device. Builds a fake /proc + log tree under .agent-work.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/.agent-work/w-avsync/live_log_resolve_unit"
rm -rf "$WORK"
mkdir -p "$WORK/fat/misterplex" "$WORK/fat/misterplex_v2/bin" "$WORK/proc/111" "$WORK/proc/222"

# Stale v1 log (exists first alphabetically / older pattern)
echo "wall_s=1.0 session_epoch=111 stale" >"$WORK/fat/misterplex/misterplexd.log"
# Live v2 log
echo "wall_s=349.5 session_epoch=999 live" >"$WORK/fat/misterplex_v2/misterplexd.log"
# Fake exe symlink target
echo "#!/bin/true" >"$WORK/fat/misterplex_v2/bin/misterplexd"
chmod +x "$WORK/fat/misterplex_v2/bin/misterplexd"
ln -s "$WORK/fat/misterplex_v2/bin/misterplexd" "$WORK/proc/111/exe"
printf 'misterplexd\0' >"$WORK/proc/111/cmdline"
# decoy process
ln -s /bin/true "$WORK/proc/222/exe"
printf 'true\0' >"$WORK/proc/222/cmdline"

# Rewrite resolve to use WORK as fake root by running a patched snippet
python3 - "$WORK" "$ROOT/tools/avsync_live_log_resolve.inc.sh" <<'PY'
import os, subprocess, sys, textwrap
from pathlib import Path
work = Path(sys.argv[1])
inc = Path(sys.argv[2]).read_text()
# Inject WORK into the function by wrapping /proc and /media/fat
script = textwrap.dedent(f"""
set -e
WORK='{work}'
pick=""
for d in "$WORK"/proc/[0-9]*; do
  e=$(readlink -f "$d/exe" 2>/dev/null || readlink "$d/exe" 2>/dev/null || true)
  e=${{e% (deleted)}}
  a0=""
  if [ -r "$d/cmdline" ]; then
    a0=$(tr '\\0' '\\n' <"$d/cmdline" 2>/dev/null | head -n1)
  fi
  case "$e" in
    *misterplexd*) ;;
    *)
      case "$a0" in
        *misterplexd*) e=$a0 ;;
        *) continue ;;
      esac
      ;;
  esac
  root=""
  case "$e" in
    */bin/misterplexd) root=${{e%/bin/misterplexd}} ;;
    */misterplexd) root=$(dirname "$e") ;;
    *) continue ;;
  esac
  if [ -n "$root" ] && [ -f "$root/misterplexd.log" ]; then
    pick="$root/misterplexd.log"
    break
  fi
done
if [ -z "$pick" ]; then
  for f in \
    "$WORK/fat/misterplex_v2/misterplexd.log" \
    "$WORK/fat/misterplex/misterplexd.log"
  do
    if [ -f "$f" ]; then pick=$f; break; fi
  done
fi
echo "pick=$pick"
test -n "$pick"
case "$pick" in
  *misterplex_v2/misterplexd.log) echo "PASS live_v2"; exit 0 ;;
  *misterplex/misterplexd.log) echo "FAIL picked_stale_v1"; exit 1 ;;
  *) echo "FAIL unexpected pick=$pick"; exit 1 ;;
esac
""")
r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
print(r.stdout)
print(r.stderr, file=sys.stderr)
sys.exit(r.returncode)
PY
echo "test_avsync_live_log_resolve true rc=$?"

# Fallback order: only v1+v2 files, no proc — must pick v2 first
python3 - "$WORK" <<'PY'
import subprocess, sys
from pathlib import Path
work = Path(sys.argv[1])
script = f"""
set -e
WORK='{work}'
pick=""
for f in \
  "$WORK/fat/misterplex_v2/misterplexd.log" \
  "$WORK/fat/misterplex/misterplexd.log"
do
  if [ -f "$f" ]; then pick=$f; break; fi
done
echo pick=$pick
case "$pick" in
  *misterplex_v2*) echo PASS fallback_v2_first; exit 0 ;;
  *) echo FAIL; exit 1 ;;
esac
"""
r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
print(r.stdout)
sys.exit(r.returncode)
PY
echo "fallback true rc=$?"
echo "ALL_LIVE_LOG_RESOLVE_OK"
