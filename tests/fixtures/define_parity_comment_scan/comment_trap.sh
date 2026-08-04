#!/usr/bin/env bash
# Doc trap: scanner must ignore -DCOMMENT_ONLY_MACRO on this comment line.
g++ -DCOMMENT_LIVE_MACRO=1 -c x.cpp
echo "quoted noise stays optional"
