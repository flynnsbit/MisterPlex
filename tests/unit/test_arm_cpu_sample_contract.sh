#!/usr/bin/env bash
# Contract: arm_cpu_sample stamps artifact pair fields, NO-DATA not 0, derivations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/.agent-work/w-cpu-1/cpu_contract.json"
mkdir -p "$(dirname "$OUT")"
# Fake RBF + log for host self-test
FAKE_RBF="$ROOT/.agent-work/w-cpu-1/fake_plex.rbf"
FAKE_LOG="$ROOT/.agent-work/w-cpu-1/fake_daemon.log"
printf 'fake-rbf-bytes-for-md5\n' >"$FAKE_RBF"
printf 'media: decode=624x480 decode_src=caller_supplied measured_delivery=624x480 delivery_verified=1\n' >"$FAKE_LOG"
EXPECT_RBF_MD5=$(md5sum "$FAKE_RBF" | awk '{print $1}')

python3 "$ROOT/tools/arm_cpu_sample.py" --seconds 1 --label contract \
  --rbf "$FAKE_RBF" --log "$FAKE_LOG" --decode-src caller_supplied \
  -o "$OUT"
echo "sample_true_rc=$?"

python3 - <<PY
import json,sys
p="$OUT"
d=json.load(open(p))
fail=0
def need(cond,msg):
    global fail
    if not cond:
        print("FAIL",msg); fail=1
    else:
        print("OK",msg)

need(d.get("rbf_md5")=="$EXPECT_RBF_MD5", f"rbf_md5 stamped got={d.get('rbf_md5')}")
need(d.get("decode_src")=="caller_supplied", f"decode_src={d.get('decode_src')}")
need(d.get("method") and "dticks" in d["method"], "method has dticks derivation")
need("derivations" in d and "SYSTEM_BUSY" in d["derivations"], "derivations.SYSTEM_BUSY")
need("sampler_self_pct_onecpu" in d, "sampler_self present (may be 0.0 measured)")
# Missing MiSTer on host must be null not 0
need(d.get("MiSTer_pct_onecpu") is None, f"MiSTer absence=null got={d.get('MiSTer_pct_onecpu')}")
need(d.get("capacity_pct_onecpu") and d["capacity_pct_onecpu"]>=100, "capacity CAP=100*ncpu")
need(d.get("tag")=="measured", "tag=measured")
# line contract via re-run stdout checked separately
sys.exit(fail)
PY
echo "contract_py_true_rc=$?"

# busybox script syntax + one shot with fake env
sh -n "$ROOT/tools/arm_cpu_soak.sh"
echo "soak_syntax_true_rc=$?"
RBF_PATH="$FAKE_RBF" DECODE_SRC=caller_supplied LOG="$FAKE_LOG" \
  sh "$ROOT/tools/arm_cpu_soak.sh" 1 | tee "$ROOT/.agent-work/w-cpu-1/soak_contract.out"
echo "soak_run_true_rc=$?"
grep -q "rbf_md5=$EXPECT_RBF_MD5" "$ROOT/.agent-work/w-cpu-1/soak_contract.out"
grep -q "decode_src=caller_supplied" "$ROOT/.agent-work/w-cpu-1/soak_contract.out"
grep -q "sampler_self=" "$ROOT/.agent-work/w-cpu-1/soak_contract.out"
grep -q "method=exe+dticks" "$ROOT/.agent-work/w-cpu-1/soak_contract.out"
# must not invent MiSTer=0.0 on host
if grep -qE 'MiSTer=0(\.0)?' "$ROOT/.agent-work/w-cpu-1/soak_contract.out"; then
  echo "FAIL MiSTer printed as 0" >&2; exit 1
fi
grep -q 'MiSTer=NO-DATA' "$ROOT/.agent-work/w-cpu-1/soak_contract.out"
echo "OK test_arm_cpu_sample_contract"
exit 0
