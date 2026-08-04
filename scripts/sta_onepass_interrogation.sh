#!/usr/bin/env bash
# One-pass STA interrogation after a PRESENT_CLK_PIX_PLL fit.
# Quoted by fpga/Plex_MiSTer/Plex_clk_pix.sdc — must exist and EXECUTE.
#
# Usage:
#   scripts/sta_onepass_interrogation.sh STA_RPT [OUT_DIR]
#
# Emits:
#   - Fmax/setup/hold tables via check_quartus_timing.py (hard empty-row fail)
#   - requires general[3] (clk_pix) in Setup Summary
#   - min Fmax general[3] >= 29.7 MHz (override: CLK_PIX_MIN_FMAX_MHZ)
#   - margin gate vs assets/timing_margin_baseline_720p_compose.json
#   - optional sameclk extract path (2nd arg or OUT_DIR/clk_sys_sameclk_setup.txt stub note)
#
# Exit: 0 PASS, 1 FAIL, 2 usage, 4 missing inputs. Soft-skip is NOT used here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STA_RPT="${1:-}"
OUT_DIR="${2:-}"

if [[ -z "$STA_RPT" ]]; then
  echo "usage: $0 STA_RPT [OUT_DIR]" >&2
  exit 2
fi
if [[ ! -f "$STA_RPT" ]]; then
  echo "STA_ONEPASS_REFUSED(exit=4): missing STA report: $STA_RPT" >&2
  exit 4
fi

MIN_FMAX="${CLK_PIX_MIN_FMAX_MHZ:-29.7}"
MARGIN_BASE="${TIMING_MARGIN_BASELINE:-$ROOT/assets/timing_margin_baseline_720p_compose.json}"

echo "STA_ONEPASS EXECUTED sta=$STA_RPT min_fmax_mhz=$MIN_FMAX baseline=$MARGIN_BASE"

echo "=== check_quartus_timing (require general[3], min_setup_rows=1, min_fmax) ==="
python3 "$ROOT/scripts/check_quartus_timing.py" \
  --sta-rpt "$STA_RPT" \
  --min-setup-rows 1 \
  --require-clock "general[3]" \
  --min-fmax-mhz "general[3]:${MIN_FMAX}"

echo "=== check_timing_margin (720p-compose baseline, clk_pix require_present) ==="
python3 "$ROOT/scripts/check_timing_margin.py" \
  --sta-rpt "$STA_RPT" \
  --baseline "$MARGIN_BASE"

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  # Evidence copy of gate stdout already printed; write a marker the parent can grep.
  {
    echo "STA_ONEPASS_OK"
    echo "sta=$STA_RPT"
    echo "min_fmax_mhz=$MIN_FMAX"
    echo "margin_baseline=$MARGIN_BASE"
    date -u +%Y-%m-%dT%H:%M:%SZ
  } >"$OUT_DIR/sta_onepass_ok.txt"
  # Placeholder path name referenced by Plex_clk_pix.sdc comment (parent may replace).
  if [[ ! -f "$OUT_DIR/clk_sys_sameclk_setup.txt" ]]; then
    echo "NOTE: clk_sys_sameclk_setup.txt not supplied — parent TQ report extract optional" \
      >"$OUT_DIR/clk_sys_sameclk_setup.txt"
  fi
fi

echo "STA_ONEPASS_PASS"
