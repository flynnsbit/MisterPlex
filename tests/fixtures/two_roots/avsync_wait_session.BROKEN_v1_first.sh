#!/usr/bin/env bash
# FIXTURE ONLY — v1-before-v2 first-hit (two-roots trap). Not product.
REMOTE_READ='
pick=""
for f in /tmp/misterplexd.log /var/log/misterplexd.log /tmp/misterplex.log \
         /media/fat/misterplex/misterplexd.log /media/fat/misterplex_v2/misterplexd.log; do
  if [ -f "$f" ]; then pick=$f; break; fi
done
'
