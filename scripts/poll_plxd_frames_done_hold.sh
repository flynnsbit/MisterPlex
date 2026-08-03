#!/usr/bin/env bash
# INVALIDATED — frames_done is SWAP count (not vsync). Do not poll for holds.
# Use daemon: media: publish_interval ... verdict=
echo "INVALIDATED: frames_done is swap counter; zero hold-length info." >&2
echo "Use: grep publish_interval /path/to/misterplexd.log" >&2
exit 2
