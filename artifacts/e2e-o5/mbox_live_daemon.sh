echo "== mailboxes (read-only) =="
for a in 3007F100 3007F104 3007F128 3007F12C; do
  echo "0x$a = $(devmem 0x$a 32 2>/dev/null)"
done
echo "== positive control (must be 0x504C5844) =="
echo "0x30140000 = $(devmem 0x30140000 32 2>/dev/null)"
echo "== daemon log location =="
ls -l /tmp/misterplexd.log /media/fat/misterplex/*.log 2>/dev/null
echo "== daemon log tail =="
for f in /tmp/misterplexd.log /media/fat/misterplex/misterplexd.log; do
  [ -f "$f" ] && { echo "--- $f ---"; tail -25 "$f"; }
done
