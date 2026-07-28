#!/usr/bin/env bash
# Offline red/green/leak proof for the secret-safe live PMS gate wrapper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/run_pms_baseline_live_gate.sh"
WORK="$ROOT/build/pms-baseline-live-gate-test"
mkdir -p "$WORK"

make -C "$ROOT" "$ROOT/build/pms_baseline_probe" >/dev/null
"$ROOT/tests/unit/test_pms_baseline_gate.sh" >/dev/null

set +e
env -u PLEX_BASE -u PLEX_TOKEN -u MISTERPLEX_BASELINE_KEY -u PLEX_KEY \
  "$SCRIPT" >"$WORK/no_token.log" 2>&1
no_token_rc=$?
set -e
if [[ "$no_token_rc" -ne 77 ]] || ! grep -q "SKIP-NOT-PASS pms_baseline_live_gate" "$WORK/no_token.log"; then
  echo "FAIL: no-token path rc=$no_token_rc, want SKIP-NOT-PASS rc=77" >&2
  cat "$WORK/no_token.log" >&2
  exit 1
fi

MISTERPLEX_BASELINE_ANNEXB="$ROOT/build/pms-baseline-gate/green.264" \
  "$SCRIPT" >"$WORK/green.log" 2>&1
grep -q "test_pms_baseline_profile: OK delivered Baseline/CAVLC/ref=1/no-B 624x480 stream" "$WORK/green.log"

set +e
MISTERPLEX_BASELINE_ANNEXB="$ROOT/build/pms-baseline-gate/bad_all.264" \
  "$SCRIPT" >"$WORK/bad_all.log" 2>&1
bad_rc=$?
set -e
if [[ "$bad_rc" -eq 0 ]]; then
  echo "FAIL: bad_all non-conforming stream unexpectedly passed" >&2
  cat "$WORK/bad_all.log" >&2
  exit 1
fi
grep -q "profile_idc=100, expected 66" "$WORK/bad_all.log"
grep -q "entropy_cabac=1, expected 0" "$WORK/bad_all.log"
grep -q "max_num_ref_frames=4, expected 1" "$WORK/bad_all.log"
grep -q "b_slices=1, expected 0" "$WORK/bad_all.log"

fake_token="MISTERPLEX_SYNTHETIC_LEAK_SENTINEL"
set +e
PLEX_TOKEN="$fake_token" "$SCRIPT" >"$WORK/exported_token_refuse.log" 2>&1
refuse_rc=$?
set -e
if [[ "$refuse_rc" -ne 2 ]] || ! grep -q "PLEX_TOKEN is already exported" "$WORK/exported_token_refuse.log"; then
  echo "FAIL: exported-token refusal rc=$refuse_rc, want rc=2" >&2
  cat "$WORK/exported_token_refuse.log" >&2
  exit 1
fi
if grep -q "$fake_token" "$WORK/exported_token_refuse.log"; then
  echo "FAIL: token leak sentinel appeared in live gate refusal log" >&2
  exit 1
fi

python3 - "$SCRIPT" "$WORK/liveish_prompt.log" <<'PY'
import os
import pty
import sys

script, log_path = sys.argv[1:3]
token = "MISTERPLEX_SYNTHETIC_PTY_TOKEN"
env = os.environ.copy()
for key in ("PLEX_TOKEN", "MISTERPLEX_BASELINE_ANNEXB"):
    env.pop(key, None)
env["PLEX_BASE"] = "http://127.0.0.1:9"
env["MISTERPLEX_BASELINE_KEY"] = "/library/metadata/1"
env["MISTERPLEX_BASELINE_SECONDS"] = "4"

pid, fd = pty.fork()
if pid == 0:
    os.execve(script, [script], env)

out = bytearray()
sent = False
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out.extend(chunk)
    if (not sent) and b"Plex token" in out:
        os.write(fd, (token + "\n").encode())
        sent = True

_, status = os.waitpid(pid, 0)
with open(log_path, "wb") as f:
    f.write(out)
if token.encode() in out:
    raise SystemExit("token leak sentinel appeared in live-ish prompt log")
if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
    raise SystemExit("live-ish unreachable PMS unexpectedly passed")
PY

echo "test_pms_baseline_live_gate: OK skip rc=77, green Annex-B, red bad_all, exported-token refusal, no token leak"
