#!/usr/bin/env bash
# Parent device command — read PLXC DDR contention snapshot (w-plxd).
#
# Usage (parent owns hardware; agents must not run this against the lab):
#   MISTER_HOST=192.168.1.183 MISTER_PASS=1 ./tools/read_ddr_contention.sh
#   DOORBELL_PHYS=0x300FF000 ./tools/read_ddr_contention.sh   # product 480p
#   DOORBELL_PHYS=0x3047F000 ./tools/read_ddr_contention.sh   # Option-C 720p
#
# Layout (LE 32-bit halves of snap_w0..w3 at doorbell+0x130):
#   +0x00 magic PLXC 0x504C5843 | +0x04 window_cycles
#   +0x08 m0_stall_cycles       | +0x0c m0_stall_while_m2
#   +0x10 m0_cmd_accepts        | +0x14 m0_rd_beats
#   +0x18 m2_cmd_accepts        | +0x1c m2_stall_while_m0
#
# Until a mailbox writer is muxed onto f2sdram, magic will not match — that
# is an honest miss (counters are fabric noprune; publish is a follow-on).
#
# PHYSICAL ACCEPTANCE: m2 (publish) fields are not product proof until src is
# contiguous PA (not heap vector). See ddr_contention_abi.hpp kPhysicalSrcAccepted.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
DOORBELL="${DOORBELL_PHYS:-0x300FF000}"
# PLXC offset 0x130 from doorbell
BASE=$(printf '0x%X' $((DOORBELL + 0x130)))

echo "=== DDR contention PLXC read @ ${BASE} (doorbell=${DOORBELL}) host=${HOST} ==="
echo "expect magic 0x504C5843 when mailbox writer is live"

ssh_cmd() {
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${HOST}" "$@"
  else
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${HOST}" "$@"
  fi
}

# Read eight 32-bit words
for off in 0 4 8 12 16 20 24 28; do
  addr=$(printf '0x%X' $((BASE + off)))
  val=$(ssh_cmd "devmem ${addr} 32" | tr -d '\r')
  echo "devmem ${addr} 32 -> ${val}"
done

echo "PASS read_ddr_contention.sh (transport only — interpret magic/fields above)"
