rd() { devmem $1 32 2>/dev/null; }
snap() {
  echo "  PLXK@3007F000=$(rd 0x3007F000) payload=$(rd 0x3007F004)"
  echo "  PLXR@30140008=$(rd 0x30140008) count=$(rd 0x3014000C)"
  echo "  PLXE@30140010=$(rd 0x30140010) err=$(rd 0x30140014)"
  echo "  PLXT@30140018=$(rd 0x30140018) lvl=$(rd 0x3014001C)"
  echo "  PLXD@3007F128=$(rd 0x3007F128) PLXS@3007F100=$(rd 0x3007F100)"
}
echo "=== T0 ==="; snap
sleep 8
echo "=== T1 (+8s) ==="; snap
sleep 8
echo "=== T2 (+16s) ==="; snap
