# READ-ONLY sample of the four mailbox words the parent asked for.
# No writes: poking is w-fit-o5's experiment and would destroy the state.
for t in 0 1 2; do
  echo "sample=$t epoch=$(date +%s)"
  for a in 0x3007F100 0x3007F104 0x3007F128 0x3007F12C; do
    echo "  $a = $(devmem $a 2>/dev/null)"
  done
  [ "$t" -lt 2 ] && sleep 6
done
echo "plxs_expect=0x504C5853 plxd_expect=0x504C5844"
