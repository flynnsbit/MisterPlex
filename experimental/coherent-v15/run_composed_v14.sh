#!/usr/bin/env bash
set -euo pipefail
CLOCK_PROFILE=sys120 bash tests/unit/test_ingress_frozen_pair.sh \
  full240-joint color-gop12 legacy-full240 active-filter-recovery \
  default legacy-default fault-recovery fault21-recovery ingress-seek
