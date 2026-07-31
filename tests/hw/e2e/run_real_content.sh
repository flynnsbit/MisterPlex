#!/usr/bin/env bash
# run_real_content.sh — P7 real library title → MiSTerPlex cast (Playwright).
# LOCAL PMS only. Never falls back to MiSTerPlex Tests fixtures.
#
# Exit: 0 PASS | 1 FAIL | 77 SKIP-NOT-PASS
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 77

export E2E_CONTENT="${E2E_CONTENT:-real}"
# Hold long enough for parent HDMI; transitions off (this is a pixel gate hold).
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-0}"
export E2E_REAL_HOLD_SEC="${E2E_REAL_HOLD_SEC:-${E2E_HDMI_HOLD_SEC:-45}}"

if [[ ! -d node_modules/playwright ]]; then
  echo "run_real_content: installing npm deps in tests/hw/e2e ..."
  npm install --no-fund --no-audit || {
    echo "SKIP-NOT-PASS: npm install failed"
    exit 77
  }
fi

if [[ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" && -z "${PW_CHROMIUM_PATH:-}" ]]; then
  expected="$(node -e "
try {
  const {chromium}=require('playwright');
  console.log(chromium.executablePath()||'');
} catch (_) { console.log(''); }
" 2>/dev/null || true)"
  if [[ -n "$expected" && -x "$expected" ]]; then
    export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="$expected"
  else
    cache="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
    if [[ -d "$cache" ]]; then
      found="$(find "$cache" -type f -path '*/chrome-linux64/chrome' 2>/dev/null | sort -V | tail -n 1 || true)"
      if [[ -n "$found" && -x "$found" ]]; then
        export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="$found"
        echo "run_real_content: using cached Chromium $found"
      fi
    fi
  fi
fi

if [[ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]]; then
  echo "run_real_content: trying playwright install chromium"
  if ! npx --no-install playwright install chromium; then
    echo "SKIP-NOT-PASS: playwright install chromium failed"
    exit 77
  fi
fi

exec node "$ROOT/test_real_content_playwright.js" "$@"
