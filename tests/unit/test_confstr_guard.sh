#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/build/confstr-guard"
mkdir -p "$WORK"

BAD="$WORK/Plex.bad-confstr.sv"
python3 - "$ROOT/fpga/Plex_MiSTer/Plex.sv" "$BAD" <<'PY'
from pathlib import Path
src = Path(__import__("sys").argv[1])
dst = Path(__import__("sys").argv[2])
text = src.read_text()
# Corrupt F1 extension field (must stay 3-char chunks: mpx).
bad = text.replace(
    '"F1,mpx,Play local (daemon);"',
    '"F1,mp4,Play local (daemon);"',
    1,
)
if bad == text:
    # Fallback: inject comma garble
    bad = text.replace(
        '"F1,mpx,Play local (daemon);"',
        '"F1,m,p,x,Play local (daemon);"',
        1,
    )
if bad == text:
    raise SystemExit("failed to inject malformed CONF_STR")
dst.write_text(bad)
PY

if python3 "$ROOT/scripts/check_confstr_guard.py" "$BAD" >"$WORK/red.out" 2>"$WORK/red.err"; then
  echo "FAIL: malformed CONF_STR unexpectedly passed" >&2
  exit 1
fi
# Either 3-char chunk error (mp4) or field-count error
if ! grep -Eqi "3-character|malformed extension|mpx" "$WORK/red.err"; then
  echo "FAIL: malformed CONF_STR error did not explain extension guard" >&2
  cat "$WORK/red.err" >&2
  exit 1
fi
echo "RED OK: malformed CONF_STR rejected"
cat "$WORK/red.err"

python3 "$ROOT/scripts/check_confstr_guard.py" "$ROOT/fpga/Plex_MiSTer/Plex.sv"
echo "GREEN OK: checked-in CONF_STR passed"
