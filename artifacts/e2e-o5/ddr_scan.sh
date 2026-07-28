nz=0; tot=0
echo "== scan mailbox region 0x3007F100..0x3007F17C =="
for off in 00 04 08 0C 10 14 18 1C 20 24 28 2C 30 34 38 3C 40 44 48 4C 50 54 58 5C 60 64 68 6C 70 74 78 7C; do
  v=$(devmem 0x3007F1$off 32 2>/dev/null); tot=$((tot+1))
  [ "$v" != "0x00000000" ] && { nz=$((nz+1)); echo "  NONZERO 0x3007F1$off = $v"; }
done
echo "== scan CTRL region 0x30140000..0x3014001C =="
for off in 00 04 08 0C 10 14 18 1C; do
  v=$(devmem 0x3014000$off 32 2>/dev/null) 2>/dev/null
  v=$(devmem $(printf '0x%X' $((0x30140000+0x$off))) 32 2>/dev/null); tot=$((tot+1))
  [ "$v" != "0x00000000" ] && { nz=$((nz+1)); echo "  NONZERO +0x$off = $v"; }
done
echo "== scan framebuffer probe 0x30000000..0x30000040 =="
for off in 0 4 8 C 10 14 18 1C 20 24 28 2C 30 34 38 3C; do
  v=$(devmem $(printf '0x%X' $((0x30000000+0x$off))) 32 2>/dev/null); tot=$((tot+1))
  [ "$v" != "0x00000000" ] && { nz=$((nz+1)); echo "  NONZERO fb+0x$off = $v"; }
done
echo "SCAN_TOTAL=$tot NONZERO=$nz"
