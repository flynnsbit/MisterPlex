#!/usr/bin/env bash
# Host gate: parent template decoder + display-skip detector (not OCR).
# RED/GREEN + LOO inside tools/glass_template_skip.py --self-test.
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
echo "GLASS_TEMPLATE_SKIP_GATE_OK"
exit 0
