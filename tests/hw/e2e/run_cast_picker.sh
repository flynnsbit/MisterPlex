#!/usr/bin/env bash
# run_cast_picker.sh — single entrypoint for Plex Web cast-picker Playwright suite.
#
# Self-diagnosing: missing required env → FAIL rc=1 with remediation;
# PMS unreachable → UNVERIFIED rc=2; missing playwright/chromium → SKIP-NOT-PASS rc=77.
# Never soft-passes a missing token/base.
#
# Optional gitignored lab env (does not override existing exports):
#   $E2E_ENV_FILE | tests/hw/e2e/.env.lab | ~/.config/misterplex/e2e.env
#
# Overlay-only (parent HDMI chrome grab):
#   E2E_OVERLAY_ONLY=1 E2E_OVERLAY_HOLD_SEC=10 ./tests/hw/e2e/run_cast_picker.sh
#
# Exit: 0 PASS | 1 FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS

set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 77

if [[ ! -d node_modules/playwright ]]; then
  echo "run_cast_picker: installing npm deps in tests/hw/e2e ..."
  npm install --no-fund --no-audit || {
    echo "SKIP-NOT-PASS: npm install failed"
    echo "CAST_PICKER_E2E_RESULT=SKIP-NOT-PASS"
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
        echo "run_cast_picker: using cached Chromium $found"
      fi
    fi
  fi
fi

if [[ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]]; then
  echo "run_cast_picker: no Chromium binary yet — trying playwright install chromium"
  if ! npx --no-install playwright install chromium; then
    echo "SKIP-NOT-PASS: playwright install chromium failed; set PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH"
    echo "CAST_PICKER_E2E_RESULT=SKIP-NOT-PASS"
    exit 77
  fi
fi

node "$ROOT/preflight_env.js" || exit $?
exec node "$ROOT/test_cast_picker_playwright.js" "$@"
