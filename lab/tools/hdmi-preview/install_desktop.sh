#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$ROOT/hdmi-preview.desktop.in"
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DEST="$DEST_DIR/hdmi-preview.desktop"
TMP="$DEST.tmp.$$"

mkdir -p "$DEST_DIR"
trap 'rm -f "$TMP"' EXIT

escaped_exec=$(printf '%s' "$ROOT/hdmi_preview.sh" | sed 's/[&|]/\\&/g')
sed "s|@HDMI_PREVIEW_EXEC@|$escaped_exec|g" "$TEMPLATE" >"$TMP"
chmod 0644 "$TMP"
mv "$TMP" "$DEST"
trap - EXIT

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DEST_DIR" >/dev/null 2>&1 || true
fi

echo "Installed HDMI Preview desktop entry: $DEST"
