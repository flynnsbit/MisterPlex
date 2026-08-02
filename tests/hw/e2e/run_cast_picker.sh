#!/usr/bin/env bash
# run_cast_picker.sh — single entrypoint for the Plex Web cast-picker Playwright suite.
#
# Credentials from env (preferred) or conf:
#   PLEX_BASE   LOCAL PMS only, e.g. http://YOUR-PLEX-SERVER:32400
#   PLEX_TOKEN  account/server token accepted by that PMS web UI
#   MISTERPLEX_CONF  optional path to misterplex.conf
#
# Optional:
#   PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH  Chrome for Testing binary if browser
#                                        download is unavailable
#
# Do NOT point PLEX_BASE at remote / SHIELD / ignored servers.
#
# Exit: 0 PASS | 1 FAIL | 77 SKIP-NOT-PASS (missing deps/env)

set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 77

if [[ ! -d node_modules/playwright ]]; then
  echo "run_cast_picker: installing npm deps in tests/hw/e2e ..."
  npm install --no-fund --no-audit || {
    echo "SKIP-NOT-PASS: npm install failed"
    exit 77
  }
fi

# Prefer an already-bundled Chromium when the matching revision is cached.
# Avoid a hard dependency on a fresh CDN download in the lab.
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
    exit 77
  fi
fi

exec node "$ROOT/test_cast_picker_playwright.js" "$@"
