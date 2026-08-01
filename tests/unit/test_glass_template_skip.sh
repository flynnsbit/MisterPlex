#!/usr/bin/env bash
# Host gate: template decoder + completeness skip detector (F1–F4).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
python3 tools/glass_template_skip.py --self-test
rc=$?
echo "true rc=$rc"
if [[ "$rc" -ne 0 ]]; then
  echo "GLASS_TEMPLATE_SKIP_GATE_FAIL"
  exit "$rc"
fi
# Banked p60 acceptance when present (no device)
if [[ -d /tmp/p60/png && -f /tmp/p60/T60.pkl && -f /tmp/p60/pts.csv ]]; then
  python3 tools/glass_template_skip.py --p60-acceptance
  rc2=$?
  echo "p60 true rc=$rc2"
  if [[ "$rc2" -ne 0 ]]; then
    echo "GLASS_TEMPLATE_SKIP_P60_FAIL"
    exit "$rc2"
  fi
fi
echo "GLASS_TEMPLATE_SKIP_GATE_OK"
exit 0
