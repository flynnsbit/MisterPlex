#!/bin/bash
# MiSTer Scripts TUI: pick 240p / 480i / 480p FPGA pair (daemon + conf + RBF).
# Install: copy to /media/fat/Scripts/MiSTerPlex_Mode.sh and ensure
#   /media/fat/misterplex/bin/switch_misterplex_mode.sh + profiles/ + RBFs exist.
set -eu

SWITCH="${MISTERPLEX_SWITCH:-/media/fat/misterplex/bin/switch_misterplex_mode.sh}"
if [ ! -x "$SWITCH" ]; then
  SWITCH="$(cd "$(dirname "$0")" && pwd)/switch_misterplex_mode.sh"
fi
if [ ! -x "$SWITCH" ]; then
  echo "MiSTerPlex_Mode: missing switch_misterplex_mode.sh"
  echo "Expected $SWITCH"
  read -r -p "Press Enter..." _
  exit 1
fi

clear_screen() { printf '\033[2J\033[H' 2>/dev/null || clear 2>/dev/null || true; }

show_status() {
  echo
  "$SWITCH" status 2>/dev/null || true
  echo
}

pick=
if [ "${1:-}" != "" ]; then
  pick=$1
else
  clear_screen
  cat <<'MENU'
========================================
   MiSTerPlex mode switch
========================================
  Swaps companion conf + daemon + Plex RBF
  then reloads the core (Menu → Plex).

  1) 240p   FPGA decode (AU32 ladder)
  2) 480i   host-paint + lipsync (product)
  3) 480p   FPGA e41b (2cb76e50) — product
  4) Status (what is live now)
  5) Quit
========================================
MENU
  show_status
  printf "Select [1-5]: "
  read -r pick || true
fi

case "$pick" in
  1|240p|240) MODE=240p ;;
  2|480i|480I) MODE=480i ;;
  3|480p|480P|e41b) MODE=480p ;;
  4|status|s|S)
    clear_screen
    show_status
    read -r -p "Press Enter..." _
    exit 0
    ;;
  5|q|Q|quit|"")
    exit 0
    ;;
  *)
    echo "Unknown choice: $pick"
    read -r -p "Press Enter..." _
    exit 1
    ;;
esac

clear_screen
echo "Switching to $MODE …"
echo "(stops misterplexd, applies profile, loads RBF)"
echo
if "$SWITCH" "$MODE"; then
  echo
  echo "Done. Cast target should reappear as MiSTerPlex-<LAN-IP>."
  echo "Idle screen conf is logo (chevron), not last frame."
else
  echo
  echo "Switch FAILED (see messages above)."
fi
echo
read -r -p "Press Enter to return..." _
