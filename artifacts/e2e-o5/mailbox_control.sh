# POSITIVE CONTROL: prove devmem reads real memory before trusting all-zeros.
# kPlxkAddr 0x3007F000 magic "PLXK"=0x504C584B is ARM-written by misterplexd.
# kPlxbAddr 0x30140000 magic "PLXB"=0x504C5842.
echo "daemon_running=$(pgrep -c misterplexd 2>/dev/null || echo 0)"
for a in 0x3007F000 0x3007F004 0x30140000 0x3007F108 0x3007F110 0x3007F118 0x3007F120; do
  echo "  $a = $(devmem $a 2>&1)"
done
echo "-- second sample of PLXK doorbell 6s apart --"
sleep 6
for a in 0x3007F000 0x3007F004; do
  echo "  $a = $(devmem $a 2>&1)"
done
echo "expect PLXK=0x504C584B PLXB=0x504C5842 PLXI=0x504C5849 PLXM=0x504C584D PLXF=0x504C5846"
