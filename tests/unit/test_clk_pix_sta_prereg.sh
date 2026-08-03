#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$ROOT/scripts/check_clk_pix_sta_prereg.py" --root "$ROOT"
echo "PASS test_clk_pix_sta_prereg"
exit 0
