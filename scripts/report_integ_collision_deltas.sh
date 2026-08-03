#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")" && pwd)/report_integ_collision_deltas.py" "$@"
