#!/usr/bin/env bash
# Idle-screen root-cause gate: black/damaged idle screen has three causes with
# one symptom, and they need different fixes.
#
#   NOT_DRAWN          the producer never put a frame in DDR
#   DRAWN_NOT_PRESENTED  DDR holds a frame the scanout never swaps to
#   DRAWN_OVERWRITTEN  DDR holds a frame, it is presented, but something writes
#                      the bank while it is being scanned out
#   PRESENTED_CORRUPT  the right bank is scanned out but the pixels arrive damaged
#   PRESENTED_CLEAN    nothing to fix
#
# Read-only: this card changes no configuration and restarts nothing. It reads
# the mailbox window the running core actually uses (derived from the doorbell
# in ddr_frame_layout.hpp — the 0x3007F1xx block in mailbox_abi_spec.hpp belongs
# to a different bank stride and returns frozen values left by an older core),
# samples both DDR banks, and captures real HDMI.
#
# The distinguishing evidence:
#   * DDR bank content       -> separates NOT_DRAWN from everything else
#   * PLXD disp_bank/swap    -> separates DRAWN_NOT_PRESENTED
#   * two captures with the producer's doorbell sequence unchanged
#                            -> separates DRAWN_OVERWRITTEN from PRESENTED_CORRUPT,
#                               because an ARM overwrite cannot happen while the
#                               ARM is not ringing the doorbell
#   * per-row left content edge -> separates PRESENTED_CORRUPT from PRESENTED_CLEAN
#
# "Capture succeeded" is deliberately NOT a pass anywhere below.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
HDMI_DEV="${HDMI_DEV:-/dev/video0}"
OUTDIR="${IDLE_RCA_OUT:-$ROOT/build/idle_screen_rca}"
CLASSIFY="$ROOT/scripts/hdmi_capture_classify.py"
INTEGRITY="$ROOT/scripts/idle_frame_integrity.py"
LAYOUT="$ROOT/host/libmisterplex/ddr_frame_layout.hpp"
RC_FAIL=1
RC_UNSCORED=77

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR
     -o ConnectTimeout=10 "$USER@$HOST")

echo "Scope: read-only idle-screen root cause. Reads DDR bank content and the doorbell-derived PLXK/PLXD/PLXF mailboxes on the MiSTer, then captures two HDMI frames locally and grades per-row left-edge integrity, to name ONE of NOT_DRAWN / DRAWN_NOT_PRESENTED / DRAWN_OVERWRITTEN / PRESENTED_CORRUPT / PRESENTED_CLEAN. It does not identify which picture is shown, does not verify colours, does not change any configuration, and does not prove RBF identity (tests/hw/test_rbf_provenance.sh owns that)."

verdict() {
    echo "IDLE_RCA_VERDICT=$1"
    echo "IDLE_RCA_RESULT=$2"
}

for tool in "$CLASSIFY" "$INTEGRITY" "$LAYOUT"; do
    if [ ! -f "$tool" ]; then
        echo "IDLE_RCA_RESULT=UNSCORED reason=missing-tool path=$tool"
        exit "$RC_UNSCORED"
    fi
done
if ! command -v sshpass >/dev/null 2>&1 && [ -z "${IDLE_RCA_PROBE_A:-}" ]; then
    echo "IDLE_RCA_RESULT=UNSCORED reason=no-sshpass"
    exit "$RC_UNSCORED"
fi

mkdir -p "$OUTDIR"

# Derive the live mailbox window from the shared layout header rather than
# repeating an address that has already gone stale once in this repo.
read -r DOORBELL BANK0 BANK_STRIDE Y_OFF U_OFF V_OFF FRAME_BYTES <<EOF
$(python3 - "$LAYOUT" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
def c(name):
    m = re.search(r'\b' + name + r'\s*=\s*(0x[0-9A-Fa-f]+|\d+)', text)
    if not m:
        raise SystemExit(f"missing {name} in layout header")
    return int(m.group(1), 0)
print(c('kPlex480pYuv420pDoorbellPhys'),
      c('kDdrFramePhysBase'),
      c('kPlex480pYuv420pBankStride'),
      c('kPlex480pYPlaneOffset'),
      c('kPlex480pUPlaneOffset'),
      c('kPlex480pVPlaneOffset'),
      c('kPlex480pYuv420pBytes'))
PY
)
EOF
if [ -z "${DOORBELL:-}" ]; then
    echo "IDLE_RCA_RESULT=UNSCORED reason=layout-parse-failed"
    exit "$RC_UNSCORED"
fi
printf 'Derived window: doorbell=0x%08X bank0=0x%08X stride=0x%X frame=%s bytes\n' \
    "$DOORBELL" "$BANK0" "$BANK_STRIDE" "$FRAME_BYTES"

probe() {
    # Fixture mode exists so tests/unit/test_idle_screen_rca_logic.sh can drive
    # every verdict branch without a MiSTer that is broken in five ways. It is
    # never a fallback: if the caller did not ask for fixtures the device is
    # contacted, and an unreachable device is UNSCORED, never a pass.
    local which="$1"
    local fixture_var="IDLE_RCA_PROBE_${which}"
    local fixture="${!fixture_var:-}"
    if [ -n "$fixture" ]; then
        cat "$fixture"
        return $?
    fi
    "${SSH[@]}" "DOORBELL=$DOORBELL BANK0=$BANK0 BANK_STRIDE=$BANK_STRIDE \
Y_OFF=$Y_OFF U_OFF=$U_OFF V_OFF=$V_OFF bash -s" <<'REMOTE' 2>/dev/null
set -u
rd() { devmem "$1" 32 2>/dev/null || echo 0x0; }
hex() { printf '0x%08X' "$1"; }

DB=$(printf '%d' "$DOORBELL")
printf 'PLXK_LO=%s\n' "$(rd "$(hex $DB)")"
printf 'PLXK_HI=%s\n' "$(rd "$(hex $((DB + 4)))")"
printf 'PLXS_LO=%s\n' "$(rd "$(hex $((DB + 0x100)))")"
printf 'PLXS_HI=%s\n' "$(rd "$(hex $((DB + 0x104)))")"
printf 'PLXF_LO=%s\n' "$(rd "$(hex $((DB + 0x118)))")"
printf 'PLXF_HI=%s\n' "$(rd "$(hex $((DB + 0x11C)))")"
printf 'PLXD_LO=%s\n' "$(rd "$(hex $((DB + 0x128)))")"
printf 'PLXD_HI=%s\n' "$(rd "$(hex $((DB + 0x12C)))")"

# Sample each bank's luma plane at spread-out offsets. A bank that is all
# 0x10101010 is video black; a bank that is all one non-black value is a flat
# fill; anything else is picture.
for b in 0 1; do
    base=$((BANK0 + b * BANK_STRIDE + Y_OFF))
    vals=""
    for off in 0 65536 131072 199680 262144; do
        vals="$vals $(rd "$(hex $((base + off)))")"
    done
    printf 'BANK%s_Y=%s\n' "$b" "$vals"
    printf 'BANK%s_U=%s\n' "$b" "$(rd "$(hex $((BANK0 + b * BANK_STRIDE + U_OFF)))")"
    printf 'BANK%s_V=%s\n' "$b" "$(rd "$(hex $((BANK0 + b * BANK_STRIDE + V_OFF)))")"
done
printf 'DAEMON_PID=%s\n' "$(pidof misterplexd 2>/dev/null || echo none)"
printf 'CORENAME=%s\n' "$(cat /tmp/CORENAME 2>/dev/null || echo unknown)"
printf 'RBF_MD5=%s\n' "$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | awk '{print $1}')"
REMOTE
}

PROBE_A="$OUTDIR/probe_a.txt"
PROBE_B="$OUTDIR/probe_b.txt"
probe A >"$PROBE_A"
PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ] || [ ! -s "$PROBE_A" ]; then
    echo "IDLE_RCA_RESULT=UNSCORED reason=device-unreachable rc=$PROBE_RC host=$HOST"
    exit "$RC_UNSCORED"
fi
cat "$PROBE_A"

val() { awk -F= -v k="$1" '$1 == k { $1=""; sub(/^=/,""); print; exit }' "$2" | tr -d ' \r'; }

PLXK_LO="$(val PLXK_LO "$PROBE_A")"
PLXK_HI_A="$(val PLXK_HI "$PROBE_A")"
PLXD_HI="$(val PLXD_HI "$PROBE_A")"
PLXD_LO="$(val PLXD_LO "$PROBE_A")"
PLXF_HI="$(val PLXF_HI "$PROBE_A")"
PLXF_LO="$(val PLXF_LO "$PROBE_A")"
RBF_MD5="$(val RBF_MD5 "$PROBE_A")"

if [ "$PLXK_LO" != "0x504C584B" ]; then
    echo "IDLE_RCA_RESULT=UNSCORED reason=no-PLXK-at-derived-doorbell got=$PLXK_LO"
    echo "  The running core is not using the doorbell this card derived; do not"
    echo "  fall back to another address, that is how frozen values get believed."
    exit "$RC_UNSCORED"
fi

DISP_BANK=$(( ( $(printf '%d' "$PLXD_HI") >> 2 ) & 1 ))
SWAP_PENDING=$(( ( $(printf '%d' "$PLXD_HI") >> 3 ) & 1 ))
FREE_MASK=$(( $(printf '%d' "$PLXD_HI") & 3 ))
UNDERRUN=$(( ( $(printf '%d' "$PLXF_HI") >> 8 ) & 0xFFFF ))
DEBUG_STATE=$(( $(printf '%d' "$PLXF_HI") & 0xFF ))
echo "MAILBOX disp_bank=$DISP_BANK swap_pending=$SWAP_PENDING free_mask=$FREE_MASK underrun=$UNDERRUN debug_state=$(printf '0x%02X' $DEBUG_STATE)"
echo "DEVICE rbf_md5=$RBF_MD5 plxd=$PLXD_LO/$PLXD_HI plxf=$PLXF_LO/$PLXF_HI"

# --- Is anything drawn in the displayed bank? ------------------------------
BANK_Y="$(awk -F= -v k="BANK${DISP_BANK}_Y" '$1 == k { $1=""; sub(/^=/,""); print; exit }' "$PROBE_A")"
echo "DISPLAYED_BANK bank=$DISP_BANK luma_samples=$BANK_Y"
DRAWN=0
for v in $BANK_Y; do
    case "$v" in
        0x10101010|0x00000000|"") ;;
        *) DRAWN=1 ;;
    esac
done

if [ "$DRAWN" -eq 0 ]; then
    echo "The bank being scanned out contains only video black / zeros: the"
    echo "producer never wrote a picture there."
    verdict NOT_DRAWN FAIL
    exit "$RC_FAIL"
fi

# --- Is that bank actually being presented? --------------------------------
# A frame parked in DDR that scanout never swaps to shows as a permanently
# pending swap. Sample twice so a single unlucky instant is not a conclusion.
sleep "${IDLE_RCA_SETTLE:-1}"
probe B >"$PROBE_B"
PLXD_HI_B="$(val PLXD_HI "$PROBE_B")"
PLXK_HI_B="$(val PLXK_HI "$PROBE_B")"
SWAP_PENDING_B=$(( ( $(printf '%d' "$PLXD_HI_B") >> 3 ) & 1 ))
DISP_BANK_B=$(( ( $(printf '%d' "$PLXD_HI_B") >> 2 ) & 1 ))
echo "MAILBOX_RESAMPLE disp_bank=$DISP_BANK_B swap_pending=$SWAP_PENDING_B doorbell_hi=$PLXK_HI_A -> $PLXK_HI_B"

if [ "$SWAP_PENDING" -eq 1 ] && [ "$SWAP_PENDING_B" -eq 1 ] && \
   [ "$DISP_BANK" -eq "$DISP_BANK_B" ]; then
    echo "swap_pending stayed set across a full second with the displayed bank"
    echo "unchanged: the frame-store is wedged and the written frame never reaches"
    echo "the screen."
    verdict DRAWN_NOT_PRESENTED FAIL
    exit "$RC_FAIL"
fi

# --- Capture and grade the pixels ------------------------------------------
CAP_A="$OUTDIR/frame_a.png"
CAP_B="$OUTDIR/frame_b.png"

grab() {
    local which="$1" out="$2" log="$3"
    local fixture_var="IDLE_RCA_CAP_${which}"
    local fixture="${!fixture_var:-}"
    if [ -n "$fixture" ]; then
        cp "$fixture" "$out" || return "$RC_UNSCORED"
        "$CLASSIFY" --source file --input "$out" --expect any >"$log" 2>&1
        return $?
    fi
    "$CLASSIFY" --device "$HDMI_DEV" --out "$out" --expect any >"$log" 2>&1
}

grab A "$CAP_A" "$OUTDIR/classify_a.log"
CLASS_RC_A=$?
if [ "$CLASS_RC_A" -eq "$RC_UNSCORED" ] || [ ! -f "$CAP_A" ]; then
    sed -n '1,20p' "$OUTDIR/classify_a.log"
    echo "IDLE_RCA_RESULT=UNSCORED reason=capture-unavailable dev=$HDMI_DEV"
    exit "$RC_UNSCORED"
fi
CLASS_A="$(grep -oE 'class=[A-Z_]+' "$OUTDIR/classify_a.log" | head -1 | cut -d= -f2)"
sleep "${IDLE_RCA_SETTLE:-1}"
grab B "$CAP_B" "$OUTDIR/classify_b.log"
CLASS_B="$(grep -oE 'class=[A-Z_]+' "$OUTDIR/classify_b.log" | head -1 | cut -d= -f2)"
echo "CAPTURE class_a=${CLASS_A:-none} class_b=${CLASS_B:-none}"

case "${CLASS_A:-}" in
    NO_SIGNAL|"")
        echo "The capture reports no valid HDMI signal, so nothing downstream of"
        echo "the frame store can be judged."
        echo "IDLE_RCA_RESULT=UNSCORED reason=no-hdmi-signal"
        exit "$RC_UNSCORED"
        ;;
    VALID_BLACK)
        echo "DDR holds a picture and the frame store is swapping, yet the screen"
        echo "is black: the presented bank is being blanked or overwritten"
        echo "downstream of the store."
        verdict DRAWN_OVERWRITTEN FAIL
        exit "$RC_FAIL"
        ;;
esac

INTEG_LOG="$OUTDIR/integrity.log"
# shellcheck disable=SC2086
"$INTEGRITY" --input "$CAP_B" --previous "$CAP_A" ${IDLE_RCA_INTEGRITY_ARGS:-} \
    --json "$OUTDIR/integrity.json" >"$INTEG_LOG" 2>&1
INTEG_RC=$?
grep -E '^IDLE_INTEGRITY' "$INTEG_LOG" || cat "$INTEG_LOG"

if [ "$INTEG_RC" -eq 0 ]; then
    verdict PRESENTED_CLEAN PASS
    exit 0
fi

# Damaged. Attribute it: the ARM can only corrupt a bank it is writing, and it
# only writes after ringing the doorbell. An unchanged doorbell across the two
# captures means the producer was idle while the damage was on screen.
if [ "$PLXK_HI_A" = "$PLXK_HI_B" ]; then
    echo "The doorbell sequence did not advance between the two graded captures,"
    echo "so no ARM frame write overlapped them; the damage is produced inside the"
    echo "presentation path. underrun=$UNDERRUN debug_state=$(printf '0x%02X' $DEBUG_STATE)"
    verdict PRESENTED_CORRUPT FAIL
else
    echo "The doorbell advanced between captures, so an ARM write overlapped the"
    echo "scanned-out bank and cannot be excluded as the source of the damage."
    verdict DRAWN_OVERWRITTEN FAIL
fi
exit "$RC_FAIL"
