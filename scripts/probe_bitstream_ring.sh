#!/usr/bin/env bash
# Observe ARM bitstream producer vs FPGA consumer without guessing from a black screen.
#
# Triage rule:
#   write pointer static          → producer dormant / STREAM=0 / no demux
#   write advances, read stuck    → FPGA consumer wedged
#   both advance, picture wrong   → genuine decode bug
#
# Run ON the MiSTer (root). Does not load cores or kill processes.
# Optional: MISTER_HOST + ssh when invoked from the build host.
set -euo pipefail

STATUS_FILE="${BITSTREAM_STATUS_FILE:-/media/fat/misterplex/bitstream_ring.status}"
CTRL_PHYS=0x30140000
READ_PHYS=0x30140008
ERR_PHYS=0x30140010
STAT0_PHYS=0x30140018

remote_body() {
  python3 - <<'PY'
import os, struct, sys

def u64(path_fd, phys):
    page = phys & ~0xFFF
    off = phys - page
    mm = os.mmap(path_fd, 0x1000, offset=page)
    try:
        return struct.unpack_from("<Q", mm, off)[0]
    finally:
        mm.close()

def mag(w):
    return w & 0xFFFFFFFF

def mag_s(m):
    try:
        return bytes([(m >> (8*i)) & 0xFF for i in range(4)]).decode("ascii")
    except Exception:
        return "????"

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
try:
    ctrl = u64(fd, 0x30140000)
    rd   = u64(fd, 0x30140008)
    err  = u64(fd, 0x30140010)
    st0  = u64(fd, 0x30140018)
finally:
    os.close(fd)

cm, rm, em, s0m = mag(ctrl), mag(rd), mag(err), mag(st0)
prod = (ctrl >> 32) & 0x7FFFFFFF
epoch = (ctrl >> 63) & 1
cons = (rd >> 32) & 0xFFFFFFFF
ring_level = (st0 >> 32) & 0xFFFFFFFF if s0m == 0x504C5854 else None

print("=== DDR bitstream ring (live /dev/mem) ===")
print(f"CTRL@{hex(0x30140000)} magic={mag_s(cm)}(0x{cm:08x}) producer_bytes={prod} epoch={epoch}")
print(f"READ@{hex(0x30140008)} magic={mag_s(rm)}(0x{rm:08x}) consumer_bytes={cons}")
print(f"ERR @{hex(0x30140010)} magic={mag_s(em)}(0x{em:08x})")
if ring_level is not None:
    print(f"STAT0 ring_level={ring_level}")

triage = "unknown"
if cm == 0x504C5844:  # PLXD
    triage = "STARVED_producer_dormant_PLXD"
elif cm != 0x504C5842:  # not PLXB
    triage = "STARVED_no_PLXB_ctrl"
elif prod == 0:
    triage = "STARVED_no_writes"
elif rm != 0x504C5852:
    triage = "BROKEN_no_PLXR_read"
elif cons == 0 and prod > 0:
    triage = "BROKEN_consumer_stuck"
elif cons + 4096 < prod:
    triage = "CONSUMER_LAGGING"
else:
    triage = "FEED_OK_check_decode"
print(f"triage={triage}")
print()
print("Rule: static write→producer; write↑ read stuck→consumer; both↑ bad picture→decode")
PY

  if [[ -f "$STATUS_FILE" ]]; then
    echo
    echo "=== daemon snapshot ($STATUS_FILE) ==="
    cat "$STATUS_FILE"
  else
    echo
    echo "(no $STATUS_FILE yet — start misterplexd / play once)"
  fi
}

if [[ -n "${MISTER_HOST:-}" && ! -e /dev/mem ]]; then
  # shellcheck disable=SC2029
  sshpass -p "${MISTER_PASS:-1}" ssh -o StrictHostKeyChecking=no \
    "${MISTER_USER:-root}@${MISTER_HOST}" \
    "STATUS_FILE='$STATUS_FILE' bash -s" <<'EOS'
set -euo pipefail
STATUS_FILE="${STATUS_FILE:-/media/fat/misterplex/bitstream_ring.status}"
python3 - <<'PY'
import os, struct

def u64(path_fd, phys):
    page = phys & ~0xFFF
    off = phys - page
    mm = os.mmap(path_fd, 0x1000, offset=page)
    try:
        return struct.unpack_from("<Q", mm, off)[0]
    finally:
        mm.close()

def mag(w):
    return w & 0xFFFFFFFF

def mag_s(m):
    try:
        return bytes([(m >> (8*i)) & 0xFF for i in range(4)]).decode("ascii")
    except Exception:
        return "????"

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
try:
    ctrl = u64(fd, 0x30140000)
    rd   = u64(fd, 0x30140008)
    err  = u64(fd, 0x30140010)
    st0  = u64(fd, 0x30140018)
finally:
    os.close(fd)

cm, rm, em, s0m = mag(ctrl), mag(rd), mag(err), mag(st0)
prod = (ctrl >> 32) & 0x7FFFFFFF
epoch = (ctrl >> 63) & 1
cons = (rd >> 32) & 0xFFFFFFFF
ring_level = (st0 >> 32) & 0xFFFFFFFF if s0m == 0x504C5854 else None
print("=== DDR bitstream ring (live /dev/mem) ===")
print(f"CTRL@0x30140000 magic={mag_s(cm)}(0x{cm:08x}) producer_bytes={prod} epoch={epoch}")
print(f"READ@0x30140008 magic={mag_s(rm)}(0x{rm:08x}) consumer_bytes={cons}")
print(f"ERR @0x30140010 magic={mag_s(em)}(0x{em:08x})")
if ring_level is not None:
    print(f"STAT0 ring_level={ring_level}")
if cm == 0x504C5844:
    triage = "STARVED_producer_dormant_PLXD"
elif cm != 0x504C5842:
    triage = "STARVED_no_PLXB_ctrl"
elif prod == 0:
    triage = "STARVED_no_writes"
elif rm != 0x504C5852:
    triage = "BROKEN_no_PLXR_read"
elif cons == 0 and prod > 0:
    triage = "BROKEN_consumer_stuck"
elif cons + 4096 < prod:
    triage = "CONSUMER_LAGGING"
else:
    triage = "FEED_OK_check_decode"
print(f"triage={triage}")
print()
print("Rule: static write→producer; write↑ read stuck→consumer; both↑ bad picture→decode")
PY
if [[ -f "$STATUS_FILE" ]]; then
  echo
  echo "=== daemon snapshot ($STATUS_FILE) ==="
  cat "$STATUS_FILE"
else
  echo
  echo "(no $STATUS_FILE yet — start misterplexd / play once)"
fi
EOS
else
  remote_body
fi
